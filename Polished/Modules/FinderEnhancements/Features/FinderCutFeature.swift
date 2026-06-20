//
//  FinderCutFeature.swift
//  Polished
//
//  Windows Explorer-style cut/paste in Finder: ⌘X marks selected files for move;
//  ⌘V in a destination folder moves them instead of copying. Requires Accessibility
//  and Input Monitoring so the event tap can intercept keyboard shortcuts.
//

import AppKit
import ApplicationServices
import Carbon

final class FinderCutFeature: FinderFeature {
    let id = "finder-enhancements.cut"
    let name = "Cut"
    let description = "Cmd+X marks files; Cmd+V moves instead of copies"

    var isEnabled = true

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cutURLs: [URL] = []

    private static let cutPasteboardName = NSPasteboard.Name("com.jackjiachenli.polished.finder-cut")
    private static let cutPathsType = NSPasteboard.PasteboardType("com.jackjiachenli.polished.finder-cut.paths")

    func start() {
        guard AXIsProcessTrusted() else {
            print("FinderCutFeature: Accessibility permission not granted — enable in System Settings")
            return
        }
        guard eventTap == nil else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: finderCutEventCallback,
            userInfo: refcon
        ) else {
            print("FinderCutFeature: Failed to create event tap — enable Input Monitoring for Polished, then quit and relaunch")
            _ = CGRequestListenEventAccess()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("FinderCutFeature: Event tap active")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        clearCutState(clearPasteboard: true)
    }

    fileprivate func handleKeyDownFromTap(_ event: CGEvent) -> CGEvent? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == CGKeyCode(kVK_Escape) {
            if hasStoredCutMark() {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.resolvedCutURLs().isEmpty else { return }
                    self.clearCutState(clearPasteboard: true)
                    PolishedLog.debug("FinderCutFeature: Cleared cut mark")
                }
            }
            return event
        }

        guard FinderAX.isFinderFrontmost else { return event }
        guard isCommandOnly(event.flags) else { return event }

        switch keyCode {
        case CGKeyCode(kVK_ANSI_X):
            DispatchQueue.main.async { [weak self] in
                _ = self?.handleCut()
            }
            return nil
        case CGKeyCode(kVK_ANSI_V):
            guard hasStoredCutMark() else { return event }
            DispatchQueue.main.async { [weak self] in
                self?.handlePaste()
            }
            return nil
        case CGKeyCode(kVK_ANSI_C):
            if hasStoredCutMark() {
                DispatchQueue.main.async { [weak self] in
                    self?.clearCutState(clearPasteboard: true)
                }
            }
            return event
        default:
            return event
        }
    }

    private func hasStoredCutMark() -> Bool {
        if !cutURLs.isEmpty { return true }
        return NSPasteboard(name: Self.cutPasteboardName).data(forType: Self.cutPathsType) != nil
    }

    private func isCommandOnly(_ flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskCommand) else { return false }
        let otherModifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskSecondaryFn, .maskHelp]
        return flags.intersection(otherModifiers).isEmpty
    }

    private func handleCut() -> Bool {
        let selected = FinderAX.selectedFileURLs()
        guard !selected.isEmpty else { return false }

        cutURLs = selected.map(\.standardizedFileURL)
        writeCutToPasteboard(urls: cutURLs)
        FinderAX.invalidateSessionCache()
        PolishedLog.debug("FinderCutFeature: Marked \(cutURLs.count) item(s) for move: \(cutURLs.map(\.lastPathComponent).joined(separator: ", "))")
        return true
    }

    private func handlePaste() {
        let urlsToMove = resolvedCutURLs()
        guard !urlsToMove.isEmpty else {
            clearCutState(clearPasteboard: true)
            PolishedLog.debug("FinderCutFeature: Paste ignored — nothing marked for cut")
            return
        }
        guard let destinationDirectory = FinderAX.pasteDestinationURL() else {
            print("FinderCutFeature: Paste ignored — could not resolve destination folder")
            NSSound.beep()
            return
        }
        if let reason = validatePasteDestination(destinationDirectory) {
            print("FinderCutFeature: Paste blocked — \(reason)")
            NSSound.beep()
            return
        }

        var movedAny = false
        for source in urlsToMove {
            guard FileManager.default.fileExists(atPath: source.path) else { continue }

            let destination = uniqueDestinationURL(for: source, in: destinationDirectory)
            if source.standardizedFileURL == destination.standardizedFileURL {
                PolishedLog.debug("FinderCutFeature: Skipping \(source.lastPathComponent) — already at destination")
                continue
            }

            do {
                PolishedLog.debug("FinderCutFeature: Moving \(source.path) → \(destination.path)")
                try moveItem(at: source, to: destination)
                if FileManager.default.fileExists(atPath: source.path) {
                    PolishedLog.debug("FinderCutFeature: Source still present after move — removing \(source.lastPathComponent)")
                    try FileManager.default.removeItem(at: source)
                }
                movedAny = true
            } catch {
                print("FinderCutFeature: Failed to move \(source.lastPathComponent) → \(destination.path): \(error.localizedDescription)")
                NSSound.beep()
                return
            }
        }

        if movedAny {
            FinderAX.invalidateSessionCache()
            clearCutState(clearPasteboard: true)
            PolishedLog.debug("FinderCutFeature: Moved item(s) to \(destinationDirectory.path)")
            return
        }

        PolishedLog.debug("FinderCutFeature: Paste did not move any items")
        NSSound.beep()
    }

    private func validatePasteDestination(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "destination is not a folder"
        }
        if url.pathExtension == "app" {
            return "cannot move into an application bundle — select a regular folder (e.g. Downloads) instead"
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return "you don’t have permission to write to “\(url.lastPathComponent)”"
        }
        return nil
    }

    private func resolvedCutURLs() -> [URL] {
        if !cutURLs.isEmpty {
            return cutURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        return storedCutURLs()
    }

    private func writeCutToPasteboard(urls: [URL]) {
        let paths = urls.map(\.path)
        guard let data = try? JSONEncoder().encode(paths) else { return }
        let pasteboard = NSPasteboard(name: Self.cutPasteboardName)
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.cutPathsType)
    }

    private func storedCutURLs() -> [URL] {
        let pasteboard = NSPasteboard(name: Self.cutPasteboardName)
        guard let data = pasteboard.data(forType: Self.cutPathsType),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func clearCutState(clearPasteboard: Bool) {
        cutURLs.removeAll()
        if clearPasteboard {
            NSPasteboard(name: Self.cutPasteboardName).clearContents()
        }
    }

    private func moveItem(at source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            guard !isSameVolume(source, destination) else { throw error }
            try fileManager.copyItem(at: source, to: destination)
            do {
                try fileManager.removeItem(at: source)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
    }

    private func isSameVolume(_ source: URL, _ destination: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let sourceValues = try? source.resourceValues(forKeys: keys),
              let destinationValues = try? destination.deletingLastPathComponent().resourceValues(forKeys: keys),
              let sourceVolume = sourceValues.volumeIdentifier,
              let destinationVolume = destinationValues.volumeIdentifier else {
            return source.path.hasPrefix("/") && destination.path.hasPrefix("/")
                && source.path.split(separator: "/").first == destination.path.split(separator: "/").first
        }
        return (sourceVolume as AnyObject).isEqual(destinationVolume)
    }

    private func uniqueDestinationURL(for source: URL, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let numberedName = ext.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(ext)"
            candidate = directory.appendingPathComponent(numberedName)
            index += 1
        }
        return candidate
    }
}

private func finderCutEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let feature = Unmanaged<FinderCutFeature>.fromOpaque(refcon).takeUnretainedValue()
        if let tap = feature.eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    let feature = Unmanaged<FinderCutFeature>.fromOpaque(refcon).takeUnretainedValue()
    if let modified = feature.handleKeyDownFromTap(event) {
        return Unmanaged.passUnretained(modified)
    }
    return nil
}

private extension FinderCutFeature {
    var eventTapPort: CFMachPort? { eventTap }
}
