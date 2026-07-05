//
//  SettingsView.swift
//  Polished
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(ModuleManager.self) private var moduleManager
    @State private var axGranted = AccessibilityPermission.isGranted
    @State private var inputMonitoringGranted = InputMonitoringPermission.isGranted
    @State private var automationGranted = AutomationPermission.isGranted
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var showRestartAlert = false
    @State private var launchAtLoginError: String?

    private static let moduleDescriptions: [String: String] = [
        "app-quitter": "Quits apps when their last window is closed",
        "window-snapper": "Snaps windows to screen edges and corners when dragged",
        "window-switcher": "Switch windows with a hold-to-cycle overlay (⌥Tab)",
        "clipboard-history": "Keeps a history of copied text, images, and files",
        "finder-enhancements": "Explorer-like improvements for Finder",
    ]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchAtLoginEnabled = LaunchAtLogin.isEnabled
                        } catch {
                            launchAtLoginError = error.localizedDescription
                            launchAtLoginEnabled = LaunchAtLogin.isEnabled
                        }
                    }
                ))
                Text("Install Polished in the Applications folder for reliable Launch at Login behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Modules") {
                if moduleManager.enabledModuleIDs.isEmpty {
                    Text("Enable one or more modules below. Grant Accessibility (and Input Monitoring for Window Switcher / Finder Cut) under Permissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(moduleManager.modules, id: \.id) { module in
                    Toggle(isOn: Binding(
                        get: { moduleManager.isEnabled(module) },
                        set: { moduleManager.setEnabled($0, for: module) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.name)
                            if let description = Self.moduleDescriptions[module.id] {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if moduleManager.isEnabled(moduleManager.clipboardHistory) {
                Section("Clipboard History") {
                    Toggle("Enable global hotkey", isOn: Binding(
                        get: { moduleManager.clipboardHistory.useGlobalHotkey },
                        set: { moduleManager.clipboardHistory.useGlobalHotkey = $0 }
                    ))
                    LabeledContent("Shortcut") {
                        HotkeyRecorder(binding: Binding(
                            get: { moduleManager.clipboardHistory.hotkeyBinding },
                            set: { moduleManager.clipboardHistory.hotkeyBinding = $0 }
                        ))
                    }
                    .disabled(!moduleManager.clipboardHistory.useGlobalHotkey)

                    Toggle("Remember history across restarts", isOn: Binding(
                        get: { moduleManager.clipboardHistory.persistHistory },
                        set: { moduleManager.clipboardHistory.persistHistory = $0 }
                    ))

                    Stepper(
                        value: Binding(
                            get: { moduleManager.clipboardHistory.maxItems },
                            set: { moduleManager.clipboardHistory.maxItems = $0 }
                        ),
                        in: 5...100,
                        step: 5
                    ) {
                        Text("Max items: \(moduleManager.clipboardHistory.maxItems)")
                    }
                    Toggle("Ignore concealed copies (password fields)", isOn: Binding(
                        get: { moduleManager.clipboardHistory.ignoreConcealed },
                        set: { moduleManager.clipboardHistory.ignoreConcealed = $0 }
                    ))
                    Toggle("Ignore copies from password managers", isOn: Binding(
                        get: { moduleManager.clipboardHistory.ignoreSensitiveApps },
                        set: { moduleManager.clipboardHistory.ignoreSensitiveApps = $0 }
                    ))
                    Text("Password managers mark copies as concealed. Turn off both ignore options above to test capturing them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Opens a floating picker with \(moduleManager.clipboardHistory.hotkeyDisplayString). Uses Accessibility to simulate ⌘V when you paste a selected item. No Input Monitoring required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if moduleManager.isEnabled(moduleManager.windowSwitcher) {
                Section("Window Switcher") {
                    LabeledContent("Shortcut") {
                        HotkeyRecorder(binding: Binding(
                            get: { moduleManager.windowSwitcher.hotkeyBinding },
                            set: { moduleManager.windowSwitcher.hotkeyBinding = $0 }
                        ))
                    }
                    Toggle("Include minimized windows", isOn: Binding(
                        get: { moduleManager.windowSwitcher.includeMinimized },
                        set: { moduleManager.windowSwitcher.includeMinimized = $0 }
                    ))
                    Text("Hold \(moduleManager.windowSwitcher.hotkeyDisplayString) to cycle windows, click a card to switch, or release the modifier to confirm. Requires Accessibility and Input Monitoring.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if moduleManager.isEnabled(moduleManager.finderEnhancements) {
                Section("Finder Enhancements") {
                    Toggle("Cut", isOn: Binding(
                        get: { moduleManager.finderEnhancements.cutEnabled },
                        set: { moduleManager.finderEnhancements.cutEnabled = $0 }
                    ))
                    Text("⌘X marks selected files for move; ⌘V in a destination folder moves them instead of copying. Esc clears the cut mark.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Requires Accessibility and Input Monitoring. Paste destination may also need Automation permission to control Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(axGranted ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(axGranted ? "Granted" : "Not granted")
                            .foregroundStyle(.secondary)
                    }
                }
                if !axGranted {
                    Button("Open Accessibility Settings") {
                        AccessibilityPermission.openSystemSettings()
                    }
                }
                LabeledContent("Input Monitoring") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(inputMonitoringGranted ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(inputMonitoringGranted ? "Granted" : "Not granted")
                            .foregroundStyle(.secondary)
                    }
                }
                if !inputMonitoringGranted {
                    Button("Open Input Monitoring Settings") {
                        InputMonitoringPermission.openSystemSettings()
                    }
                }
                LabeledContent("Automation (Finder)") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(automationGranted ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(automationGranted ? "Granted" : "Not granted")
                            .foregroundStyle(.secondary)
                    }
                }
                if !automationGranted {
                    Button("Open Automation Settings") {
                        AutomationPermission.openSystemSettings()
                    }
                }
                Text("Window Switcher and Finder Cut need Input Monitoring. Finder Cut may also need Automation — enable Finder Cut and approve the prompt when macOS asks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("After changing permissions, quit and reopen Polished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 520)
        .onAppear {
            AppActivation.activateForWindowPresentation()
            refreshPermissionStatus()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .alert("Launch at Login", isPresented: Binding(
            get: { launchAtLoginError != nil },
            set: { if !$0 { launchAtLoginError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(launchAtLoginError ?? "")
        }
        .alert("Restart Polished", isPresented: $showRestartAlert) {
            Button("Quit Polished") {
                NSApplication.shared.terminate(nil)
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Permission changes take full effect after you quit and reopen Polished.")
        }
    }

    private func refreshPermissionStatus() {
        let axNow = AccessibilityPermission.isGranted
        let inputNow = InputMonitoringPermission.isGranted
        let automationNow = AutomationPermission.isGranted

        if (axNow && !axGranted) || (inputNow && !inputMonitoringGranted) {
            showRestartAlert = true
        }

        axGranted = axNow
        inputMonitoringGranted = inputNow
        automationGranted = automationNow
        launchAtLoginEnabled = LaunchAtLogin.isEnabled

        if moduleManager.isEnabled(moduleManager.finderEnhancements) {
            moduleManager.finderEnhancements.start()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(ModuleManager.shared)
}
