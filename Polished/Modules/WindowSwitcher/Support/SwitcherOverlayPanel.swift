//
//  SwitcherOverlayPanel.swift
//  Polished
//

import AppKit
import SwiftUI

enum SwitcherOverlayLayout {
    static let cardWidth: CGFloat = 184
    static let cardSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 18
    static let previewHeight: CGFloat = 112
    static let footerHeight: CGFloat = 44
    static let cardCornerRadius: CGFloat = 10
    static let containerCornerRadius: CGFloat = 16
    static let selectedScale: CGFloat = 1.06

    static var cardHeight: CGFloat { previewHeight + footerHeight }

    static func panelWidth(for windowCount: Int) -> CGFloat {
        let count = CGFloat(max(windowCount, 1))
        let cards = count * cardWidth + max(0, count - 1) * cardSpacing
        let natural = cards + horizontalPadding * 2
        let maxWidth = WindowAccessibility.screenForSwitcherOverlay().visibleFrame.width * 0.88
        return min(natural, maxWidth)
    }

    static func panelHeight(for windowCount: Int) -> CGFloat {
        verticalPadding * 2 + cardHeight * selectedScale + 4
    }

    static func panelSize(for windowCount: Int) -> NSSize {
        NSSize(width: panelWidth(for: windowCount), height: panelHeight(for: windowCount))
    }
}

@MainActor
final class SwitcherOverlayPanel {
    private var panel: SwitcherFloatingPanel?
    private var hostingView: NSHostingView<SwitcherOverlayView>?

    func show(windows: [SwitchableWindow], selectedIndex: Int) {
        updateContent(windows: windows, selectedIndex: selectedIndex)
        guard let panel else { return }
        panel.orderFrontRegardless()
    }

    func update(windows: [SwitchableWindow], selectedIndex: Int) {
        updateContent(windows: windows, selectedIndex: selectedIndex)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    private func updateContent(windows: [SwitchableWindow], selectedIndex: Int) {
        let screen = WindowAccessibility.screenForSwitcherOverlay()
        let content = SwitcherOverlayView(windows: windows, selectedIndex: selectedIndex)

        if panel == nil {
            panel = SwitcherFloatingPanel()
        }

        let size = SwitcherOverlayLayout.panelSize(for: windows.count)

        if let hostingView {
            hostingView.rootView = content
            hostingView.frame = NSRect(origin: .zero, size: size)
        } else {
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: size)
            hostingView = hosting
            panel?.contentView = hosting
        }

        guard let panel else { return }
        panel.setContentSize(size)
        center(panel, on: screen)
    }

    private func center(_ panel: NSPanel, on screen: NSScreen) {
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

private final class SwitcherFloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 180),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SwitcherOverlayView: View {
    let windows: [SwitchableWindow]
    let selectedIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: SwitcherOverlayLayout.cardSpacing) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        SwitcherWindowCard(
                            window: window,
                            isSelected: index == selectedIndex
                        )
                        .id(window.id)
                    }
                }
                .padding(.horizontal, SwitcherOverlayLayout.horizontalPadding)
                .padding(.vertical, SwitcherOverlayLayout.verticalPadding)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard windows.indices.contains(newIndex) else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                    proxy.scrollTo(windows[newIndex].id, anchor: .center)
                }
            }
            .onAppear {
                guard windows.indices.contains(selectedIndex) else { return }
                proxy.scrollTo(windows[selectedIndex].id, anchor: .center)
            }
        }
        .frame(
            width: SwitcherOverlayLayout.panelWidth(for: windows.count),
            height: SwitcherOverlayLayout.panelHeight(for: windows.count)
        )
        .background {
            RoundedRectangle(cornerRadius: SwitcherOverlayLayout.containerCornerRadius, style: .continuous)
                .fill(.black.opacity(0.55))
                .background {
                    RoundedRectangle(cornerRadius: SwitcherOverlayLayout.containerCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        }
    }
}

private struct SwitcherWindowCard: View {
    let window: SwitchableWindow
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            footerBar
        }
        .frame(width: SwitcherOverlayLayout.cardWidth, height: SwitcherOverlayLayout.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: SwitcherOverlayLayout.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SwitcherOverlayLayout.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.white.opacity(0.12),
                    lineWidth: isSelected ? 2.5 : 1
                )
        }
        .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear, radius: 10, y: 2)
        .scaleEffect(isSelected ? SwitcherOverlayLayout.selectedScale : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
        .zIndex(isSelected ? 1 : 0)
    }

    private var previewArea: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(white: 0.22),
                    Color(white: 0.14),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if window.isMinimized {
                previewBadge("Minimized", systemImage: "minus.circle.fill")
            } else if window.isFullScreen {
                previewBadge("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .frame(height: SwitcherOverlayLayout.previewHeight)
    }

    private var footerBar: some View {
        HStack(spacing: 6) {
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.95))

                Text(window.appName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: SwitcherOverlayLayout.footerHeight)
        .background(Color(white: 0.12))
    }

    private func previewBadge(_ label: String, systemImage: String) -> some View {
        VStack {
            HStack {
                Spacer()
                Label(label, systemImage: systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(6)
            }
            Spacer()
        }
    }

    private var displayTitle: String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return window.appName
    }
}
