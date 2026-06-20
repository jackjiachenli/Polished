//
//  ClipboardHistoryStore.swift
//  Polished
//

import Foundation

enum ClipboardHistoryStore {
    private static let directoryName = "Polished"
    private static let fileName = "clipboard-history.json"

    static func load() -> [ClipboardItem] {
        guard let url = storeURL(), FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([StoredClipboardItem].self, from: data)
            return decoded.compactMap { $0.clipboardItem }
        } catch {
            print("ClipboardHistoryStore: load failed — \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ items: [ClipboardItem]) {
        guard let url = storeURL() else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stored = items.map(StoredClipboardItem.init)
            let data = try JSONEncoder().encode(stored)
            try data.write(to: url, options: .atomic)
        } catch {
            print("ClipboardHistoryStore: save failed — \(error.localizedDescription)")
        }
    }

    static func clear() {
        guard let url = storeURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func storeURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

private struct StoredClipboardItem: Codable {
    let id: UUID
    let capturedAt: Date
    let kind: String
    let text: String?
    let imageData: Data?
    let imageWidth: Int?
    let imageHeight: Int?
    let filePaths: [String]?

    init(item: ClipboardItem) {
        id = item.id
        capturedAt = item.capturedAt
        switch item.content {
        case .text(let string):
            kind = "text"
            text = string
            imageData = nil
            imageWidth = nil
            imageHeight = nil
            filePaths = nil
        case .image(let data, let width, let height):
            kind = "image"
            text = nil
            imageData = data
            imageWidth = width
            imageHeight = height
            filePaths = nil
        case .fileURLs(let urls):
            kind = "files"
            text = nil
            imageData = nil
            imageWidth = nil
            imageHeight = nil
            filePaths = urls.map(\.path)
        }
    }

    var clipboardItem: ClipboardItem? {
        let content: ClipboardContent?
        switch kind {
        case "text":
            guard let text, !text.isEmpty else { return nil }
            content = .text(text)
        case "image":
            guard let imageData, let imageWidth, let imageHeight else { return nil }
            content = .image(imageData, width: imageWidth, height: imageHeight)
        case "files":
            guard let filePaths, !filePaths.isEmpty else { return nil }
            let urls = filePaths.map { URL(fileURLWithPath: $0) }
            content = .fileURLs(urls)
        default:
            content = nil
        }
        guard let content else { return nil }
        return ClipboardItem(id: id, content: content, capturedAt: capturedAt)
    }
}
