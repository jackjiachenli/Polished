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
    let icon: NSImage?

    var id: CGWindowID { windowID }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }
}
