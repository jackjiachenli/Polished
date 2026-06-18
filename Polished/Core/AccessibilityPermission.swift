//
//  AccessibilityPermission.swift
//  Polished
//
//  Created by Jack Li on 18/6/2026.
//

import AppKit
import ApplicationServices

enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func requestIfNeeded() {
        let key = "hasPromptedForAccessibility"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
