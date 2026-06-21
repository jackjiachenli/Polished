//
//  WindowSwitcher.swift
//  Polished
//
// Alt+Tab-style window switcher (overlay and event tap in later phases).
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
        }
    }

    var hotkeyDisplayString: String { hotkeyBinding.displayString }

    var includeMinimized: Bool {
        didSet {
            guard includeMinimized != oldValue else { return }
            UserDefaults.standard.set(includeMinimized, forKey: Self.includeMinimizedKey)
            if isEnabled {
                refreshSwitchableWindows()
            }
        }
    }

    private(set) var switchableWindows: [SwitchableWindow] = []

    private let mru = WindowMRU()
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
    }

    func stop() {
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
        })
    }

    private func handleApplicationActivated() {
        mru.scheduleFocusUpdate { [weak self] in
            self?.recordFocusedWindow()
            self?.refreshSwitchableWindows()
        }
    }

    private func recordFocusedWindow() {
        guard let app = WindowAccessibility.frontmostRegularApplication() else { return }
        guard let window = WindowAccessibility.focusedWindow(in: app),
              WindowAccessibility.isStandardWindow(window),
              !WindowAccessibility.isFullScreen(window) else { return }
        guard let windowID = WindowAccessibility.windowID(of: window) else { return }
        mru.recordFocus(windowID: windowID)
        PolishedLog.debug("WindowSwitcher: MRU focus recorded for window \(windowID)")
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
