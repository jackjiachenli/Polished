//
//  WindowSnapper.swift
//  Polished
//
// Drag-to-edge/corner snap via CGEvent tap; requires Accessibility.
//
// Snap detection and frame calculations are adapted from Rectangle (MIT):
// https://github.com/rxhanson/Rectangle — see NOTICE at the repository root.
//

import AppKit
import ApplicationServices
import Observation

// MARK: - Snap history (unsnap-restore)

/// Tracks per-window snap state so dragging away from a snapped position can restore pre-snap size.
private final class SnapHistory {
    private var lastSnapRects: [CGWindowID: CGRect] = [:]
    private var restoreRects: [CGWindowID: CGRect] = [:]

    func restoreRect(for windowID: CGWindowID) -> CGRect? {
        restoreRects[windowID]
    }

    func setRestoreRect(windowID: CGWindowID, rect: CGRect) {
        restoreRects[windowID] = rect
    }

    func recordSnap(windowID: CGWindowID, snappedRect: CGRect) {
        lastSnapRects[windowID] = snappedRect.integral
    }

    /// Called when the user begins dragging — either restore size or remember the pre-drag rect.
    func handleDragStart(windowID: CGWindowID, initialRect: CGRect, window: AXUIElement, currentRect: CGRect, cursor: NSPoint) {
        if let lastSnap = lastSnapRects[windowID],
           isStillAtSnapPosition(lastSnap, initialRect),
           let restore = restoreRects[windowID],
           sizeDiffers(restore.size, initialRect.size) {
            WindowSnapAX.restoreSizeWhileDragging(
                window: window, currentRect: currentRect, restoreSize: restore.size, cursor: cursor
            )
            lastSnapRects.removeValue(forKey: windowID)
        } else if lastSnapRects[windowID] == nil {
            // Only seed restore when this window wasn't placed by a prior snap.
            restoreRects[windowID] = initialRect
        }
    }

    func clearIfNotSnapped(windowID: CGWindowID, initialRect: CGRect, currentRect: CGRect) {
        guard let lastSnap = lastSnapRects[windowID] else { return }
        if !rectsMatch(lastSnap, initialRect), sharedEdgeCount(lastSnap, initialRect) >= 2 {
            lastSnapRects.removeValue(forKey: windowID)
        }
        if currentRect.size != initialRect.size {
            lastSnapRects.removeValue(forKey: windowID)
        }
    }

    func removeWindow(_ windowID: CGWindowID) {
        lastSnapRects.removeValue(forKey: windowID)
        restoreRects.removeValue(forKey: windowID)
    }

    func pruneStaleEntries(visibleWindowIDs: Set<CGWindowID>) {
        for windowID in lastSnapRects.keys where !visibleWindowIDs.contains(windowID) {
            lastSnapRects.removeValue(forKey: windowID)
        }
        for windowID in restoreRects.keys where !visibleWindowIDs.contains(windowID) {
            restoreRects.removeValue(forKey: windowID)
        }
    }

    private func rectsMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        let tolerance: CGFloat = 4
        return abs(a.origin.x - b.origin.x) < tolerance
            && abs(a.origin.y - b.origin.y) < tolerance
            && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    private func isStillAtSnapPosition(_ snapped: CGRect, _ current: CGRect) -> Bool {
        if rectsMatch(snapped, current) { return true }
        return sizeDiffers(snapped.size, current.size) == false && sharedEdgeCount(snapped, current) >= 3
    }

    private func sizeDiffers(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) > 1 || abs(a.height - b.height) > 1
    }

    private func sharedEdgeCount(_ a: CGRect, _ b: CGRect) -> Int {
        var count = 0
        if abs(a.minX - b.minX) < 1 { count += 1 }
        if abs(a.maxX - b.maxX) < 1 { count += 1 }
        if abs(a.minY - b.minY) < 1 { count += 1 }
        if abs(a.maxY - b.maxY) < 1 { count += 1 }
        return count
    }
}

// MARK: - Rectangle-style snap detection & frame math
// Detection margins match Rectangle defaults, but edges are measured from `visibleFrame`
// (reachable workspace) instead of `screen.frame` (physical display).
// SnapAreaModel, CompoundSnapArea, and HalfSplitFrameCalculation.

private enum Directional: Equatable {
    case tl, t, tr, l, r, bl, b, br
}

private enum SnapAction: Equatable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case maximize
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case firstThird, centerThird, lastThird
    case firstTwoThirds, lastTwoThirds
}

private struct SnapArea: Equatable {
    let screen: NSScreen
    let directional: Directional
    let action: SnapAction
}

private enum HalfSplitSide {
    case leading, trailing
}

private enum HalfSplitFrameCalculation {
    private static let floorTolerance: CGFloat = 0.0001

    static func horizontalRect(in frame: CGRect, side: HalfSplitSide, fraction: Float) -> CGRect {
        var rect = frame
        rect.size.width = floorDimension(frame.width * CGFloat(fraction))
        if side == .trailing {
            rect.origin.x = frame.maxX - rect.width
        }
        return rect
    }

    static func verticalRect(in frame: CGRect, side: HalfSplitSide, fraction: Float) -> CGRect {
        var rect = frame
        rect.size.height = floorDimension(frame.height * CGFloat(fraction))
        if side == .leading {
            rect.origin.y = frame.maxY - rect.height
        }
        return rect
    }

    static func cornerRect(
        in frame: CGRect,
        horizontalSide: HalfSplitSide,
        verticalSide: HalfSplitSide,
        horizontalFraction: Float,
        verticalFraction: Float
    ) -> CGRect {
        let h = horizontalRect(in: frame, side: horizontalSide, fraction: horizontalFraction)
        let v = verticalRect(in: frame, side: verticalSide, fraction: verticalFraction)
        var rect = frame
        rect.origin.x = h.origin.x
        rect.size.width = h.width
        rect.origin.y = v.origin.y
        rect.size.height = v.height
        return rect
    }

    private static func floorDimension(_ value: CGFloat) -> CGFloat {
        floor(value + floorTolerance)
    }
}

private enum SnapFrameCalculation {
    private static let splitRatio: Float = 0.5

    static func frame(for action: SnapAction, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let landscape = screen.frame.width > screen.frame.height

        switch action {
        case .leftHalf:
            return HalfSplitFrameCalculation.horizontalRect(in: visible, side: .leading, fraction: splitRatio)
        case .rightHalf:
            return HalfSplitFrameCalculation.horizontalRect(in: visible, side: .trailing, fraction: splitRatio)
        case .topHalf:
            return HalfSplitFrameCalculation.verticalRect(in: visible, side: .leading, fraction: splitRatio)
        case .bottomHalf:
            return HalfSplitFrameCalculation.verticalRect(in: visible, side: .trailing, fraction: splitRatio)
        case .maximize:
            return visible
        case .topLeftQuarter:
            return HalfSplitFrameCalculation.cornerRect(
                in: visible, horizontalSide: .leading, verticalSide: .leading,
                horizontalFraction: splitRatio, verticalFraction: splitRatio
            )
        case .topRightQuarter:
            return HalfSplitFrameCalculation.cornerRect(
                in: visible, horizontalSide: .trailing, verticalSide: .leading,
                horizontalFraction: splitRatio, verticalFraction: splitRatio
            )
        case .bottomLeftQuarter:
            return HalfSplitFrameCalculation.cornerRect(
                in: visible, horizontalSide: .leading, verticalSide: .trailing,
                horizontalFraction: splitRatio, verticalFraction: splitRatio
            )
        case .bottomRightQuarter:
            return HalfSplitFrameCalculation.cornerRect(
                in: visible, horizontalSide: .trailing, verticalSide: .trailing,
                horizontalFraction: splitRatio, verticalFraction: splitRatio
            )
        case .firstThird:
            if landscape {
                var rect = visible
                rect.size.width = floor(visible.width / 3)
                return rect
            }
            var rect = visible
            rect.size.height = floor(visible.height / 3)
            rect.origin.y = visible.minY + visible.height - rect.height
            return rect
        case .centerThird:
            if landscape {
                var rect = visible
                rect.origin.x = visible.minX + floor(visible.width / 3)
                rect.size.width = visible.width / 3
                return rect
            }
            var rect = visible
            rect.origin.y = visible.minY + floor(visible.height / 3)
            rect.size.height = visible.height / 3
            return rect
        case .lastThird:
            if landscape {
                var rect = visible
                rect.size.width = floor(visible.width / 3)
                rect.origin.x = visible.minX + visible.width - rect.width
                return rect
            }
            var rect = visible
            rect.size.height = floor(visible.height / 3)
            return rect
        case .firstTwoThirds:
            if landscape {
                var rect = visible
                rect.size.width = floor(visible.width * 2 / 3)
                return rect
            }
            var rect = visible
            rect.size.height = floor(visible.height * 2 / 3)
            rect.origin.y = visible.minY + visible.height - rect.height
            return rect
        case .lastTwoThirds:
            if landscape {
                var rect = visible
                rect.size.width = floor(visible.width * 2 / 3)
                rect.origin.x = visible.minX + visible.width - rect.width
                return rect
            }
            var rect = visible
            rect.size.height = floor(visible.height * 2 / 3)
            return rect
        }
    }
}

// MARK: - Snap area resolution (Rectangle SnappingManager + compounds)
//
// Margin values match Rectangle defaults (5 px edges, 20 px corners, 145 px short-edge bands).
// Edge detection uses `visibleFrame` bounds instead of `screen.frame` so zones align with where
// the cursor can actually reach while dragging — below the menu bar / notch and above the dock.

private struct SnapEdges {
    let left: CGFloat
    let right: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    /// Workspace edges the cursor can reach while dragging windows.
    static func forScreen(_ screen: NSScreen) -> SnapEdges {
        let visible = screen.visibleFrame
        return SnapEdges(
            left: visible.minX,
            right: visible.maxX,
            top: visible.maxY,
            bottom: visible.minY
        )
    }
}

private enum SnapAreaResolver {
    static let marginTop: CGFloat = 5
    static let marginBottom: CGFloat = 5
    static let marginLeft: CGFloat = 5
    static let marginRight: CGFloat = 5
    static let cornerSize: CGFloat = 20
    static let shortEdgeSize: CGFloat = 145

    static func snapArea(at cursor: NSPoint, priorSnapArea: SnapArea?) -> SnapArea? {
        for screen in NSScreen.screens {
            guard let directional = directionalLocationOfCursor(loc: cursor, screen: screen) else { continue }

            let config = screen.frame.width > screen.frame.height
                ? landscapeConfig[directional]
                : portraitConfig[directional]

            guard let config else { continue }

            switch config {
            case .direct(let action):
                return SnapArea(screen: screen, directional: directional, action: action)
            case .leftTopBottomHalf:
                return leftTopBottomHalf(cursor: cursor, screen: screen, directional: directional)
            case .rightTopBottomHalf:
                return rightTopBottomHalf(cursor: cursor, screen: screen, directional: directional)
            case .thirds:
                return bottomThirds(cursor: cursor, screen: screen, directional: directional, prior: priorSnapArea)
            case .portraitThirdsSide:
                return portraitSideThirds(cursor: cursor, screen: screen, directional: directional, prior: priorSnapArea)
            case .halves:
                return portraitBottomHalves(cursor: cursor, screen: screen, directional: directional)
            case .none:
                continue
            }
        }
        return nil
    }

    /// Rectangle `directionalLocationOfCursor`, with edges measured from the reachable workspace.
    private static func directionalLocationOfCursor(loc: NSPoint, screen: NSScreen) -> Directional? {
        let frame = screen.frame
        let edges = SnapEdges.forScreen(screen)

        guard loc.x >= frame.minX, loc.x <= frame.maxX, loc.y >= frame.minY, loc.y <= frame.maxY else {
            return nil
        }

        if loc.x < edges.left + marginLeft + cornerSize {
            if loc.y >= edges.top - marginTop - cornerSize { return .tl }
            if loc.y <= edges.bottom + marginBottom + cornerSize { return .bl }
            if loc.x < edges.left + marginLeft { return .l }
        }

        if loc.x > edges.right - marginRight - cornerSize {
            if loc.y >= edges.top - marginTop - cornerSize { return .tr }
            if loc.y <= edges.bottom + marginBottom + cornerSize { return .br }
            if loc.x > edges.right - marginRight { return .r }
        }

        if loc.y > edges.top - marginTop { return .t }
        if loc.y < edges.bottom + marginBottom { return .b }

        return nil
    }

    private enum ConfigKind {
        case none
        case direct(SnapAction)
        case leftTopBottomHalf
        case rightTopBottomHalf
        case thirds
        case portraitThirdsSide
        case halves
    }

    private static let landscapeConfig: [Directional: ConfigKind] = [
        .tl: .direct(.topLeftQuarter),
        .t: .direct(.maximize),
        .tr: .direct(.topRightQuarter),
        .l: .leftTopBottomHalf,
        .r: .rightTopBottomHalf,
        .bl: .direct(.bottomLeftQuarter),
        .b: .thirds,
        .br: .direct(.bottomRightQuarter),
    ]

    private static let portraitConfig: [Directional: ConfigKind] = [
        .tl: .direct(.topLeftQuarter),
        .t: .direct(.maximize),
        .tr: .direct(.topRightQuarter),
        .l: .portraitThirdsSide,
        .r: .portraitThirdsSide,
        .bl: .direct(.bottomLeftQuarter),
        .b: .halves,
        .br: .direct(.bottomRightQuarter),
    ]

    private static func leftTopBottomHalf(cursor loc: NSPoint, screen: NSScreen, directional: Directional) -> SnapArea {
        let edges = SnapEdges.forScreen(screen)
        if loc.y <= edges.bottom + marginBottom + shortEdgeSize {
            return SnapArea(screen: screen, directional: directional, action: .bottomHalf)
        }
        if loc.y >= edges.top - marginTop - shortEdgeSize {
            return SnapArea(screen: screen, directional: directional, action: .topHalf)
        }
        return SnapArea(screen: screen, directional: directional, action: .leftHalf)
    }

    private static func rightTopBottomHalf(cursor loc: NSPoint, screen: NSScreen, directional: Directional) -> SnapArea {
        let edges = SnapEdges.forScreen(screen)
        if loc.y <= edges.bottom + marginBottom + shortEdgeSize {
            return SnapArea(screen: screen, directional: directional, action: .bottomHalf)
        }
        if loc.y >= edges.top - marginTop - shortEdgeSize {
            return SnapArea(screen: screen, directional: directional, action: .topHalf)
        }
        return SnapArea(screen: screen, directional: directional, action: .rightHalf)
    }

    private static func bottomThirds(cursor loc: NSPoint, screen: NSScreen, directional: Directional, prior: SnapArea?) -> SnapArea {
        let edges = SnapEdges.forScreen(screen)
        let thirdWidth = floor((edges.right - edges.left) / 3)

        if loc.x <= edges.left + thirdWidth {
            return SnapArea(screen: screen, directional: directional, action: .firstThird)
        }
        if loc.x >= edges.left + thirdWidth, loc.x <= edges.right - thirdWidth {
            if let priorAction = prior?.action {
                switch priorAction {
                case .firstThird, .firstTwoThirds:
                    return SnapArea(screen: screen, directional: directional, action: .firstTwoThirds)
                case .lastThird, .lastTwoThirds:
                    return SnapArea(screen: screen, directional: directional, action: .lastTwoThirds)
                default:
                    break
                }
            }
            return SnapArea(screen: screen, directional: directional, action: .centerThird)
        }
        return SnapArea(screen: screen, directional: directional, action: .lastThird)
    }

    private static func portraitSideThirds(cursor loc: NSPoint, screen: NSScreen, directional: Directional, prior: SnapArea?) -> SnapArea {
        let edges = SnapEdges.forScreen(screen)
        let thirdHeight = floor((edges.top - edges.bottom) / 3)

        if loc.y <= edges.bottom + marginBottom + shortEdgeSize {
            return SnapArea(screen: screen, directional: directional, action: .bottomHalf)
        }
        if loc.y >= edges.top - marginTop - shortEdgeSize {
            return SnapArea(screen: screen, directional: directional, action: .topHalf)
        }
        if loc.y >= edges.bottom, loc.y <= edges.bottom + thirdHeight {
            return SnapArea(screen: screen, directional: directional, action: .lastThird)
        }
        if loc.y >= edges.bottom + thirdHeight, loc.y <= edges.top - thirdHeight {
            if let priorAction = prior?.action {
                switch priorAction {
                case .firstThird, .firstTwoThirds:
                    return SnapArea(screen: screen, directional: directional, action: .firstTwoThirds)
                case .lastThird, .lastTwoThirds:
                    return SnapArea(screen: screen, directional: directional, action: .lastTwoThirds)
                default:
                    break
                }
            }
            return SnapArea(screen: screen, directional: directional, action: .centerThird)
        }
        return SnapArea(screen: screen, directional: directional, action: .firstThird)
    }

    private static func portraitBottomHalves(cursor loc: NSPoint, screen: NSScreen, directional: Directional) -> SnapArea {
        let edges = SnapEdges.forScreen(screen)
        let halfHeight = floor((edges.top - edges.bottom) / 2)

        if loc.y <= edges.bottom + marginBottom + shortEdgeSize {
            return SnapArea(screen: screen, directional: directional, action: .bottomHalf)
        }
        if loc.y >= edges.top - marginTop - shortEdgeSize {
            return SnapArea(screen: screen, directional: directional, action: .topHalf)
        }
        if loc.y >= edges.bottom, loc.y <= edges.bottom + halfHeight {
            return SnapArea(screen: screen, directional: directional, action: .bottomHalf)
        }
        return SnapArea(screen: screen, directional: directional, action: .topHalf)
    }
}

// MARK: - Footprint overlay (Rectangle-style drag preview)

private final class FootprintWindow: NSWindow {
    private var orderOutCanceled = false
    private var isFadingOut = false

    private static let footprintAlpha: CGFloat = 0.3
    private static let borderWidth: CGFloat = 2
    private static let fadeDuration: TimeInterval = 0.2
    private static let fadeEnabled = true
    private static let animateResize = true

    var shouldFadeOut: Bool {
        isVisible && alphaValue > 0.01
    }

    init() {
        super.init(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)

        title = "Polished"
        isOpaque = false
        level = .modalPanel
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        alphaValue = Self.fadeEnabled ? 0 : Self.footprintAlpha

        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior.insert(.transient)

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.toolbarButton)?.isHidden = true

        let boxView = NSBox()
        boxView.boxType = .custom
        boxView.borderColor = .lightGray
        boxView.borderWidth = Self.borderWidth
        if #available(macOS 26.0, *) {
            boxView.cornerRadius = 16
        } else {
            boxView.cornerRadius = 10
        }
        boxView.fillColor = .black
        contentView = boxView
    }

    func show(at target: NSRect, directional: Directional) {
        if Self.animateResize {
            if !isFootprintVisible {
                let origin = Self.animationOrigin(for: directional, in: target)
                setFrame(CGRect(origin: origin, size: .zero), display: false)
            }
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { _ in
                self.animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
            orderFront(nil)
        }
    }

    func fadeOut() {
        orderOut(nil)
    }

    func dismissImmediately() {
        orderOutCanceled = true
        isFadingOut = false
        alphaValue = 0
        super.orderOut(nil)
    }

    private var isFootprintVisible: Bool {
        if Self.fadeEnabled {
            return alphaValue >= Self.footprintAlpha - 0.01
        }
        return isVisible
    }

    override func orderFront(_ sender: Any?) {
        if Self.fadeEnabled {
            orderOutCanceled = true
            isFadingOut = false
            super.orderFront(sender)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                self.animator().alphaValue = Self.footprintAlpha
            }
        } else {
            alphaValue = Self.footprintAlpha
            super.orderFront(sender)
        }
    }

    override func orderOut(_ sender: Any?) {
        if Self.fadeEnabled {
            guard shouldFadeOut, !isFadingOut else {
                if !isVisible { return }
                super.orderOut(nil)
                return
            }
            isFadingOut = true
            orderOutCanceled = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                self.animator().alphaValue = 0
            } completionHandler: {
                self.isFadingOut = false
                if !self.orderOutCanceled {
                    super.orderOut(nil)
                }
            }
        } else {
            super.orderOut(nil)
        }
    }

    static func animationOrigin(for directional: Directional, in boxRect: CGRect) -> CGPoint {
        switch directional {
        case .tl: return CGPoint(x: boxRect.minX, y: boxRect.maxY)
        case .t: return CGPoint(x: boxRect.midX, y: boxRect.maxY)
        case .tr: return CGPoint(x: boxRect.maxX, y: boxRect.maxY)
        case .l: return CGPoint(x: boxRect.minX, y: boxRect.midY)
        case .r: return CGPoint(x: boxRect.maxX, y: boxRect.midY)
        case .bl: return CGPoint(x: boxRect.minX, y: boxRect.minY)
        case .b: return CGPoint(x: boxRect.midX, y: boxRect.minY)
        case .br: return CGPoint(x: boxRect.maxX, y: boxRect.minY)
        }
    }
}

// MARK: - Snap-specific AX helpers

private enum WindowSnapAX {
    static func windowBeingDragged(at point: NSPoint) -> AXUIElement? {
        if let hit = windowAtCursor(point) { return hit }
        return focusedSnappableWindow()
    }

    static func focusedSnappableWindow() -> AXUIElement? {
        guard let app = WindowAccessibility.frontmostRegularApplication() else { return nil }
        guard let window = WindowAccessibility.focusedWindow(in: app) else { return nil }
        return isSnappable(window) ? window : nil
    }

    static func windowAtCursor(_ point: NSPoint) -> AXUIElement? {
        guard let window = WindowAccessibility.windowAtCursor(point) else { return nil }
        return isSnappable(window) ? window : nil
    }

    static func isSnappable(_ window: AXUIElement) -> Bool {
        if WindowAccessibility.isFullScreen(window) { return false }
        guard WindowAccessibility.isStandardWindow(window) else { return false }
        if WindowAccessibility.isMinimized(window) { return false }
        return WindowAccessibility.hasSettableFrame(window)
    }

    static func frontWindowIsFullScreen() -> Bool {
        guard let window = focusedSnappableWindow() else { return false }
        return WindowAccessibility.isFullScreen(window)
    }

    static func restoreSizeWhileDragging(
        window: AXUIElement,
        currentRect: CGRect,
        restoreSize: CGSize,
        cursor: NSPoint
    ) {
        var newRect = currentRect
        newRect.size = restoreSize
        if !newRect.contains(cursor) {
            newRect.origin.x = currentRect.maxX - newRect.width
            if !newRect.contains(cursor) {
                newRect.origin.x = cursor.x - newRect.width / 2
            }
        }
        if !newRect.contains(cursor) {
            newRect.origin.y = currentRect.maxY - newRect.height
            if !newRect.contains(cursor) {
                newRect.origin.y = cursor.y - newRect.height / 2
            }
        }
        WindowAccessibility.setFrame(newRect, on: window)
    }
}

// MARK: - WindowSnapper module

@Observable
final class WindowSnapper: Module {
    let id = "window-snapper"
    var name = "Window Snapper"
    var isEnabled = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?

    private let snapHistory = SnapHistory()

    private var capturedWindow: AXUIElement?
    private var capturedWindowID: CGWindowID?
    private var capturedAppPID: pid_t?
    private var dragOrigin: NSPoint?
    private var initialWindowRect: CGRect?
    private var isDragging = false
    private var windowMoving = false
    private var pendingSnapArea: SnapArea?

    private var footprint: FootprintWindow?
    private var footprintSnapArea: SnapArea?

    private var windowCaptureAttempts = 0
    private var lastWindowCaptureTimestamp: TimeInterval?
    private var snappingDisabled = false
    private var dragDispatchScheduled = false
    private var pendingDragLocation: NSPoint?
    private var dragEndCount = 0

    private let dragThreshold: CGFloat = 5
    private let maxWindowCaptureAttempts = 20
    private let windowCaptureRetryInterval: TimeInterval = 0.1
    private let snapPruneInterval = 10

    func start() {
        guard AXIsProcessTrusted() else {
            print("WindowSnapper: Accessibility not granted — enable in System Settings")
            return
        }
        guard eventTap == nil else { return }

        registerWorkspaceObserver()
        updateFullScreenState()

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: windowSnapperEventCallback,
            userInfo: refcon
        ) else {
            print("WindowSnapper: Failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        footprint?.dismissImmediately()
        footprint = nil
        resetDragSession()
    }

    private func registerWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateFullScreenState()
        }
    }

    private func updateFullScreenState() {
        snappingDisabled = WindowSnapAX.frontWindowIsFullScreen()
    }

    fileprivate func enqueueEvent(type: CGEventType, at location: NSPoint) {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            dragDispatchScheduled = false
            pendingDragLocation = nil
            handleEvent(type: type, at: location)
        case .leftMouseDragged:
            pendingDragLocation = location
            guard !dragDispatchScheduled else { return }
            dragDispatchScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dragDispatchScheduled = false
                guard let location = self.pendingDragLocation else { return }
                self.pendingDragLocation = nil
                self.handleEvent(type: .leftMouseDragged, at: location)
            }
        default:
            break
        }
    }

    fileprivate func handleEvent(type: CGEventType, at location: NSPoint) {
        switch type {
        case .leftMouseDown:
            onMouseDown(at: location)
        case .leftMouseDragged:
            onMouseDragged(at: location)
        case .leftMouseUp:
            onMouseUp(at: location)
        default:
            break
        }
    }

    private func onMouseDown(at point: NSPoint) {
        resetDragSession()
        guard !snappingDisabled else { return }

        dragOrigin = point
        windowCaptureAttempts = 0
        lastWindowCaptureTimestamp = nil
        captureWindow(at: point)
    }

    private func captureWindow(at point: NSPoint) {
        capturedWindow = WindowSnapAX.windowBeingDragged(at: point)
        if let window = capturedWindow {
            capturedWindowID = WindowAccessibility.windowID(of: window)
            if capturedWindowID == nil {
                capturedWindow = nil
            } else {
                var pid: pid_t = 0
                if AXUIElementGetPid(window, &pid) == .success {
                    capturedAppPID = pid
                }
                initialWindowRect = WindowAccessibility.frame(of: window)
            }
        }
    }

    private func tryCaptureWindowIfNeeded(at point: NSPoint) {
        guard capturedWindow == nil, windowCaptureAttempts < maxWindowCaptureAttempts else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if let lastAttempt = lastWindowCaptureTimestamp,
           now - lastAttempt < windowCaptureRetryInterval {
            return
        }

        captureWindow(at: point)
        windowCaptureAttempts += 1
        lastWindowCaptureTimestamp = now
    }

    private func onMouseDragged(at point: NSPoint) {
        guard !snappingDisabled else { return }
        guard let origin = dragOrigin else { return }

        tryCaptureWindowIfNeeded(at: point)
        guard capturedWindow != nil else { return }

        if !isDragging {
            guard hypot(point.x - origin.x, point.y - origin.y) >= dragThreshold else { return }
            updateFullScreenState()
            guard !snappingDisabled else { return }
            isDragging = true
        }

        guard frontmostPID == capturedAppPID else {
            resetDragSession()
            hideFootprint()
            return
        }

        guard let window = capturedWindow, let currentRect = WindowAccessibility.frame(of: window) else { return }

        if !windowMoving {
            if let initial = initialWindowRect,
               currentRect.size == initial.size || sharedEdgeCount(currentRect, initial) < 2,
               currentRect.origin != initial.origin {
                windowMoving = true
                if let windowID = capturedWindowID ?? WindowAccessibility.windowID(of: window) {
                    capturedWindowID = windowID
                    snapHistory.handleDragStart(
                        windowID: windowID,
                        initialRect: initial,
                        window: window,
                        currentRect: currentRect,
                        cursor: point
                    )
                }
            } else if let windowID = capturedWindowID, let initial = initialWindowRect {
                snapHistory.clearIfNotSnapped(windowID: windowID, initialRect: initial, currentRect: currentRect)
                return
            } else {
                return
            }
        }

        if let snapArea = SnapAreaResolver.snapArea(at: point, priorSnapArea: pendingSnapArea) {
            pendingSnapArea = snapArea
            updateFootprint(for: snapArea)
        } else {
            pendingSnapArea = nil
            hideFootprint()
        }
    }

    private func updateFootprint(for snapArea: SnapArea) {
        guard snapArea != footprintSnapArea else { return }

        let target = SnapFrameCalculation.frame(for: snapArea.action, on: snapArea.screen)
        if footprint == nil {
            footprint = FootprintWindow()
        }
        footprint?.show(at: target, directional: snapArea.directional)
        footprintSnapArea = snapArea
    }

    private func hideFootprint() {
        guard footprintSnapArea != nil else { return }
        footprintSnapArea = nil
        footprint?.fadeOut()
    }

    private func dismissFootprint() {
        footprintSnapArea = nil
        guard footprint?.shouldFadeOut == true else { return }
        footprint?.fadeOut()
    }

    private func onMouseUp(at point: NSPoint) {
        defer {
            dismissFootprint()
            resetDragSession()
        }

        guard !snappingDisabled,
              let window = capturedWindow,
              WindowSnapAX.isSnappable(window) else { return }

        if let snapArea = pendingSnapArea {
            applySnap(snapArea, to: window)
            return
        }

        // Mouse-up fallback: fast drag-drop may skip drag events in the snap zone.
        guard let currentRect = WindowAccessibility.frame(of: window),
              let initial = initialWindowRect,
              currentRect.size == initial.size,
              currentRect.origin != initial.origin else { return }

        if !windowMoving, let windowID = capturedWindowID ?? WindowAccessibility.windowID(of: window) {
            snapHistory.handleDragStart(
                windowID: windowID,
                initialRect: initial,
                window: window,
                currentRect: currentRect,
                cursor: point
            )
        }

        if let snapArea = SnapAreaResolver.snapArea(at: point, priorSnapArea: nil) {
            applySnap(snapArea, to: window)
        }
    }

    private func applySnap(_ snapArea: SnapArea, to window: AXUIElement) {
        let windowID = capturedWindowID ?? WindowAccessibility.windowID(of: window)
        if let windowID {
            capturedWindowID = windowID
            if let preSnap = initialWindowRect {
                snapHistory.setRestoreRect(windowID: windowID, rect: preSnap)
            }
        }

        let target = SnapFrameCalculation.frame(for: snapArea.action, on: snapArea.screen)
        WindowAccessibility.setFrame(target, on: window)

        if let windowID {
            let snapped = WindowAccessibility.frame(of: window) ?? target
            snapHistory.recordSnap(windowID: windowID, snappedRect: snapped)
        }
    }

    private func resetDragSession() {
        dragEndCount += 1
        if dragEndCount.isMultiple(of: snapPruneInterval) {
            snapHistory.pruneStaleEntries(visibleWindowIDs: WindowAccessibility.onScreenWindowIDs())
        }
        capturedWindow = nil
        capturedWindowID = nil
        capturedAppPID = nil
        dragOrigin = nil
        initialWindowRect = nil
        isDragging = false
        windowMoving = false
        pendingSnapArea = nil
        windowCaptureAttempts = 0
        lastWindowCaptureTimestamp = nil
    }

    private func sharedEdgeCount(_ a: CGRect, _ b: CGRect) -> Int {
        var count = 0
        if abs(a.minX - b.minX) < 1 { count += 1 }
        if abs(a.maxX - b.maxX) < 1 { count += 1 }
        if abs(a.minY - b.minY) < 1 { count += 1 }
        if abs(a.maxY - b.maxY) < 1 { count += 1 }
        return count
    }

    private var frontmostPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

// MARK: - CGEvent tap callback

private func windowSnapperEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let snapper = Unmanaged<WindowSnapper>.fromOpaque(refcon).takeUnretainedValue()
        if let tap = snapper.eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let snapper = Unmanaged<WindowSnapper>.fromOpaque(refcon).takeUnretainedValue()
    let location = NSEvent.mouseLocation
    DispatchQueue.main.async {
        snapper.enqueueEvent(type: type, at: location)
    }
    return Unmanaged.passUnretained(event)
}

private extension WindowSnapper {
    var eventTapPort: CFMachPort? { eventTap }
}
