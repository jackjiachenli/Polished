//
//  FinderAX.swift
//  Polished
//

import AppKit
import ApplicationServices
import Carbon

enum FinderAX {
    private static let finderBundleID = "com.apple.finder"
    private static let cacheLifetime: TimeInterval = 0.2
    private static let maxAXDepth = 20

    private static var cachedWindow: AXUIElement?
    private static var cachedWindowExpiresAt = Date.distantPast
    private static var cachedFolderURL: URL?
    private static var cachedFolderExpiresAt = Date.distantPast

    static func invalidateSessionCache() {
        cachedWindow = nil
        cachedFolderURL = nil
        cachedWindowExpiresAt = .distantPast
        cachedFolderExpiresAt = .distantPast
    }

    static var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleID
    }

    static func selectedFileURLs() -> [URL] {
        if let window = sessionFocusedWindow() {
            let axURLs = selectedElements(in: window)
                .compactMap { fileURL(from: $0, relativeTo: window) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !axURLs.isEmpty {
                return axURLs
            }
        }

        let scriptURLs = selectedFileURLsViaAppleScript()
        if !scriptURLs.isEmpty {
            return scriptURLs
        }

        return selectedFileURLsViaCopySimulation()
    }

    static func viewingFolderURL() -> URL? {
        guard let window = sessionFocusedWindow() else { return nil }
        return sessionFolderURL(for: window)
    }

    static func pasteDestinationURL() -> URL? {
        guard let window = sessionFocusedWindow() else {
            print("FinderAX: No focused Finder window for paste destination")
            return nil
        }

        guard let viewingFolder = sessionFolderURL(for: window) else {
            print("FinderAX: Could not resolve the folder shown in the front Finder window")
            return nil
        }

        let selectedURLs: [URL]
        if hasSelectedItems(in: window) {
            selectedURLs = selectedElements(in: window)
                .compactMap { directFileURL(from: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        } else {
            selectedURLs = []
        }

        let selectedDirectories = selectedURLs.filter(isDirectory)
        let selectedFiles = selectedURLs.filter { !isDirectory($0) }

        if selectedDirectories.count == 1, selectedFiles.isEmpty {
            PolishedLog.debug("FinderAX: Paste destination (selected folder): \(selectedDirectories[0].path)")
            return selectedDirectories[0]
        }

        PolishedLog.debug("FinderAX: Paste destination (viewing folder): \(viewingFolder.path)")
        return viewingFolder
    }

    private static func selectedFileURLsViaAppleScript() -> [URL] {
        let source = """
        tell application "Finder"
            try
                set sel to selection
                if (count of sel) is 0 then return ""
                set pathLines to {}
                repeat with anItem in sel
                    set end of pathLines to POSIX path of (anItem as alias)
                end repeat
                set AppleScript's text item delimiters to linefeed
                set pathText to pathLines as string
                set AppleScript's text item delimiters to ""
                return pathText
            on error
                return ""
            end try
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return [] }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                print("FinderAX: Allow Polished to control Finder in System Settings → Privacy & Security → Automation")
            }
            return []
        }

        guard let text = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return []
        }

        let urls = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            PolishedLog.debug("FinderAX: Resolved \(urls.count) file(s) via Finder AppleScript selection")
        }
        return urls
    }

    private static func selectedFileURLsViaCopySimulation() -> [URL] {
        let pasteboard = NSPasteboard.general
        let backup = GeneralPasteboardBackup.capture()
        let priorChangeCount = pasteboard.changeCount

        KeySimulation.postCommandKey(CGKeyCode(kVK_ANSI_C))

        for _ in 0..<25 {
            if pasteboard.changeCount != priorChangeCount { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        defer { backup.restore() }

        let urls = PasteboardFileURLs.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            print("FinderAX: Copy simulation did not yield file URLs — select file(s) in Finder and try again")
            return []
        }

        PolishedLog.debug("FinderAX: Resolved \(urls.count) file(s) via copy simulation")
        return urls
    }

    private static let folderContainerRoles: Set<String> = [
        kAXWindowRole as String,
        kAXScrollAreaRole as String,
        "AXBrowser",
        "AXSplitGroup",
        "AXOutline",
        "AXTable",
        "AXList",
    ]

    private static func sessionFocusedWindow() -> AXUIElement? {
        let now = Date()
        if let window = cachedWindow, cachedWindowExpiresAt > now {
            return window
        }
        let window = focusedFinderWindow()
        cachedWindow = window
        cachedWindowExpiresAt = now.addingTimeInterval(cacheLifetime)
        return window
    }

    private static func sessionFolderURL(for window: AXUIElement) -> URL? {
        let now = Date()
        if let url = cachedFolderURL, cachedFolderExpiresAt > now {
            return url
        }
        let url = currentFolderURL(from: window) ?? folderURLViaAppleScript()
        cachedFolderURL = url
        cachedFolderExpiresAt = now.addingTimeInterval(cacheLifetime)
        return url
    }

    private static func hasSelectedItems(in window: AXUIElement) -> Bool {
        if !axElements(window, kAXSelectedChildrenAttribute as CFString).isEmpty {
            return true
        }
        for child in axElements(window, kAXChildrenAttribute as CFString) {
            if axValue(child, kAXSelectedAttribute as CFString) as? Bool == true {
                return true
            }
            if let rows = axValue(child, "AXSelectedRows" as CFString) as? [AnyObject], !rows.isEmpty {
                return true
            }
        }
        return false
    }

    private static func finderApplication() -> AXUIElement? {
        guard isFinderFrontmost,
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 5)
        return axApp
    }

    private static func focusedFinderWindow() -> AXUIElement? {
        guard let app = finderApplication() else { return nil }

        if let window = axElement(app, kAXFocusedWindowAttribute as CFString) {
            return window
        }

        if let windows = axValue(app, kAXWindowsAttribute as CFString) as? [AnyObject] {
            for item in windows {
                let window: AXUIElement = item as! AXUIElement
                if axRole(window) != nil {
                    return window
                }
            }
        }

        return nil
    }

    private static func selectedElements(in window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var seen = Set<UnsafeMutableRawPointer>()
        collectSelected(in: window, depth: 0, into: &found, seen: &seen)
        return dedupeElements(found)
    }

    private static func collectSelected(
        in element: AXUIElement,
        depth: Int,
        into found: inout [AXUIElement],
        seen: inout Set<UnsafeMutableRawPointer>
    ) {
        guard depth <= maxAXDepth else { return }
        let key = Unmanaged.passUnretained(element).toOpaque()
        guard seen.insert(key).inserted else { return }

        found.append(contentsOf: axElements(element, kAXSelectedChildrenAttribute as CFString))

        if axValue(element, kAXSelectedAttribute as CFString) as? Bool == true {
            found.append(element)
        }

        if let rows = axValue(element, "AXSelectedRows" as CFString) as? [AnyObject] {
            for item in rows {
                found.append(item as! AXUIElement)
            }
        }

        for child in axElements(element, kAXChildrenAttribute as CFString) {
            collectSelected(in: child, depth: depth + 1, into: &found, seen: &seen)
        }
    }

    private static func dedupeElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen = Set<UnsafeMutableRawPointer>()
        return elements.filter { element in
            seen.insert(Unmanaged.passUnretained(element).toOpaque()).inserted
        }
    }

    private static func currentFolderURL(from window: AXUIElement) -> URL? {
        if let url = documentFolderURL(from: window) { return url }

        for child in axElements(window, kAXChildrenAttribute as CFString) {
            if let url = documentFolderURL(from: child) { return url }
            for grandchild in axElements(child, kAXChildrenAttribute as CFString) {
                if let url = documentFolderURL(from: grandchild) { return url }
            }
        }

        var containerCandidates: [URL] = []
        collectContainerFolderURLs(in: window, depth: 0, into: &containerCandidates)
        if let best = bestViewingFolderCandidate(from: containerCandidates) {
            PolishedLog.debug("FinderAX: Resolved viewing folder from container scan: \(best.path)")
            return best
        }

        if let url = pathBarFolderURL(from: window) {
            PolishedLog.debug("FinderAX: Resolved viewing folder from path bar: \(url.path)")
            return url
        }

        if let url = folderURLFromWindowTitle(from: window) {
            PolishedLog.debug("FinderAX: Resolved viewing folder from window title: \(url.path)")
            return url
        }

        return nil
    }

    private static func collectContainerFolderURLs(in element: AXUIElement, depth: Int, into urls: inout [URL]) {
        guard depth <= 8 else { return }
        if let role = axRole(element), folderContainerRoles.contains(role),
           let url = directFileURL(from: element), isDirectory(url) {
            urls.append(url.standardizedFileURL)
        }
        for child in axElements(element, kAXChildrenAttribute as CFString) {
            collectContainerFolderURLs(in: child, depth: depth + 1, into: &urls)
        }
    }

    private static func bestViewingFolderCandidate(from urls: [URL]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let candidates = urls
            .filter { isDirectory($0) && FileManager.default.isWritableFile(atPath: $0.path) }
            .filter { $0.pathExtension.lowercased() != "app" }
            .filter { $0.path == home || $0.path.hasPrefix(home + "/") }

        guard !candidates.isEmpty else { return nil }
        return candidates.max(by: { $0.path.count < $1.path.count })
    }

    private static func pathBarFolderURL(from window: AXUIElement) -> URL? {
        guard let toolbar = findToolbar(in: window) else { return nil }
        var segments: [URL] = []
        collectToolbarDirectoryURLs(in: toolbar, depth: 0, into: &segments)
        return bestViewingFolderCandidate(from: segments)
    }

    private static func findToolbar(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= 10 else { return nil }
        if axRole(element) == kAXToolbarRole as String { return element }
        for child in axElements(element, kAXChildrenAttribute as CFString) {
            if let found = findToolbar(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func collectToolbarDirectoryURLs(in element: AXUIElement, depth: Int, into urls: inout [URL]) {
        guard depth <= 8 else { return }
        if let url = directFileURL(from: element), isDirectory(url) {
            urls.append(url.standardizedFileURL)
        }
        for child in axElements(element, kAXChildrenAttribute as CFString) {
            collectToolbarDirectoryURLs(in: child, depth: depth + 1, into: &urls)
        }
    }

    private static func folderURLFromWindowTitle(from window: AXUIElement) -> URL? {
        guard let title = axValue(window, kAXTitleAttribute as CFString) as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let known: [(String, FileManager.SearchPathDirectory)] = [
            ("Desktop", .desktopDirectory),
            ("Downloads", .downloadsDirectory),
            ("Documents", .documentDirectory),
            ("Applications", .applicationDirectory),
            ("Movies", .moviesDirectory),
            ("Music", .musicDirectory),
            ("Pictures", .picturesDirectory),
        ]
        for (name, directory) in known {
            guard trimmed == name || trimmed.hasPrefix(name + " ") else { continue }
            return FileManager.default.urls(for: directory, in: .userDomainMask).first
        }
        return nil
    }

    private static func folderURLViaAppleScript() -> URL? {
        let source = """
        tell application "Finder"
            try
                return POSIX path of (insertion location as alias)
            on error
                try
                    if (exists Finder window 1) then
                        return POSIX path of (folder of Finder window 1 as alias)
                    end if
                end try
            end try
            return ""
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                print("FinderAX: Allow Polished to control Finder in System Settings → Privacy & Security → Automation")
            } else {
                print("FinderAX: AppleScript folder resolution failed: \(error)")
            }
            return nil
        }
        guard let path = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard isDirectory(url), FileManager.default.isWritableFile(atPath: url.path) else { return nil }
        PolishedLog.debug("FinderAX: Resolved viewing folder via Finder AppleScript: \(url.path)")
        return url
    }

    private static func documentFolderURL(from element: AXUIElement) -> URL? {
        guard let role = axRole(element), folderContainerRoles.contains(role) else { return nil }
        guard let url = directFileURL(from: element), isDirectory(url) else { return nil }
        return url
    }

    private static func fileURL(from element: AXUIElement, relativeTo window: AXUIElement) -> URL? {
        if let url = directFileURL(from: element) {
            return url
        }

        guard elementIdentity(element) != elementIdentity(window),
              axRole(element) != kAXWindowRole as String,
              let title = axValue(element, kAXTitleAttribute as CFString) as? String,
              !title.isEmpty else {
            return nil
        }

        guard let folder = currentFolderURL(from: window)
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return nil
        }

        let candidate = folder.appendingPathComponent(title)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    static func directFileURL(from element: AXUIElement) -> URL? {
        for attribute in [kAXURLAttribute, kAXDocumentAttribute, "AXFilePath", "AXPath"] as [CFString] {
            if let url = parseURL(axValue(element, attribute)) {
                return url
            }
        }
        if let value = axValue(element, kAXValueAttribute as CFString) as? String,
           let url = parsePathString(value) {
            return url
        }
        return nil
    }

    private static func parsePathString(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return nil
    }

    private static func elementIdentity(_ element: AXUIElement) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(element).toOpaque()
    }

    private static func parseURL(_ value: CFTypeRef?) -> URL? {
        guard let value else { return nil }

        if let url = value as? URL, url.isFileURL {
            return url.standardizedFileURL
        }

        if CFGetTypeID(value) == CFURLGetTypeID() {
            let url = value as! CFURL as URL
            guard url.isFileURL else { return nil }
            return url.standardizedFileURL
        }

        if let string = value as? String {
            if string.hasPrefix("file://"), let url = URL(string: string), url.isFileURL {
                return url.standardizedFileURL
            }
            if string.contains(":"), let posix = hfsPathToPOSIX(string) {
                return URL(fileURLWithPath: posix, isDirectory: true)
            }
            if string.hasPrefix("/") {
                return URL(fileURLWithPath: string, isDirectory: true)
            }
        }

        return nil
    }

    private static func hfsPathToPOSIX(_ hfsPath: String) -> String? {
        let parts = hfsPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        return "/" + parts.dropFirst().joined(separator: "/")
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private static func axElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = axValue(element, attribute) else { return nil }
        let child: AXUIElement = value as! AXUIElement
        return axRole(child) != nil ? child : nil
    }

    private static func axElements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        guard let value = axValue(element, attribute) as? [AnyObject] else { return [] }
        return value.compactMap { item in
            let child: AXUIElement = item as! AXUIElement
            return axRole(child) != nil ? child : nil
        }
    }

    private static func axValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private static func axRole(_ element: AXUIElement) -> String? {
        axValue(element, kAXRoleAttribute as CFString) as? String
    }
}
