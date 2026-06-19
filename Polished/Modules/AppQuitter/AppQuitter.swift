import AppKit
import ApplicationServices

final class AppQuitter: Module {
    let id = "app-quitter"
    var name = "App Quitter"
    var isEnabled = false

    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var monitoredApps: [pid_t: NSRunningApplication] = [:]
    private var observedWindows: [pid_t: [AXUIElement]] = [:]
    private var pendingChecks: [pid_t: DispatchWorkItem] = [:]

    /// Brief pause so the AX tree reflects the closed window
    private let trackedWindowDelay: TimeInterval = 0.05
    /// Longer path for ambiguous destroys (e.g. Electron focus churn)
    private let uncertainInitialDelay: TimeInterval = 0.15
    private let uncertainRetryDelay: TimeInterval = 0.2

    private let excludedBundleIDs: Set<String> = [
        "com.apple.finder",
        Bundle.main.bundleIdentifier ?? "com.jackjiachenli.Polished",
    ]

    func start() {
        guard AXIsProcessTrusted() else {
            print("AppQuitter: Accessibility permission not granted — enable in System Settings")
            return
        }

        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.startMonitoring(app)
        })

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.stopMonitoring(pid: app.processIdentifier)
        })

        for app in NSWorkspace.shared.runningApplications {
            startMonitoring(app)
        }
    }

    func stop() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for pid in Array(axObservers.keys) {
            stopMonitoring(pid: pid)
        }
    }

    private func shouldMonitor(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated else { return false }
        guard app.activationPolicy == .regular else { return false }
        guard let bundleID = app.bundleIdentifier else { return false }
        guard !excludedBundleIDs.contains(bundleID) else { return false }
        return true
    }

    private func startMonitoring(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard shouldMonitor(app) else { return }
        guard axObservers[pid] == nil else { return }

        monitoredApps[pid] = app

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)
        guard result == .success, let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let axApp = AXUIElementCreateApplication(pid)

        AXObserverAddNotification(
            observer,
            axApp,
            kAXWindowCreatedNotification as CFString,
            refcon
        )

        observeAllWindows(pid: pid, observer: observer, refcon: refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer
    }

    private func stopMonitoring(pid: pid_t) {
        pendingChecks[pid]?.cancel()
        pendingChecks.removeValue(forKey: pid)

        if let observer = axObservers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        monitoredApps.removeValue(forKey: pid)
        observedWindows.removeValue(forKey: pid)
    }

    fileprivate func handleWindowCreated(pid: pid_t) {
        guard let observer = axObservers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        observeAllWindows(pid: pid, observer: observer, refcon: refcon)
    }

    fileprivate func handleWindowDestroyed(pid: pid_t, element: AXUIElement) {
        guard axObservers[pid] != nil else { return }

        var observed = observedWindows[pid] ?? []
        if let index = observed.firstIndex(where: { $0 == element }) {
            observed.remove(at: index)
            observedWindows[pid] = observed
            scheduleCheck(pid: pid, requiresRetry: false)
        } else if isWindow(element) {
            // CFEqual match can fail across AX wrappers; accept destroy events on window roles
            scheduleCheck(pid: pid, requiresRetry: true)
        }
    }

    private func isWindow(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleString = role as? String else { return false }
        return roleString == kAXWindowRole as String
    }

    private func observeAllWindows(pid: pid_t, observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let windows = windowList as? [AXUIElement] else { return }

        var observed = observedWindows[pid] ?? []
        for window in windows {
            guard !observed.contains(where: { $0 == window }) else { continue }
            AXObserverAddNotification(
                observer,
                window,
                kAXUIElementDestroyedNotification as CFString,
                refcon
            )
            observed.append(window)
        }
        observedWindows[pid] = observed
    }

    fileprivate func scheduleCheck(pid: pid_t, requiresRetry: Bool) {
        pendingChecks[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkAndQuitIfNoWindows(pid: pid, requiresRetry: requiresRetry, attempt: 1)
        }
        pendingChecks[pid] = work
        let delay = requiresRetry ? uncertainInitialDelay : trackedWindowDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func visibleWindowCount(for pid: pid_t) -> Int? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let windows = windowList as? [AXUIElement] else { return nil }

        return windows.filter { window in
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            return (minimized as? Bool) != true
        }.count
    }

    private func checkAndQuitIfNoWindows(pid: pid_t, requiresRetry: Bool, attempt: Int) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        guard shouldMonitor(app) else { return }

        guard let visibleCount = visibleWindowCount(for: pid) else { return }
        guard visibleCount == 0 else { return }

        // Retry only for ambiguous destroys — Electron apps can briefly report 0 windows
        if requiresRetry && attempt == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + uncertainRetryDelay) { [weak self] in
                self?.checkAndQuitIfNoWindows(pid: pid, requiresRetry: true, attempt: 2)
            }
            return
        }

        if requiresRetry && attempt == 2 {
            guard let recount = visibleWindowCount(for: pid), recount == 0 else { return }
        }

        let label = app.localizedName ?? app.bundleIdentifier ?? "unknown"
        print("AppQuitter: Terminating \(label) — no visible windows remaining")
        let quit = app.terminate()
        print("AppQuitter: terminate() returned \(quit) for \(label)")
        stopMonitoring(pid: pid)
    }
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }

    let quitter = Unmanaged<AppQuitter>.fromOpaque(refcon).takeUnretainedValue()
    let notificationName = notification as String

    DispatchQueue.main.async {
        if notificationName == kAXWindowCreatedNotification as String {
            quitter.handleWindowCreated(pid: pid)
        } else if notificationName == kAXUIElementDestroyedNotification as String {
            quitter.handleWindowDestroyed(pid: pid, element: element)
        }
    }
}
