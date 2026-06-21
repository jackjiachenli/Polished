//
//  WindowAccessibility.swift
//  Polished
//
// Shared Accessibility helpers for window enumeration, IDs, and frames.
//

import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum ScreenCoordinates {
    static var primaryMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    static func cocoaPointToQuartz(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    static func cocoaRectToQuartz(_ rect: CGRect) -> CGRect {
        let r = rect.integral
        return CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }
}

enum WindowAccessibility {
    private static let excludedSubroles: Set<String> = [
        kAXDialogSubrole as String,
        kAXFloatingWindowSubrole as String,
        kAXSystemFloatingWindowSubrole as String,
    ]

    static func frontmostRegularApplication(excludingOwnApp: Bool = true) -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular else { return nil }
        if excludingOwnApp, app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        return app
    }

    static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    static func focusedWindow(in app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return nil }
        return value as! AXUIElement
    }

    static func windowAtCursor(_ point: NSPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        let quartz = ScreenCoordinates.cocoaPointToQuartz(point)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(quartz.x), Float(quartz.y), &element
        ) == .success, var current = element else { return nil }

        for _ in 0..<24 {
            if isStandardWindow(current) { return current }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue else { break }
            current = parentValue as! AXUIElement
        }
        return nil
    }

    static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
              (role as? String) == kAXWindowRole as String else { return false }

        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subrole = subrole as? String,
           excludedSubroles.contains(subrole) {
            return false
        }
        return true
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            return true
        }
        return false
    }

    static func hasSettableFrame(_ window: AXUIElement) -> Bool {
        isSettable(window, kAXPositionAttribute as CFString)
            && isSettable(window, kAXSizeAttribute as CFString)
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success,
           let fullscreen = value as? Bool {
            return fullscreen
        }
        return false
    }

    static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String else { return "" }
        return title
    }

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var wid = CGWindowID(0)
        if _AXUIElementGetWindow(window, &wid) == .success, wid != 0 {
            return wid
        }
        return windowIDFromWindowList(for: window)
    }

    static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for entry in list {
            if let id = entry[kCGWindowNumber as String] as? CGWindowID {
                ids.insert(id)
            }
        }
        return ids
    }

    static func allWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for entry in list {
            if let id = entry[kCGWindowNumber as String] as? CGWindowID {
                ids.insert(id)
            }
        }
        return ids
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }

        return CGRect(
            x: pos.x,
            y: ScreenCoordinates.primaryMaxY - pos.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func setFrame(_ cocoaFrame: CGRect, on window: AXUIElement) {
        let quartz = ScreenCoordinates.cocoaRectToQuartz(cocoaFrame)
        setQuartzPoint(quartz.origin, on: window)
        setQuartzSize(quartz.size, on: window)
    }

    private static func windowIDFromWindowList(for window: AXUIElement) -> CGWindowID? {
        guard let frame = frame(of: window) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }

        for info in list {
            guard let infoPID = info[kCGWindowOwnerPID as String] as? pid_t, infoPID == pid,
                  let windowNumber = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }

            let primaryMaxY = ScreenCoordinates.primaryMaxY
            let cocoaFrame = CGRect(x: x, y: primaryMaxY - y - h, width: w, height: h)
            if framesApproxEqual(cocoaFrame, frame) {
                return windowNumber
            }
        }
        return nil
    }

    private static func framesApproxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) < tolerance
            && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    private static func setQuartzPoint(_ point: CGPoint, on window: AXUIElement) {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private static func setQuartzSize(_ size: CGSize, on window: AXUIElement) {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }
}
