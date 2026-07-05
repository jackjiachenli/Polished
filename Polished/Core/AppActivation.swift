//
//  AppActivation.swift
//  Polished
//

import AppKit

enum AppActivation {
    @MainActor
    static func activateForWindowPresentation() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
