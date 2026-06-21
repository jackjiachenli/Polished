//
//  ClipboardImageStorage.swift
//  Polished
//

import AppKit

enum ClipboardImageStorage {
    private static let maxStoredDimension = 1024
    private static let jpegCompression: Float = 0.75

    static func content(from pasteboard: NSPasteboard) -> (data: Data, width: Int, height: Int)? {
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        guard let bitmap = bitmapRepresentation(for: image) else { return nil }

        let scaled = scaleDownIfNeeded(bitmap)
        guard let data = scaled.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: jpegCompression)]
        ) else {
            return nil
        }

        return (
            data,
            max(scaled.pixelsWide, 1),
            max(scaled.pixelsHigh, 1)
        )
    }

    private static func bitmapRepresentation(for image: NSImage) -> NSBitmapImageRep? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return rep
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private static func scaleDownIfNeeded(_ source: NSBitmapImageRep) -> NSBitmapImageRep {
        let width = source.pixelsWide
        let height = source.pixelsHigh
        let longest = max(width, height)
        guard longest > maxStoredDimension else { return source }

        let scale = CGFloat(maxStoredDimension) / CGFloat(longest)
        let targetSize = NSSize(
            width: max(CGFloat(width) * scale, 1),
            height: max(CGFloat(height) * scale, 1)
        )

        let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: targetSize))
        NSGraphicsContext.restoreGraphicsState()

        return output
    }

    static func bitmapRep(fromStoredData data: Data) -> NSBitmapImageRep? {
        if let rep = NSBitmapImageRep(data: data) {
            return rep
        }
        guard let image = NSImage(data: data), let rep = bitmapRepresentation(for: image) else {
            return nil
        }
        return rep
    }

    @discardableResult
    static func write(data: Data, to pasteboard: NSPasteboard) -> Bool {
        guard let rep = bitmapRep(fromStoredData: data) else { return false }
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return pasteboard.writeObjects([image])
    }
}
