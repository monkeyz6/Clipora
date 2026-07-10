import AppKit
import CryptoKit
import Foundation

/// 轮询 NSPasteboard.changeCount（0.3s），识别文本/图片/文件三类内容入库。
/// changeCount 判定与 pasteboard 快照在主线程完成，转码/哈希/缩略图/落盘/入库等
/// 重活一律移到后台串行队列，避免阻塞主线程（保证呼出零延迟）。
final class PasteboardMonitor {

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int
    private let workQueue = DispatchQueue(label: "com.clipora.capture", qos: .utility)

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.1
        // 面板交互（event tracking run loop mode）期间也要继续轮询
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 应用自身写入剪贴板后调用，跳过该次变更，避免自我循环入库
    func markSelfWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    /// 主线程：仅检测 changeCount 并快速快照 pasteboard 数据，重活交给后台
    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let snapshot = readSnapshot() else { return }
        workQueue.async { [weak self] in
            guard let item = self?.makeItem(from: snapshot) else { return }
            DatabaseManager.shared.insertOrBump(item)
        }
    }

    // MARK: - 主线程快照

    /// pasteboard 只读取原始字节，尽快脱离主线程。
    private struct Snapshot {
        var fileURLs: [String]?
        var pngData: Data?
        var tiffData: Data?
        var string: String?
        var sourceApp: String?
    }

    private func readSnapshot() -> Snapshot? {
        let types = pasteboard.types ?? []
        var snap = Snapshot()
        // 复制发生时的前台应用即来源 App（自身为 LSUIElement 不抢前台）
        snap.sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL], !urls.isEmpty {
            snap.fileURLs = urls.map(\.path)
        }
        if types.contains(.png) { snap.pngData = pasteboard.data(forType: .png) }
        if types.contains(.tiff) { snap.tiffData = pasteboard.data(forType: .tiff) }
        snap.string = pasteboard.string(forType: .string)

        let hasContent = snap.fileURLs != nil || snap.pngData != nil
            || snap.tiffData != nil || snap.string != nil
        return hasContent ? snap : nil
    }

    // MARK: - 后台构建条目（优先级：文件 > 图片 > 文本）

    private func makeItem(from snapshot: Snapshot) -> ClipItem? {
        captureFileURLs(snapshot) ?? captureImage(snapshot) ?? captureText(snapshot)
    }

    private func captureFileURLs(_ snapshot: Snapshot) -> ClipItem? {
        guard let paths = snapshot.fileURLs, !paths.isEmpty else { return nil }
        if AppSettings.ignoreFiles { return nil }

        guard let json = try? JSONEncoder().encode(paths),
              let content = String(data: json, encoding: .utf8) else { return nil }

        return ClipItem(
            id: nil,
            type: .file,
            subtype: nil,
            content: content,
            thumbnail: nil,
            imagePath: nil,
            contentHash: Self.sha256(content),
            isFavorite: false,
            favSortOrder: nil,
            createdAt: Date(),
            sourceApp: snapshot.sourceApp
        )
    }

    private func captureImage(_ snapshot: Snapshot) -> ClipItem? {
        guard snapshot.pngData != nil || snapshot.tiffData != nil else { return nil }
        if AppSettings.ignoreImages { return nil }

        // 统一转成 PNG 存储，方便回写与落盘
        var pngData: Data?
        if let data = snapshot.pngData {
            pngData = data
        } else if let tiff = snapshot.tiffData, let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        }
        guard let data = pngData else { return nil }

        // 尺寸检查前置：命中忽略规则直接丢弃，不再做哈希/缩略图/落盘的无用功
        if AppSettings.ignoreLargeContent, data.count > AppSettings.maxContentSizeBytes {
            return nil
        }

        let hash = Self.sha256(data)

        // 去重前置检查：同图已存在时不重复落盘（insertOrBump 兜底清理，双保险）
        var imagePath: String?
        if !DatabaseManager.shared.exists(type: .image, contentHash: hash) {
            imagePath = ImageStore.saveOriginal(pngData: data)
            guard imagePath != nil else { return nil }
        }

        let thumbnail = ImageStore.makeThumbnail(from: data)

        return ClipItem(
            id: nil,
            type: .image,
            subtype: nil,
            content: nil,
            thumbnail: thumbnail,
            imagePath: imagePath,
            contentHash: hash,
            isFavorite: false,
            favSortOrder: nil,
            createdAt: Date(),
            sourceApp: snapshot.sourceApp
        )
    }

    private func captureText(_ snapshot: Snapshot) -> ClipItem? {
        guard let text = snapshot.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if AppSettings.ignoreLargeContent,
           text.utf8.count > AppSettings.maxContentSizeBytes {
            return nil
        }

        return ClipItem(
            id: nil,
            type: .text,
            subtype: ContentClassifier.subtype(for: text),
            content: text,
            thumbnail: nil,
            imagePath: nil,
            contentHash: Self.sha256(text),
            isFavorite: false,
            favSortOrder: nil,
            createdAt: Date(),
            sourceApp: snapshot.sourceApp
        )
    }

    // MARK: - 哈希

    private static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
