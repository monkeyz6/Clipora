import AppKit
import Foundation

/// 图片原图落盘与缩略图生成。原图存 Application Support/Clipora/images/，数据库只存相对文件名。
enum ImageStore {

    static let thumbnailMaxDimension: CGFloat = 200

    /// 保存 PNG 原图，返回落盘文件名（作为 image_path 存库)
    static func saveOriginal(pngData: Data) -> String? {
        let dir = AppPaths.imagesDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".png"
            try pngData.write(to: dir.appendingPathComponent(name))
            return name
        } catch {
            NSLog("ImageStore.saveOriginal failed: \(error)")
            return nil
        }
    }

    static func originalURL(path: String) -> URL {
        // 兼容绝对路径（防御性），正常情况 path 只是文件名
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return AppPaths.imagesDirectory.appendingPathComponent(path)
    }

    static func loadOriginal(path: String) -> Data? {
        try? Data(contentsOf: originalURL(path: path))
    }

    static func delete(path: String) {
        try? FileManager.default.removeItem(at: originalURL(path: path))
    }

    /// 生成最长边 ≤ 200px 的 PNG 缩略图数据
    static func makeThumbnail(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        // 优先复用 NSImage 已解码的位图表示读像素尺寸，避免对同一份数据二次解码；
        // 个别格式的 NSImage 不含位图表示时，才回退到从 data 重新解码。
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
            ?? NSBitmapImageRep(data: data) else {
            return pngData(from: image, maxDimension: thumbnailMaxDimension)
        }
        let pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        return pngData(from: image, sourceSize: pixelSize, maxDimension: thumbnailMaxDimension)
    }

    private static func pngData(
        from image: NSImage,
        sourceSize: NSSize? = nil,
        maxDimension: CGFloat
    ) -> Data? {
        let size = sourceSize ?? image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
