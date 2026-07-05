//
//  ClipboardPickerPanel.swift
//  Polished
//

import AppKit
import SwiftUI

@MainActor
final class ClipboardPickerPanel: NSObject {
    private var panel: FloatingPickerPanel?
    private var hostingView: NSHostingView<ClipboardPickerView>?
    private var keyMonitor: Any?
    private var savedPasteTarget: NSRunningApplication?

    func show(history: ClipboardHistory) {
        let content = ClipboardPickerView(
            history: history,
            onSelect: { [weak self] item in
                let target = self?.pasteTargetForPaste()
                history.paste(item, activating: target)
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        if panel == nil {
            let newPanel = FloatingPickerPanel()
            newPanel.delegate = self
            panel = newPanel
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

        captureInitialPasteTarget()
        history.resetPickerSelection()
        center(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor(history: history)
    }

    func dismiss() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    private func captureInitialPasteTarget() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            savedPasteTarget = app
        }
    }

    private func pasteTargetForPaste() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            return frontmost
        }
        return savedPasteTarget
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
                history.pasteSelectedPickerItem(activating: self?.pasteTargetForPaste())
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

extension ClipboardPickerPanel: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }
        savedPasteTarget = app
    }
}

private final class FloatingPickerPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .closable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = "Clipboard History"
        titlebarAppearsTransparent = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeMain: Bool { false }
}

private struct ClipboardPickerView: View {
    @Bindable var history: ClipboardHistory
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    @State private var copiedItemID: UUID?
    @State private var copiedFeedbackTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if history.items.isEmpty {
                    ContentUnavailableView(
                        "No clipboard items",
                        systemImage: "doc.on.clipboard",
                        description: Text("Copy something to build your history.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(history.items) { item in
                                ClipboardPickerRow(
                                    item: item,
                                    isSelected: history.selectedItemID == item.id,
                                    showCopied: copiedItemID == item.id,
                                    onSelect: { history.selectedItemID = item.id },
                                    onPaste: { onSelect(item) },
                                    onCopy: { copyItem(item) },
                                    onDelete: { history.deleteItem(item) }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }

                HStack {
                    Text("Click where to paste, then ↵ or double-click item")
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

            if copiedItemID != nil {
                CopiedFeedbackBanner()
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: copiedItemID)
    }

    private func copyItem(_ item: ClipboardItem) {
        history.selectedItemID = item.id
        history.copyToPasteboard(item)
        copiedFeedbackTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            copiedItemID = item.id
        }
        copiedFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, copiedItemID == item.id else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                copiedItemID = nil
            }
        }
    }
}

private struct CopiedFeedbackBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Copied to clipboard")
                .fontWeight(.medium)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

private struct ClipboardPickerRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let showCopied: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
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
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onSelect()
                onCopy()
            } label: {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(copyButtonBackground)
                    .foregroundStyle(showCopied ? .green : .primary)
                    .scaleEffect(showCopied ? 1.1 : 1)
                    .symbolEffect(.bounce, value: showCopied)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: showCopied)

            Button {
                onSelect()
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
                    .background {
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 0.85 : 0.45))
                    }
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onPaste()
            }
        )
    }

    @ViewBuilder
    private var copyButtonBackground: some View {
        Circle()
            .fill(
                showCopied
                    ? Color.green.opacity(0.22)
                    : Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 0.95 : 0.5)
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        showCopied ? Color.green.opacity(0.55) : Color.primary.opacity(isSelected ? 0.18 : 0.08),
                        lineWidth: showCopied ? 1.5 : 1
                    )
            }
    }
}
