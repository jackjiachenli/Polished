//
//  ClipboardPickerWindowController.swift
//  Polished
//

import AppKit
import SwiftUI

@MainActor
final class ClipboardPickerWindowController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPickerWindowController()

    private var window: NSWindow?
    private weak var history: ClipboardHistory?

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show(history: ClipboardHistory) {
        self.history = history
        history.resetPickerSelection()
        history.pickerPresented = true

        let content = ClipboardPickerView(history: history)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]

        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.identifier = NSUserInterfaceItemIdentifier("clipboard-picker")
            newWindow.title = "Clipboard History"
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            window = newWindow
        }

        window?.contentViewController = controller
        AppActivation.activateForWindowPresentation()
        centerWindow()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        guard let window else {
            history?.pickerPresented = false
            return
        }
        window.orderOut(nil)
        history?.pickerPresented = false
    }

    func windowWillClose(_ notification: Notification) {
        history?.pickerPresented = false
        if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "settings" && $0.isVisible }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func centerWindow() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let frame = window.frame
        let screenFrame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        ))
    }
}
