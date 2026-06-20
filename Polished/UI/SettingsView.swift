//
//  SettingsView.swift
//  Polished
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(ModuleManager.self) private var moduleManager
    @State private var axGranted = AccessibilityPermission.isGranted

    private static let moduleDescriptions: [String: String] = [
        "app-quitter": "Quits apps when their last window is closed",
        "window-snapper": "Snaps windows to screen edges and corners when dragged",
        "clipboard-history": "Keeps a history of copied text, images, and files",
    ]

    var body: some View {
        Form {
            Section("Modules") {
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
                    Text("Opens a floating picker with \(moduleManager.clipboardHistory.hotkeyDisplayString). Uses Accessibility to simulate ⌘V when you paste a selected item. No Input Monitoring required.")
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
                    Button("Open System Settings") {
                        AccessibilityPermission.openSystemSettings()
                    }
                }
            }
            Section {
                LabeledContent("Version", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 480)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            axGranted = AccessibilityPermission.isGranted
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
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
