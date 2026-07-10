import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {

    convenience init() {
        // SwiftUI 内容透明，靠底层毛玻璃透出桌面（对齐设计稿的半透明玻璃窗）
        let hosting = NSHostingView(rootView: SettingsView())
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.addSubview(hosting)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentView = effect
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        // 内容铺满标题栏区域，原生红绿灯浮于玻璃之上；标题文字由 SwiftUI 居中自绘
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = L("Clipora 设置", "Clipora Settings")   // 供窗口菜单 / Mission Control 识别
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)

        NotificationCenter.default.addObserver(
            self, selector: #selector(languageDidChange),
            name: .languageDidChange, object: nil
        )
    }

    @objc private func languageDidChange() {
        window?.title = L("Clipora 设置", "Clipora Settings")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}
