//
//  ModuleManager.swift
//  Polished
//
//  Created by Jack Li on 18/6/2026.
//

import Foundation
import Observation

@Observable
class ModuleManager {
    static let shared = ModuleManager()
    private(set) var modules: [Module] = []
    private(set) var clipboardHistory: ClipboardHistory
    private(set) var enabledModuleIDs: Set<String> = []
    private let enabledModulesKey = "enabledModuleIDs"

    private init() {
        let clipboardHistory = ClipboardHistory()
        self.clipboardHistory = clipboardHistory
        modules = [
            AppQuitter(),
            WindowSnapper(),
            clipboardHistory,
        ]
        loadEnabledState()
        startEnabledModules()
    }

    private func loadEnabledState() {
        let saved = UserDefaults.standard.stringArray(forKey: enabledModulesKey) ?? []
        enabledModuleIDs = Set(saved)
    }

    private func saveEnabledState() {
        UserDefaults.standard.set(Array(enabledModuleIDs), forKey: enabledModulesKey)
    }

    func startEnabledModules() {
        for module in modules where isEnabled(module) {
            module.isEnabled = true
            module.start()
        }
    }

    func isEnabled(_ module: Module) -> Bool {
        enabledModuleIDs.contains(module.id)
    }

    func setEnabled(_ enabled: Bool, for module: Module) {
        guard enabled != isEnabled(module) else { return }

        if enabled {
            enabledModuleIDs.insert(module.id)
        } else {
            enabledModuleIDs.remove(module.id)
        }
        saveEnabledState()

        module.isEnabled = enabled
        if enabled {
            module.start()
        } else {
            module.stop()
        }
    }

    func toggleModule(_ module: Module) {
        setEnabled(!isEnabled(module), for: module)
    }
}
