//
//  SwitchableWindow.swift
//  Polished
//

import AppKit

struct SwitchableWindow: Identifiable, Equatable, Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let bundleIdentifier: String?
    let isMinimized: Bool
    let isFullScreen: Bool
    let icon: NSImage?
    /// Used to pick the primary window when duplicates appear (e.g. Electron fullscreen artifacts).
    let area: CGFloat

    var id: CGWindowID { windowID }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }
}
