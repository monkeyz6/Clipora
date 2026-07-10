import AppKit

/// 无边框、不激活应用的浮动面板（Spotlight 式）。
/// .nonactivatingPanel 保证呼出时不抢占原应用焦点；canBecomeKey 让搜索框能接键盘输入。
final class ClipPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none  // 动画自己做，避免系统默认动画叠加
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 顶部拖拽区：在空白处按下即拖动整个面板

/// 铺在顶部栏底层的透明视图；空白处 mouseDown 发起窗口拖动（搜索框/分段控件在其上层，各自消费点击）。
final class HeaderDragView: NSView {
    /// 拖动结束回调（performDrag 阻塞至松开鼠标后返回，此时窗口已在最终位置）
    var onDragEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        onDragEnded?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 胶囊 Toast（浅色毛玻璃：圆形彩色徽章 + 文案，横向）

/// 独立的高层级、不激活、穿透点击的小面板：复制/收藏/取消收藏时，屏幕下方弹出
/// 一枚浅色毛玻璃胶囊——左侧彩色圆形徽章（对勾/星形），右侧文案。整体弹入淡入。
final class ToastPresenter {

    enum Kind {
        case copied, favorited, unfavorited

        /// 徽章内白色字形（copied 用「画出来」的对勾，不走此项）
        var symbol: String {
            switch self {
            case .copied: return "checkmark"
            case .favorited: return "star.fill"
            case .unfavorited: return "star.slash.fill"
            }
        }
        /// 圆形徽章底色
        var tint: NSColor {
            switch self {
            case .copied: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)   // 系统绿
            case .favorited: return NSColor(srgbRed: 0.98, green: 0.71, blue: 0.15, alpha: 1) // 琥珀
            case .unfavorited: return NSColor(srgbRed: 0.58, green: 0.60, blue: 0.67, alpha: 1) // 中性灰
            }
        }
        var caption: String {
            switch self {
            case .copied: return L("复制成功", "Copied")
            case .favorited: return L("收藏成功", "Favorited")
            case .unfavorited: return L("取消成功", "Unfavorited")
            }
        }
    }

    // 指标
    private static let height: CGFloat = 44
    private static let dot: CGFloat = 22       // 圆形徽章直径
    private static let leftPad: CGFloat = 15    // 胶囊左边 → 徽章
    private static let gap: CGFloat = 9         // 徽章 → 文字
    private static let rightPad: CGFloat = 18   // 文字 → 胶囊右边
    private static let font = NSFont.systemFont(ofSize: 14, weight: .semibold)

    private let panel: NSPanel
    private let container = NSVisualEffectView()
    private let dotView = NSView()             // 圆形彩色底
    private let iconView = NSImageView()        // 星形等白色字形
    private let checkLayer = CAShapeLayer()     // copied 的白色对勾（描边动画）
    private let captionLabel = NSTextField(labelWithString: "")
    private var dismissWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        // 浅色毛玻璃胶囊（.popover 材质随系统深浅切换，浅色下即参考稿的白色磨砂）
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        // 用 maskImage 裁成胶囊（全圆角）；材质需要它才能真正裁切
        container.maskImage = PanelTheme.roundedMask(radius: Self.height / 2)

        dotView.wantsLayer = true
        dotView.layer?.masksToBounds = true
        dotView.layer?.cornerRadius = Self.dot / 2

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true

        checkLayer.fillColor = nil
        checkLayer.lineWidth = 2.4
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        checkLayer.strokeColor = NSColor.white.cgColor
        checkLayer.isHidden = true

        captionLabel.font = Self.font
        captionLabel.textColor = PanelTheme.fg
        captionLabel.alignment = .left
        captionLabel.lineBreakMode = .byTruncatingTail

        dotView.addSubview(iconView)
        dotView.layer?.addSublayer(checkLayer)
        container.addSubview(dotView)
        container.addSubview(captionLabel)
        panel.contentView = container
    }

    /// 在指定屏幕下方弹出（水平居中，纵向距屏幕底部约 16% 高度）。
    func show(_ kind: Kind, on screen: NSScreen) {
        let H = Self.height
        captionLabel.stringValue = kind.caption
        captionLabel.textColor = PanelTheme.fg

        // 胶囊总宽按文字实际渲染宽度算：NSTextField 排版比 NSString.size 宽约 4pt，
        // 直接用 sizeToFit 量准，否则短文案尾字会被截成「…」。
        captionLabel.sizeToFit()
        let textW = ceil(captionLabel.frame.width)
        let iconBlock = Self.leftPad + Self.dot + Self.gap
        let width = iconBlock + textW + Self.rightPad

        // 圆形徽章
        let dotY = (H - Self.dot) / 2
        let dotFrame = NSRect(x: Self.leftPad, y: dotY, width: Self.dot, height: Self.dot)
        dotView.frame = dotFrame
        dotView.layer?.backgroundColor = kind.tint.cgColor
        iconView.frame = dotView.bounds.insetBy(dx: 4, dy: 4)
        checkLayer.frame = dotView.bounds
        checkLayer.path = Self.checkmarkPath(in: dotView.bounds)

        // 文案（垂直居中）
        let labelH: CGFloat = 20
        captionLabel.frame = NSRect(x: iconBlock, y: (H - labelH) / 2 - 0.5,
                                    width: textW, height: labelH)

        // copied 用描边对勾；其余用白色 SF 字形
        if kind == .copied {
            iconView.isHidden = true
            checkLayer.isHidden = false
        } else {
            iconView.isHidden = false
            checkLayer.isHidden = true
            iconView.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(pointSize: 11, weight: .bold)
                    .applying(.init(hierarchicalColor: .white))
                )
        }

        // 尺寸 + 定位
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: (visible.midX - width / 2).rounded(),
            y: (visible.minY + visible.height * 0.16).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: H)), display: true)
        panel.invalidateShadow()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        playIn(kind: kind)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// 整体弹入（轻微放大 + 从下方上滑），copied 额外「画出」对勾。
    private func playIn(kind: Kind) {
        if let layer = container.layer {
            var from = CATransform3DIdentity
            from = CATransform3DTranslate(from, 0, -10, 0)   // 起始略低 10pt
            from = CATransform3DScale(from, 0.94, 0.94, 1)
            let t = CABasicAnimation(keyPath: "transform")
            t.fromValue = NSValue(caTransform3D: from)
            t.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            t.duration = 0.30
            t.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(t, forKey: "in")
        }

        guard kind == .copied else { return }
        checkLayer.removeAllAnimations()
        checkLayer.strokeEnd = 1
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0; draw.toValue = 1
        draw.duration = 0.30
        draw.beginTime = CACurrentMediaTime() + 0.08
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        checkLayer.add(draw, forKey: "draw")
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    /// 对勾路径（三段折线，比例坐标 × box 尺寸；non-flipped，原点左下）
    private static func checkmarkPath(in box: NSRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.width * 0.26, y: box.height * 0.50))
        path.addLine(to: CGPoint(x: box.width * 0.43, y: box.height * 0.33))
        path.addLine(to: CGPoint(x: box.width * 0.74, y: box.height * 0.66))
        return path
    }
}
