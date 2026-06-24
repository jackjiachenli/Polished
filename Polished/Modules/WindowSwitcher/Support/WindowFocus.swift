//
//  WindowFocus.swift
//  Polished
//

import AppKit
import ApplicationServices

enum WindowFocus {
    @discardableResult
    static func raise(_ window: SwitchableWindow) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let app = NSRunningApplication(processIdentifier: window.pid),
              !app.isTerminated else { return false }
        guard let axWindow = WindowAccessibility.axWindow(
            forWindowID: window.windowID,
            pid: window.pid,
            title: window.title
        ) ?? WindowAccessibility.axWindow(matchingTitle: window.title, pid: window.pid) else {
            app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            PolishedLog.debug("WindowFocus: Activated app \(window.pid) — no AX window resolved")
            return true
        }

        if WindowAccessibility.isMinimized(axWindow) {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        let axApp = AXUIElementCreateApplication(window.pid)
        DispatchQueue.main.async {
            applyFocus(app: app, axApp: axApp, axWindow: axWindow, window: window, attempt: 0)
        }
        return true
    }

    private static func applyFocus(
        app: NSRunningApplication,
        axApp: AXUIElement,
        axWindow: AXUIElement,
        window: SwitchableWindow,
        attempt: Int
    ) {
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        let focusResult = AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)

        if focusResult == .success {
            PolishedLog.debug("WindowFocus: Raised window \(window.windowID) (\(window.title))")
            return
        }

        guard attempt < 2 else {
            PolishedLog.debug("WindowFocus: Focus failed for window \(window.windowID) after retries")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            applyFocus(app: app, axApp: axApp, axWindow: axWindow, window: window, attempt: attempt + 1)
        }
    }
}
