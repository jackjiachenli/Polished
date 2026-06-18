import AppKit
import ApplicationServices

final class AppQuitter: Module {
    let id = "app-quitter"
    var name = "App Quitter"
    var isEnabled = false

    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var monitoredApps: [pid_t: NSRunningApplication] = [:]
    private var observedWindows: [pid_t: Set<ObjectIdentifier>] = [:]
    private var pendingChecks: [pid_t: DispatchWorkItem] = [:]

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
        let windowID = ObjectIdentifier(element)
        guard var observed = observedWindows[pid], observed.contains(windowID) else { return }
        observed.remove(windowID)
        observedWindows[pid] = observed
        scheduleCheck(pid: pid)
    }

    private func observeAllWindows(pid: pid_t, observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let windows = windowList as? [AXUIElement] else { return }

        var observed = observedWindows[pid] ?? []
        for window in windows {
            let id = ObjectIdentifier(window)
            guard !observed.contains(id) else { continue }
            AXObserverAddNotification(
                observer,
                window,
                kAXUIElementDestroyedNotification as CFString,
                refcon
            )
            observed.insert(id)
        }
        observedWindows[pid] = observed
    }

    fileprivate func scheduleCheck(pid: pid_t) {
        pendingChecks[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkAndQuitIfNoWindows(pid: pid, attempt: 1)
        }
        pendingChecks[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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

    private func checkAndQuitIfNoWindows(pid: pid_t, attempt: Int) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        guard shouldMonitor(app) else { return }

        guard let visibleCount = visibleWindowCount(for: pid) else { return }
        guard visibleCount == 0 else { return }

        // Retry once — Electron apps often report 0 windows briefly during focus changes
        if attempt == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkAndQuitIfNoWindows(pid: pid, attempt: 2)
            }
            return
        }

        guard let recount = visibleWindowCount(for: pid), recount == 0 else { return }

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
