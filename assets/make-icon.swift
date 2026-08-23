import Cocoa

// MouseFix 图标生成：macOS 圆角矩形 + 蓝色渐变 + 白色鼠标剪影
// 用法: swift assets/make-icon.swift
// 产物: assets/icon-1024.png（1024×1024）

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
defer { NSGraphicsContext.restoreGraphicsState() }

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// 1) 底板：macOS 风格圆角矩形 + 纵向蓝色渐变
let board = NSRect(x: 24, y: 24, width: S - 48, height: S - 48)
let boardPath = NSBezierPath(roundedRect: board, xRadius: 225, yRadius: 225)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.20, green: 0.68, blue: 1.00, alpha: 1),   // 亮蓝
    NSColor(srgbRed: 0.04, green: 0.36, blue: 0.93, alpha: 1),   // 深蓝
])!
gradient.draw(in: boardPath, angle: -90)

// 顶部内高光，增加立体感
let highlight = NSBezierPath(roundedRect: board.insetBy(dx: 6, dy: 6), xRadius: 219, yRadius: 219)
NSColor.white.withAlphaComponent(0.10).setStroke()
highlight.lineWidth = 3
highlight.stroke()

// 2) 鼠标剪影（白色，带柔和投影）
let mouseW: CGFloat = 400, mouseH: CGFloat = 610
let mouseRect = NSRect(x: (S - mouseW) / 2, y: (S - mouseH) / 2 - 10, width: mouseW, height: mouseH)
let mouse = NSBezierPath(roundedRect: mouseRect, xRadius: 200, yRadius: 200)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.white.setFill()
mouse.fill()
ctx.restoreGState()

// 3) 按键分割线（左右键分界）
let splitY = mouseRect.minY + mouseH * 0.60
let split = NSBezierPath()
split.move(to: NSPoint(x: mouseRect.minX + 30, y: splitY))
split.line(to: NSPoint(x: mouseRect.maxX - 30, y: splitY))
NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 0.55).setStroke()
split.lineWidth = 10
split.lineCapStyle = .round
split.stroke()

// 4) 滚轮（蓝色，呼应底板）
let wheel = NSBezierPath(roundedRect: NSRect(x: S / 2 - 34, y: splitY + 52, width: 68, height: 150),
                         xRadius: 34, yRadius: 34)
let wheelGrad = NSGradient(colors: [
    NSColor(srgbRed: 0.10, green: 0.50, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.04, green: 0.36, blue: 0.93, alpha: 1),
])!
wheelGrad.draw(in: wheel, angle: -90)

// 5) 滚轮两侧的上下滚动箭头（点题：滚轮修复）
func arrow(_ center: NSPoint, _ up: Bool) {
    let p = NSBezierPath()
    let w: CGFloat = 34, h: CGFloat = 22
    let d: CGFloat = up ? 1 : -1
    p.move(to: NSPoint(x: center.x - w, y: center.y - d * h))
    p.line(to: NSPoint(x: center.x, y: center.y + d * h))
    p.line(to: NSPoint(x: center.x + w, y: center.y - d * h))
    p.lineWidth = 14
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 0.9).setStroke()
    p.stroke()
}
arrow(NSPoint(x: S / 2 - 118, y: splitY + 128), true)    // 左键区：上箭头
arrow(NSPoint(x: S / 2 + 118, y: splitY + 128), false)   // 右键区：下箭头

// 6) 导出 PNG
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("export failed") }
try png.write(to: URL(fileURLWithPath: "assets/icon-1024.png"))
print("assets/icon-1024.png written")
