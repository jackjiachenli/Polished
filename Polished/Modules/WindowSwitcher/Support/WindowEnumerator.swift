//
//  WindowEnumerator.swift
//  Polished
//

import AppKit
import ApplicationServices

enum WindowEnumerator {
    static func switchableWindows(includeMinimized: Bool = true) -> [SwitchableWindow] {
        guard AXIsProcessTrusted() else { return [] }

        let ownBundleID = Bundle.main.bundleIdentifier
        var results: [SwitchableWindow] = []
        var seenWindowIDs = Set<CGWindowID>()

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            if app.bundleIdentifier == ownBundleID { continue }

            let appName = app.localizedName ?? "Unknown"
            let icon = app.icon

            for window in WindowAccessibility.windows(of: app) {
                guard isSwitchable(window, includeMinimized: includeMinimized) else { continue }
                guard let windowID = WindowAccessibility.windowID(of: window) else { continue }
                guard seenWindowIDs.insert(windowID).inserted else { continue }

                results.append(SwitchableWindow(
                    windowID: windowID,
                    pid: app.processIdentifier,
                    title: WindowAccessibility.title(of: window),
                    appName: appName,
                    bundleIdentifier: app.bundleIdentifier,
                    isMinimized: WindowAccessibility.isMinimized(window),
                    icon: icon
                ))
            }
        }
        return results
    }

    private static func isSwitchable(_ window: AXUIElement, includeMinimized: Bool) -> Bool {
        if WindowAccessibility.isFullScreen(window) { return false }
        guard WindowAccessibility.isStandardWindow(window) else { return false }
        if !includeMinimized, WindowAccessibility.isMinimized(window) { return false }
        return true
    }
}
