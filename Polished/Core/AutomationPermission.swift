//
//  AutomationPermission.swift
//  Polished
//

import AppKit

enum AutomationPermission {
    static var isGranted: Bool {
        let source = """
        tell application "Finder"
            return name of front window
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        _ = script.executeAndReturnError(&error)
        guard let error else { return true }
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        return code != -1743
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
