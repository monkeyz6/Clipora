// Clipora 应用图标绘制脚本：swift render_icon.swift <输出目录>
// 在 1024pt 逻辑画布上矢量绘制，按需缩放输出各尺寸 PNG。
import AppKit

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func starPath(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let inner = radius * 0.42
    for i in 0..<10 {
        let angle = CGFloat(i) * .pi / 5 - .pi / 2
        let r = i % 2 == 0 ? radius : inner
        let p = NSPoint(x: center.x + r * cos(angle), y: center.y - r * sin(angle))
        if i == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

func draw(canvas: CGFloat) {
    let s = canvas / 1024.0
    func pt(_ v: CGFloat) -> CGFloat { v * s }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: pt(x), y: pt(y), width: pt(w), height: pt(h))
    }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // ── 底座：macOS 圆角方形 + 靛蓝渐变 ──
    let plate = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: pt(185), yRadius: pt(185))
    NSGraphicsContext.saveGraphicsState()
    let plateShadow = NSShadow()
    plateShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    plateShadow.shadowOffset = NSSize(width: 0, height: pt(-10))
    plateShadow.shadowBlurRadius = pt(24)
    plateShadow.set()
    c(88, 100, 232).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSGradient(starting: c(122, 138, 255), ending: c(70, 54, 210))?
        .draw(in: rect(100, 100, 824, 824), angle: -90)
    // 顶部高光（液态玻璃）：自顶向下柔和消隐，无硬边界
    NSGradient(starting: c(255, 255, 255, 0.20), ending: c(255, 255, 255, 0))?
        .draw(in: rect(100, 560, 824, 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // ── 后层历史卡片（半透明，暗示"剪贴历史"层叠） ──
    let backCard = NSBezierPath(roundedRect: rect(332, 252, 440, 560), xRadius: pt(64), yRadius: pt(64))
    c(255, 255, 255, 0.32).setFill()
    backCard.fill()

    // ── 主剪贴板 ──
    let boardRect = rect(272, 200, 440, 560)
    let board = NSBezierPath(roundedRect: boardRect, xRadius: pt(64), yRadius: pt(64))
    NSGraphicsContext.saveGraphicsState()
    let boardShadow = NSShadow()
    boardShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    boardShadow.shadowOffset = NSSize(width: 0, height: pt(-12))
    boardShadow.shadowBlurRadius = pt(30)
    boardShadow.set()
    NSColor.white.setFill()
    board.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    board.addClip()
    NSGradient(starting: c(255, 255, 255), ending: c(232, 234, 244))?
        .draw(in: boardRect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // ── 夹子：跨在板顶边的深靛蓝胶囊 + 圆孔 ──
    let clipRect = rect(412, 716, 200, 88)
    let clip = NSBezierPath(roundedRect: clipRect, xRadius: pt(44), yRadius: pt(44))
    NSGraphicsContext.saveGraphicsState()
    let clipShadow = NSShadow()
    clipShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    clipShadow.shadowOffset = NSSize(width: 0, height: pt(-6))
    clipShadow.shadowBlurRadius = pt(12)
    clipShadow.set()
    c(52, 44, 150).setFill()
    clip.fill()
    NSGraphicsContext.restoreGraphicsState()
    let hole = NSBezierPath(ovalIn: rect(486, 738, 52, 52))
    c(122, 138, 255).setFill()
    hole.fill()

    // ── 板面剪贴条（三行，长短不一 = 历史记录） ──
    let lineColor = c(178, 186, 218)
    for (y, w) in [(608.0, 312.0), (516.0, 216.0), (424.0, 264.0)] {
        let bar = NSBezierPath(roundedRect: rect(328, y, w, 44), xRadius: pt(22), yRadius: pt(22))
        lineColor.setFill()
        bar.fill()
    }

    // ── 金色收藏星（呼应应用内 starActive） ──
    let star = starPath(center: NSPoint(x: pt(612), y: pt(538)), radius: pt(52))
    NSGraphicsContext.saveGraphicsState()
    let starShadow = NSShadow()
    starShadow.shadowColor = c(247, 179, 43, 0.45)
    starShadow.shadowOffset = .zero
    starShadow.shadowBlurRadius = pt(18)
    starShadow.set()
    c(247, 179, 43).setFill()
    star.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(canvas: CGFloat(px))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// (文件名, 像素) —— 同时覆盖 iconset 与 appiconset 所需的全部规格
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    try render(px: px).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("wrote \(name) (\(px)px)")
}
