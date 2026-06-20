//
//  PasteboardFileURLs.swift
//  Polished
//

import AppKit

enum PasteboardFileURLs {
    static func fileURLs(from pasteboard: NSPasteboard, requireExistingFiles: Bool = true) -> [URL] {
        var paths: [String] = []
        var seen = Set<String>()

        func appendPath(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let path: String
            if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
                path = url.path
            } else {
                path = trimmed
            }
            guard seen.insert(path).inserted else { return }
            paths.append(path)
        }

        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let path = item.string(forType: .fileURL) {
                    appendPath(path)
                }
                if let path = item.string(forType: NSPasteboard.PasteboardType("public.file-url")) {
                    appendPath(path)
                }
            }
        }

        if paths.isEmpty,
           let legacy = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            for path in legacy {
                appendPath(path)
            }
        }

        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard requireExistingFiles else { return urls }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
