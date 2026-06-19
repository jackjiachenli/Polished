//
//  SettingsView.swift
//  Polished
//
//  Created by Jack Li on 18/6/2026.
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(ModuleManager.self) private var moduleManager
    @State private var axGranted = AccessibilityPermission.isGranted

    private static let moduleDescriptions: [String: String] = [
        "app-quitter": "Quits apps when their last window is closed",
        "window-snapper": "Snaps windows to screen edges and corners when dragged",
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
        .frame(width: 420, height: 320)
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
