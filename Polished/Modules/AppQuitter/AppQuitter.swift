//
//  AppQuitter.swift
//  Polished
//
// Quits regular apps when their last visible window closes.
// Requires Accessibility. Excludes Finder and Polished itself.
//

import AppKit
import ApplicationServices

final class AppQuitter: Module {
    let id = "app-quitter"
    var name = "App Quitter"
    var isEnabled = false

    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var monitoredApps: [pid_t: NSRunningApplication] = [:]
    /// Visible user windows we are actively tracking per process.
    private var trackedVisibleWindows: [pid_t: [AXUIElement]] = [:]

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

        for app in NSWorkspace.shared.runningApplications where appHasVisibleUserWindow(app) {
            startMonitoring(app)
        }
    }

    private func appHasVisibleUserWindow(_ app: NSRunningApplication) -> Bool {
        guard shouldMonitor(app) else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let windows = windowList as? [AXUIElement] else {
            return false
        }
        return windows.contains { isVisibleUserWindow($0) }
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

        syncTrackedWindows(pid: pid, observer: observer, refcon: refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer
    }

    private func stopMonitoring(pid: pid_t) {
        if let observer = axObservers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        monitoredApps.removeValue(forKey: pid)
        trackedVisibleWindows.removeValue(forKey: pid)
    }

    fileprivate func handleWindowCreated(pid: pid_t) {
        guard let observer = axObservers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        syncTrackedWindows(pid: pid, observer: observer, refcon: refcon)
    }

    fileprivate func handleWindowDestroyed(pid: pid_t, element: AXUIElement) {
        guard axObservers[pid] != nil else { return }

        let wasTracked = removeTrackedWindow(pid: pid, element: element)
        guard wasTracked || isWindow(element) else { return }

        if wasTracked, !(trackedVisibleWindows[pid]?.isEmpty ?? true) {
            // Other windows we were already tracking are still open — no AX round-trip needed.
            return
        }

        if wasTracked {
            evaluateQuit(pid: pid)
        } else {
            // CFEqual can fail across AX wrappers; defer one runloop turn so the AX tree can update.
            DispatchQueue.main.async { [weak self] in
                self?.evaluateQuit(pid: pid)
            }
        }
    }

    private func removeTrackedWindow(pid: pid_t, element: AXUIElement) -> Bool {
        guard var tracked = trackedVisibleWindows[pid] else { return false }
        guard let index = tracked.firstIndex(where: { $0 == element }) else { return false }
        tracked.remove(at: index)
        trackedVisibleWindows[pid] = tracked
        return true
    }

    private func isWindow(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleString = role as? String else { return false }
        return roleString == kAXWindowRole as String
    }

    private func syncTrackedWindows(pid: pid_t, observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let windows = windowList as? [AXUIElement] else {
            trackedVisibleWindows[pid] = []
            return
        }

        let visible = windows.filter { isVisibleUserWindow($0) }
        var tracked = (trackedVisibleWindows[pid] ?? []).filter { existing in
            visible.contains(where: { $0 == existing })
        }

        for window in visible where !tracked.contains(where: { $0 == window }) {
            AXObserverAddNotification(
                observer,
                window,
                kAXUIElementDestroyedNotification as CFString,
                refcon
            )
            tracked.append(window)
        }

        trackedVisibleWindows[pid] = tracked
    }

    private func isVisibleUserWindow(_ window: AXUIElement) -> Bool {
        guard isWindow(window) else { return false }

        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subrole = subrole as? String {
            let excludedSubroles: Set<String> = [
                kAXDialogSubrole as String,
                kAXFloatingWindowSubrole as String,
                kAXSystemFloatingWindowSubrole as String,
                "AXDrawer",
            ]
            if excludedSubroles.contains(subrole) {
                return false
            }
        }

        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if (minimized as? Bool) == true { return false }

        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeValue {
            var size = CGSize.zero
            if AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
               size.width < 100 || size.height < 100 {
                return false
            }
        }

        return true
    }

    private func evaluateQuit(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        guard shouldMonitor(app) else { return }

        if let observer = axObservers[pid] {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            syncTrackedWindows(pid: pid, observer: observer, refcon: refcon)
        }

        guard trackedVisibleWindows[pid]?.isEmpty ?? true else { return }

        let label = app.localizedName ?? app.bundleIdentifier ?? "unknown"
        print("AppQuitter: Terminating \(label) (pid \(pid)) — no visible windows remaining")
        let quit = app.terminate()
        print("AppQuitter: terminate() returned \(quit) for \(label) (pid \(pid))")
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
