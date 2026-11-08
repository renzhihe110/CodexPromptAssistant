import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 用户显式选入的图片

@MainActor
final class AttachmentStore {
    private let directory = CodexEnvironment.cacheDirectory.appendingPathComponent("Attachments", isDirectory: true)

    init() {
        // 本应用单实例运行，启动时清理上次退出遗留的临时图片。
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func importFile(_ url: URL) throws -> ImageAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > 30 * 1024 * 1024 {
            throw AssistantError.imageTooLarge
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AssistantError.imageUnreadable
        }
        return try save(source: source, name: url.lastPathComponent)
    }

    func importImage(_ image: NSImage, name: String = "粘贴的图片.png") throws -> ImageAttachment {
        guard let data = image.tiffRepresentation, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AssistantError.imageUnreadable
        }
        return try save(source: source, name: name)
    }

    func remove(_ attachments: [ImageAttachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.fileURL)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func save(source: CGImageSource, name: String) throws -> ImageAttachment {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AssistantError.imageUnreadable
        }
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AssistantError.imageUnreadable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AssistantError.imageUnreadable
        }
        return ImageAttachment(id: id, name: name, fileURL: url)
    }
}
