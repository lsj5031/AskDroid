import AppKit
import Foundation
import UniformTypeIdentifiers

struct AttachedImage: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    let mediaType: String
    let filename: String

    var fileExtension: String {
        switch mediaType {
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "png"
        }
    }

    var nsImage: NSImage? {
        NSImage(data: data)
    }

    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [AttachedImage] {
        var images: [AttachedImage] = []
        var seen = Set<Int>()

        func append(_ image: AttachedImage?) {
            guard let image, seen.insert(image.data.hashValue).inserted else { return }
            images.append(image)
        }

        for url in fileURLs(on: pasteboard) {
            append(fromFileURL(url))
        }

        let typedData: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "image/png"),
            (.tiff, "image/tiff"),
            (NSPasteboard.PasteboardType("public.jpeg"), "image/jpeg"),
            (NSPasteboard.PasteboardType("public.jpg"), "image/jpeg"),
            (NSPasteboard.PasteboardType("public.gif"), "image/gif"),
            (NSPasteboard.PasteboardType("public.webp"), "image/webp"),
            (NSPasteboard.PasteboardType("public.heic"), "image/heic"),
            (NSPasteboard.PasteboardType("public.heif"), "image/heif"),
            (NSPasteboard.PasteboardType("com.apple.webarchive"), "image/png"),
        ]
        if images.isEmpty {
            for (type, mime) in typedData {
                if let data = pasteboard.data(forType: type) {
                    append(fromData(data, hintedType: mime))
                    if !images.isEmpty { break }
                }
            }
        }

        if images.isEmpty, let rawImages = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for raw in rawImages {
                append(fromNSImage(raw))
            }
        }

        return images
    }

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        if let items = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls.append(contentsOf: items.map { URL(fileURLWithPath: $0) })
        }

        if let raw = pasteboard.string(forType: .fileURL), let url = URL(string: raw) ?? URL(string: raw.removingPercentEncoding ?? raw) {
            urls.append(url)
        }

        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] {
            urls.append(contentsOf: objects)
        }

        var unique: [URL] = []
        var seen = Set<URL>()
        for url in urls where seen.insert(url.standardizedFileURL).inserted {
            unique.append(url)
        }
        return unique
    }

    static func fromFileURL(_ url: URL) -> AttachedImage? {
        let resolved = url.standardizedFileURL
        guard let data = try? Data(contentsOf: resolved) else { return nil }
        let type = UTType(filenameExtension: resolved.pathExtension.lowercased())
        return fromData(data, hintedType: mimeType(for: type), filename: resolved.lastPathComponent)
    }

    static func fromNSImage(_ image: NSImage, filename: String? = nil) -> AttachedImage? {
        guard image.size.width > 0, image.size.height > 0,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }
        return AttachedImage(
            id: UUID(),
            data: data,
            mediaType: "image/png",
            filename: filename ?? "paste.png"
        )
    }

    static func fromData(_ data: Data, hintedType: String?, filename: String? = nil) -> AttachedImage? {
        let hinted = normalizeMediaType(hintedType)
        let sniffed = sniffMediaType(data)
        let mediaType = hinted ?? sniffed
        guard let mediaType else {
            if let image = NSImage(data: data) {
                return fromNSImage(image, filename: filename)
            }
            return nil
        }
        if needsTranscode(mediaType) {
            guard let image = NSImage(data: data) else { return nil }
            return fromNSImage(image, filename: filename ?? defaultName(for: "image/png"))
        }
        return AttachedImage(
            id: UUID(),
            data: data,
            mediaType: mediaType,
            filename: filename ?? defaultName(for: mediaType)
        )
    }

    static func needsTranscode(_ mediaType: String) -> Bool {
        mediaType == "image/tiff" || mediaType == "image/heic" || mediaType == "image/heif"
    }

    static func normalizeMediaType(_ value: String?) -> String? {
        switch value {
        case "image/jpeg", "image/jpg": "image/jpeg"
        case "image/png": "image/png"
        case "image/gif": "image/gif"
        case "image/webp": "image/webp"
        case "image/tiff", "image/tif": "image/tiff"
        case "image/heic": "image/heic"
        case "image/heif": "image/heif"
        default: nil
        }
    }

    static func mimeType(for type: UTType?) -> String? {
        guard let type else { return nil }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .gif) { return "image/gif" }
        if type.conforms(to: .webP) { return "image/webp" }
        if type.conforms(to: .tiff) { return "image/tiff" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "image/heic" }
        return type.preferredMIMEType
    }

    static func sniffMediaType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.count >= 4, data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }
        if data.count >= 12,
           data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50
        {
            return "image/webp"
        }
        return nil
    }

    static func defaultName(for mediaType: String) -> String {
        switch mediaType {
        case "image/jpeg": "paste.jpg"
        case "image/gif": "paste.gif"
        case "image/webp": "paste.webp"
        default: "paste.png"
        }
    }
}
