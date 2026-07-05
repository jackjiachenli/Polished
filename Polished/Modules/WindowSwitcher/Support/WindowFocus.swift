//
//  WindowFocus.swift
//  Polished
//

import AppKit
import ApplicationServices

enum WindowFocus {
    private static let fullScreenRetryDelay: TimeInterval = 0.15
    private static let standardRetryDelay: TimeInterval = 0.05
    private static let maxAttempts = 4

    @discardableResult
    static func raise(_ window: SwitchableWindow) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let app = NSRunningApplication(processIdentifier: window.pid),
              !app.isTerminated else { return false }

        app.activate(options: [.activateAllWindows])

        let delay = window.isFullScreen ? fullScreenRetryDelay : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            raiseResolved(window: window, app: app, attempt: 0)
        }
        return true
    }

    private static func raiseResolved(
        window: SwitchableWindow,
        app: NSRunningApplication,
        attempt: Int
    ) {
        guard !app.isTerminated else { return }

        if let axWindow = resolveAXWindow(for: window) {
            if WindowAccessibility.isMinimized(axWindow) {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let axApp = AXUIElementCreateApplication(window.pid)
            applyFocus(app: app, axApp: axApp, axWindow: axWindow, window: window, attempt: 0)
            return
        }

        guard attempt < maxAttempts else {
            PolishedLog.debug("WindowFocus: Could not resolve AX window for \(window.windowID) after retries")
            return
        }

        let delay = window.isFullScreen ? fullScreenRetryDelay : standardRetryDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            raiseResolved(window: window, app: app, attempt: attempt + 1)
        }
    }

    private static func resolveAXWindow(for window: SwitchableWindow) -> AXUIElement? {
        if window.isFullScreen, let fullScreen = WindowAccessibility.fullScreenWindow(pid: window.pid) {
            return fullScreen
        }

        if let byID = WindowAccessibility.axWindow(
            forWindowID: window.windowID,
            pid: window.pid,
            title: window.title
        ) {
            if window.isFullScreen, !WindowAccessibility.isFullScreen(byID),
               let fullScreen = WindowAccessibility.fullScreenWindow(pid: window.pid) {
                return fullScreen
            }
            return byID
        }

        return WindowAccessibility.axWindow(
            matchingTitle: window.title,
            pid: window.pid,
            preferFullScreen: window.isFullScreen
        )
    }

    private static func applyFocus(
        app: NSRunningApplication,
        axApp: AXUIElement,
        axWindow: AXUIElement,
        window: SwitchableWindow,
        attempt: Int
    ) {
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [.activateAllWindows])

        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        let focusResult = AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)

        if focusResult == .success {
            PolishedLog.debug("WindowFocus: Raised window \(window.windowID) (\(window.title))")
            return
        }

        guard attempt < maxAttempts else {
            PolishedLog.debug("WindowFocus: Focus failed for window \(window.windowID) after retries")
            return
        }

        let delay = window.isFullScreen ? fullScreenRetryDelay : standardRetryDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let axWindow = resolveAXWindow(for: window) ?? axWindow
            applyFocus(app: app, axApp: axApp, axWindow: axWindow, window: window, attempt: attempt + 1)
        }
    }
}
