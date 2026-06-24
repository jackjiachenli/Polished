//
//  WindowEnumerator.swift
//  Polished
//

import AppKit
import ApplicationServices

enum WindowEnumerator {
    private static let minimumCGWidth: CGFloat = 200
    private static let minimumCGHeight: CGFloat = 120

    static func switchableWindows(includeMinimized: Bool = true) -> [SwitchableWindow] {
        guard AXIsProcessTrusted() else { return [] }

        let ownBundleID = Bundle.main.bundleIdentifier
        var results: [SwitchableWindow] = []
        var seenWindowIDs = Set<CGWindowID>()

        results.append(contentsOf: enumerateFromWindowList(
            seenWindowIDs: &seenWindowIDs,
            includeMinimized: includeMinimized,
            ownBundleID: ownBundleID
        ))

        results.append(contentsOf: enumerateFromAccessibility(
            seenWindowIDs: &seenWindowIDs,
            includeMinimized: includeMinimized,
            ownBundleID: ownBundleID
        ))

        return deduplicate(results)
    }
    private static func enumerateFromWindowList(
        seenWindowIDs: inout Set<CGWindowID>,
        includeMinimized: Bool,
        ownBundleID: String?
    ) -> [SwitchableWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var results: [SwitchableWindow] = []

        for info in list {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  seenWindowIDs.insert(windowID).inserted,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated,
                  app.activationPolicy == .regular,
                  app.bundleIdentifier != ownBundleID else { continue }

            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            guard cgBounds(info) != nil else { continue }

            let axWindow = WindowAccessibility.axWindow(
                forWindowID: windowID,
                pid: pid,
                title: cgTitle(info)
            )

            if let axWindow, isSwitchable(axWindow, includeMinimized: includeMinimized) {
                results.append(makeSwitchableWindow(
                    windowID: windowID,
                    info: info,
                    axWindow: axWindow,
                    app: app
                ))
            } else if isSwitchableCGEntry(info, includeMinimized: includeMinimized) {
                results.append(makeSwitchableWindow(
                    windowID: windowID,
                    info: info,
                    axWindow: nil,
                    app: app
                ))
            }
        }

        return results
    }

    /// Secondary path: minimized and other windows missing from CGWindowList.
    private static func enumerateFromAccessibility(
        seenWindowIDs: inout Set<CGWindowID>,
        includeMinimized: Bool,
        ownBundleID: String?
    ) -> [SwitchableWindow] {
        var results: [SwitchableWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            if app.bundleIdentifier == ownBundleID { continue }

            for window in WindowAccessibility.windows(of: app) {
                guard isSwitchable(window, includeMinimized: includeMinimized) else { continue }
                guard let windowID = WindowAccessibility.windowID(of: window) else { continue }
                guard seenWindowIDs.insert(windowID).inserted else { continue }

                results.append(makeSwitchableWindow(
                    windowID: windowID,
                    axWindow: window,
                    app: app
                ))
            }
        }

        return results
    }

    private static func makeSwitchableWindow(
        windowID: CGWindowID,
        info: [String: Any],
        axWindow: AXUIElement?,
        app: NSRunningApplication
    ) -> SwitchableWindow {
        let axTitle = axWindow.map { WindowAccessibility.title(of: $0) } ?? ""
        let cgTitle = cgTitle(info)
        let title = !axTitle.isEmpty ? axTitle : cgTitle

        return SwitchableWindow(
            windowID: windowID,
            pid: app.processIdentifier,
            title: title,
            appName: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            isMinimized: axWindow.map { WindowAccessibility.isMinimized($0) } ?? false,
            isFullScreen: axWindow.map { WindowAccessibility.isFullScreen($0) } ?? cgLooksFullScreen(info),
            icon: app.icon,
            area: cgArea(info)
        )
    }

    private static func makeSwitchableWindow(
        windowID: CGWindowID,
        axWindow: AXUIElement,
        app: NSRunningApplication
    ) -> SwitchableWindow {
        SwitchableWindow(
            windowID: windowID,
            pid: app.processIdentifier,
            title: WindowAccessibility.title(of: axWindow),
            appName: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            isMinimized: WindowAccessibility.isMinimized(axWindow),
            isFullScreen: WindowAccessibility.isFullScreen(axWindow),
            icon: app.icon,
            area: WindowAccessibility.frame(of: axWindow).map { $0.width * $0.height } ?? 0
        )
    }

    private static func isSwitchable(_ window: AXUIElement, includeMinimized: Bool) -> Bool {
        guard WindowAccessibility.isStandardWindow(window) else { return false }
        if !includeMinimized, WindowAccessibility.isMinimized(window) { return false }
        return true
    }

    private static func isSwitchableCGEntry(_ info: [String: Any], includeMinimized: Bool) -> Bool {
        guard let bounds = cgBounds(info) else { return false }
        if bounds.width < minimumCGWidth || bounds.height < minimumCGHeight { return false }
        return true
    }

    private static func deduplicate(_ windows: [SwitchableWindow]) -> [SwitchableWindow] {
        var bestByKey: [String: SwitchableWindow] = [:]

        for window in windows {
            let key = "\(window.pid)|\(dedupeTitle(window))"
            if let existing = bestByKey[key] {
                bestByKey[key] = preferredWindow(window, over: existing)
            } else {
                bestByKey[key] = window
            }
        }

        return dropUntitledShadows(Array(bestByKey.values))
    }

    /// When an app has both a titled window and an untitled phantom (common in Electron fullscreen), keep the titled one.
    private static func dropUntitledShadows(_ windows: [SwitchableWindow]) -> [SwitchableWindow] {
        Dictionary(grouping: windows, by: \.pid).values.flatMap { group -> [SwitchableWindow] in
            let titled = group.filter { !displayTitle($0).isEmpty }
            return titled.isEmpty ? group : titled
        }
    }

    private static func preferredWindow(_ candidate: SwitchableWindow, over existing: SwitchableWindow) -> SwitchableWindow {
        if candidate.title.isEmpty != existing.title.isEmpty {
            return candidate.title.isEmpty ? existing : candidate
        }
        if candidate.area != existing.area {
            return candidate.area > existing.area ? candidate : existing
        }
        return candidate.windowID > existing.windowID ? candidate : existing
    }

    private static func dedupeTitle(_ window: SwitchableWindow) -> String {
        let title = displayTitle(window)
        return title.isEmpty ? window.appName : title
    }

    private static func displayTitle(_ window: SwitchableWindow) -> String {
        window.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cgTitle(_ info: [String: Any]) -> String {
        (info[kCGWindowName as String] as? String) ?? ""
    }

    private static func cgBounds(_ info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"] else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cgArea(_ info: [String: Any]) -> CGFloat {
        guard let bounds = cgBounds(info) else { return 0 }
        return bounds.width * bounds.height
    }

    private static func cgLooksFullScreen(_ info: [String: Any]) -> Bool {
        guard let bounds = cgBounds(info) else { return false }
        return NSScreen.screens.contains { screen in
            let frame = screen.frame
            return abs(bounds.width - frame.width) < 8 && abs(bounds.height - frame.height) < 80
        }
    }
}
