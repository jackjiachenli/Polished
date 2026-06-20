//
//  PolishedApp.swift
//  Polished
//

import SwiftUI

@main
struct PolishedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Bindable private var moduleManager = ModuleManager.shared

    var body: some Scene {
        // Establishes window context for LSUIElement apps (required before other scenes on macOS 26)
        Window("Hidden", id: "hidden-context") {
            Color.clear
                .frame(width: 1, height: 1)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra("Polished", systemImage: "sparkles") {
            MenuBarMenuContent(moduleManager: moduleManager)
        }
        .menuBarExtraStyle(.menu)

        Window("Polished Settings", id: "settings") {
            SettingsView()
                .environment(moduleManager)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct MenuBarMenuContent: View {
    @Bindable var moduleManager: ModuleManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(moduleManager.modules, id: \.id) { module in
            Toggle(module.name, isOn: Binding(
                get: { moduleManager.isEnabled(module) },
                set: { moduleManager.setEnabled($0, for: module) }
            ))
        }
        Divider()
        Button("Settings…") {
            openSettingsWindow()
        }
        Divider()
        Button("Quit Polished") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")

        // openWindow can fail silently in menu bar apps — ensure the window is visible
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "settings"
            }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
