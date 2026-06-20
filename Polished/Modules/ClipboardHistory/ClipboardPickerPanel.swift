//
//  ClipboardPickerPanel.swift
//  Polished
//
//  Floating picker shown by the global clipboard hotkey.
//

import AppKit
import SwiftUI

@MainActor
final class ClipboardPickerPanel {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<ClipboardPickerView>?
    private var keyMonitor: Any?

    func show(history: ClipboardHistory) {
        let content = ClipboardPickerView(
            history: history,
            onSelect: { [weak self] item in
                history.paste(item)
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        if panel == nil {
            panel = makePanel()
        }

        if let hostingView {
            hostingView.rootView = content
        } else {
            let hosting = NSHostingView(rootView: content)
            hosting.frame.size = NSSize(width: 420, height: 360)
            hostingView = hosting
            panel?.contentView = hosting
        }

        guard let panel else { return }

        history.resetPickerSelection()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        center(panel)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor(history: history)
    }

    func dismiss() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        if NSApp.windows.filter({ $0.isVisible && $0.identifier?.rawValue != "hidden-context" }).isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Clipboard History"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func center(_ panel: NSPanel) {
        if let screen = NSScreen.main {
            let frame = panel.frame
            let screenFrame = screen.visibleFrame
            let origin = NSPoint(
                x: screenFrame.midX - frame.width / 2,
                y: screenFrame.midY - frame.height / 2
            )
            panel.setFrameOrigin(origin)
        }
    }

    private func installKeyMonitor(history: ClipboardHistory) {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.panel?.isVisible == true else { return event }

            switch event.keyCode {
            case 53: // Escape
                self?.dismiss()
                return nil
            case 125: // Down
                history.movePickerSelection(delta: 1)
                return nil
            case 126: // Up
                history.movePickerSelection(delta: -1)
                return nil
            case 36, 76: // Return, keypad Enter
                history.pasteSelectedPickerItem()
                self?.dismiss()
                return nil
            case 51, 117: // Backspace, Forward Delete
                history.deleteSelectedItem()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private struct ClipboardPickerView: View {
    @Bindable var history: ClipboardHistory
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if history.items.isEmpty {
                ContentUnavailableView(
                    "No clipboard items",
                    systemImage: "doc.on.clipboard",
                    description: Text("Copy something to build your history.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { history.selectedItemID },
                    set: { history.selectedItemID = $0 }
                )) {
                    ForEach(history.items) { item in
                        ClipboardPickerRow(
                            item: item,
                            onPaste: { onSelect(item) },
                            onDelete: { history.deleteItem(item) }
                        )
                        .tag(item.id)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text("↑↓ navigate · ↵ paste · ⌫ delete · esc dismiss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !history.items.isEmpty {
                    Button("Clear All", role: .destructive) {
                        history.clearHistory()
                    }
                }
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }
}

private struct ClipboardPickerRow: View {
    let item: ClipboardItem
    let onPaste: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.content.preview)
                    .lineLimit(2)
                Text(item.capturedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onPaste()
        }
    }
}
