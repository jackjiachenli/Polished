//
//  ClipboardPickerPanel.swift
//  Polished
//

import AppKit
import SwiftUI

struct ClipboardPickerView: View {
    @Bindable var history: ClipboardHistory
    @State private var copiedItemID: UUID?
    @State private var copiedFeedbackTask: Task<Void, Never>?
    @State private var savedPasteTarget: NSRunningApplication?
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Form {
                Section {
                    if history.items.isEmpty {
                        ContentUnavailableView(
                            "No clipboard items",
                            systemImage: "doc.on.clipboard",
                            description: Text("Copy something to build your history.")
                        )
                    } else {
                        ForEach(history.items) { item in
                            ClipboardPickerRow(
                                item: item,
                                isSelected: history.selectedItemID == item.id,
                                showCopied: copiedItemID == item.id,
                                onSelect: { history.selectedItemID = item.id },
                                onPaste: { paste(item) },
                                onCopy: { copyItem(item) },
                                onDelete: { history.deleteItem(item) }
                            )
                        }
                    }
                }
                Section {
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
                        Button("Cancel") {
                            history.setPickerPresented(false)
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .formStyle(.grouped)

            if copiedItemID != nil {
                CopiedFeedbackBanner()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .frame(width: 420, height: 360)
        .focused($isFocused)
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            capturePasteTarget()
        }
        .onDisappear {
            if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "settings" && $0.isVisible }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier?.rawValue == "clipboard-picker" else { return }
            capturePasteTarget()
        }
        .onKeyPress(.escape) {
            history.setPickerPresented(false)
            return .handled
        }
        .onKeyPress(.upArrow) {
            history.movePickerSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            history.movePickerSelection(delta: 1)
            return .handled
        }
        .onKeyPress(.return) {
            pasteSelectedItem()
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            history.deleteSelectedItem()
            return .handled
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: copiedItemID)
    }

    private func paste(_ item: ClipboardItem) {
        history.paste(item, activating: pasteTargetForPaste())
        history.setPickerPresented(false)
    }

    private func pasteSelectedItem() {
        history.pasteSelectedPickerItem(activating: pasteTargetForPaste())
        history.setPickerPresented(false)
    }

    private func capturePasteTarget() {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        }
        .padding(.horizontal, 4)
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
