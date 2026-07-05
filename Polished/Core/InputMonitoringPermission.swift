//
//  InputMonitoringPermission.swift
//  Polished
//

import AppKit
import CoreGraphics

enum InputMonitoringPermission {
    static var isGranted: Bool { CGPreflightListenEventAccess() }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func requestIfNeeded() {
        guard !isGranted else { return }
        _ = CGRequestListenEventAccess()
    }
}
