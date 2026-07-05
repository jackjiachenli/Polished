//
//  LaunchAtLogin.swift
//  Polished
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    enum Error: LocalizedError {
        case notInApplications

        var errorDescription: String? {
            "Move Polished to the Applications folder to enable Launch at Login."
        }
    }

    static var isInstalledInApplications: Bool {
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL == applicationsURL
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled && !isInstalledInApplications {
            throw Error.notInApplications
        }

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
