import Cocoa

// 菜单栏（状态栏）模板图标生成：黑色鼠标剪影 + 透明滚轮镂空
// 产出 assets/menubar-icon.png（18×18）与 assets/menubar-icon@2x.png（36×36）
// isTemplate=true 后系统自动反色：深色菜单栏显白、浅色显黑。
// 用法: swift assets/make-menubar-icon.swift

func drawMouse(pixels: Int) -> NSBitmapImageRep {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // 鼠标身体：竖向圆角矩形，紧贴画布（上下各留 1px 呼吸位）
    let body = NSRect(x: s * 0.24, y: s * 0.03, width: s * 0.52, height: s * 0.94)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: s * 0.26, yRadius: s * 0.26)
    NSColor.black.setFill()
    bodyPath.fill()

    // 滚轮：透明镂空
    ctx.setBlendMode(.clear)
    let wheel = NSBezierPath(roundedRect: NSRect(x: s * 0.44, y: s * 0.56, width: s * 0.12, height: s * 0.24),
                             xRadius: s * 0.06, yRadius: s * 0.06)
    wheel.fill()
    // 按键分割线：透明镂空
    let split = NSBezierPath(roundedRect: NSRect(x: body.minX, y: s * 0.50, width: body.width, height: s * 0.05),
                             xRadius: s * 0.025, yRadius: s * 0.025)
    split.fill()
    ctx.setBlendMode(.normal)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (px, name) in [(18, "menubar-icon.png"), (36, "menubar-icon@2x.png")] {
    let rep = drawMouse(pixels: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("export failed") }
    try png.write(to: URL(fileURLWithPath: "assets/\(name)"))
    print("assets/\(name) written")
}
