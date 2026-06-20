//
//  GeneralPasteboardBackup.swift
//  Polished
//

import AppKit

struct GeneralPasteboardBackup {
    private let itemData: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> GeneralPasteboardBackup {
        let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return dataByType
        }
        return GeneralPasteboardBackup(itemData: items)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !itemData.isEmpty else { return }

        let items = itemData.map { dataByType in
            let item = NSPasteboardItem()
            for (type, data) in dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
