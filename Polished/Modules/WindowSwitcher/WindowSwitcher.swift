//
//  WindowSwitcher.swift
//  Polished
//
// Alt+Tab-style window switcher with hold-to-cycle overlay.
//

import AppKit
import Carbon
import Observation

@Observable
final class WindowSwitcher: Module {
    let id = "window-switcher"
    var name = "Window Switcher"
    var isEnabled = false

    var hotkeyBinding: HotkeyBinding {
        didSet {
            guard hotkeyBinding != oldValue else { return }
            saveHotkeyBinding()
            eventTap?.updateBinding(hotkeyBinding)
        }
    }

    var hotkeyDisplayString: String { hotkeyBinding.displayString }

    var includeMinimized: Bool {
        didSet {
            guard includeMinimized != oldValue else { return }
            UserDefaults.standard.set(includeMinimized, forKey: Self.includeMinimizedKey)
            if isEnabled {
                refreshSwitchableWindows()
                if isOverlayOpen {
                    overlayPanel.update(windows: switchableWindows, selectedIndex: selectedIndex)
                }
            }
        }
    }

    private(set) var switchableWindows: [SwitchableWindow] = []
    private(set) var isOverlayOpen = false
    private(set) var selectedIndex = 0

    private let mru = WindowMRU()
    private let overlayPanel = SwitcherOverlayPanel()
    private var eventTap: SwitcherEventTap?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        hotkeyBinding = Self.loadHotkeyBinding()
        includeMinimized = UserDefaults.standard.object(forKey: Self.includeMinimizedKey) as? Bool ?? true
    }

    func start() {
        guard AXIsProcessTrusted() else {
            print("WindowSwitcher: Accessibility not granted — enable in System Settings")
            return
        }
        guard workspaceObservers.isEmpty else { return }

        registerWorkspaceObservers()
        refreshSwitchableWindows()
        recordFocusedWindow()

        let tap = SwitcherEventTap(binding: hotkeyBinding)
        tap.delegate = self
        tap.start()
        eventTap = tap
    }

    func stop() {
        dismissOverlay()
        eventTap?.stop()
        eventTap = nil

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        mru.cancelPendingFocusUpdate()
    }

    func refreshSwitchableWindows() {
        let windows = WindowEnumerator.switchableWindows(includeMinimized: includeMinimized)
        let validIDs = Set(windows.map(\.windowID))
        mru.pruneMissing(validWindowIDs: validIDs)
        switchableWindows = mru.orderedWindows(from: windows)
    }

    var mruOrderedWindows: [SwitchableWindow] {
        switchableWindows
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationActivated()
        })

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSwitchableWindows()
            self?.handleWindowsChangedWhileOverlayOpen()
        })
    }

    private func handleApplicationActivated() {
        guard !isOverlayOpen else { return }
        mru.scheduleFocusUpdate { [weak self] in
            self?.recordFocusedWindow()
            self?.refreshSwitchableWindows()
        }
    }

    private func recordFocusedWindow() {
        guard let app = WindowAccessibility.frontmostRegularApplication() else { return }
        guard let window = WindowAccessibility.focusedWindow(in: app),
              WindowAccessibility.isStandardWindow(window) else { return }
        guard let windowID = WindowAccessibility.windowID(of: window) else { return }
        mru.recordFocus(windowID: windowID)
        PolishedLog.debug("WindowSwitcher: MRU focus recorded for window \(windowID)")
    }

    private func openOverlay() {
        refreshSwitchableWindows()
        guard !switchableWindows.isEmpty else { return }

        selectedIndex = switchableWindows.count > 1 ? 1 : 0
        isOverlayOpen = true
        overlayPanel.show(windows: switchableWindows, selectedIndex: selectedIndex)
        PolishedLog.debug("WindowSwitcher: Overlay opened with \(switchableWindows.count) window(s)")
    }

    private func advanceSelection() {
        guard isOverlayOpen, !switchableWindows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % switchableWindows.count
        overlayPanel.update(windows: switchableWindows, selectedIndex: selectedIndex)
    }

    private func confirmSelection() {
        guard isOverlayOpen else { return }
        let index = min(selectedIndex, switchableWindows.count - 1)
        guard switchableWindows.indices.contains(index) else {
            dismissOverlay()
            return
        }

        let window = switchableWindows[index]
        isOverlayOpen = false
        overlayPanel.dismiss()

        WindowFocus.raise(window)
        mru.recordFocus(windowID: window.windowID)
        refreshSwitchableWindows()
        PolishedLog.debug("WindowSwitcher: Confirmed switch to window \(window.windowID)")
    }

    private func dismissOverlay() {
        guard isOverlayOpen else { return }
        isOverlayOpen = false
        overlayPanel.dismiss()
        PolishedLog.debug("WindowSwitcher: Overlay dismissed")
    }

    private func handleWindowsChangedWhileOverlayOpen() {
        guard isOverlayOpen else { return }
        refreshSwitchableWindows()
        guard !switchableWindows.isEmpty else {
            dismissOverlay()
            return
        }
        if selectedIndex >= switchableWindows.count {
            selectedIndex = switchableWindows.count > 1 ? 1 : 0
        }
        overlayPanel.update(windows: switchableWindows, selectedIndex: selectedIndex)
    }

    private static let hotkeyBindingKey = "windowSwitcherHotkeyBinding"
    private static let includeMinimizedKey = "windowSwitcherIncludeMinimized"

    private static func loadHotkeyBinding() -> HotkeyBinding {
        guard let data = UserDefaults.standard.data(forKey: hotkeyBindingKey),
              let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data),
              binding.isValid else {
            return .windowSwitcherDefault
        }
        return binding
    }

    private func saveHotkeyBinding() {
        guard let data = try? JSONEncoder().encode(hotkeyBinding) else { return }
        UserDefaults.standard.set(data, forKey: Self.hotkeyBindingKey)
    }
}

extension WindowSwitcher: SwitcherEventTapDelegate {
    var isSwitcherOverlayOpen: Bool { isOverlayOpen }

    func switcherEventTapDidOpenOverlay() {
        openOverlay()
    }

    func switcherEventTapDidAdvanceSelection() {
        advanceSelection()
    }

    func switcherEventTapDidConfirmSelection() {
        confirmSelection()
    }

    func switcherEventTapDidCancel() {
        dismissOverlay()
    }
}
