// Renders the app icon (Resources/AppIcon.icns) with AppKit.
// Usage: swift scripts/make_icon.swift <output.iconset-dir>

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = 185 * s

    // Body with vertical gradient
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(calibratedWhite: 0.25, alpha: 1), ending: NSColor(calibratedWhite: 0.07, alpha: 1))!
        .draw(in: shape, angle: -90)
    NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
    shape.lineWidth = 6 * s
    shape.stroke()

    // Browser window
    let window = NSRect(x: 230 * s, y: 330 * s, width: 564 * s, height: 400 * s)
    let windowPath = NSBezierPath(roundedRect: window, xRadius: 36 * s, yRadius: 36 * s)
    NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
    windowPath.fill()
    NSGraphicsContext.saveGraphicsState()
    windowPath.addClip()
    NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
    NSRect(x: window.minX, y: window.maxY - 78 * s, width: window.width, height: 78 * s).fill()
    for i in 0..<3 {
        let dot = NSRect(x: window.minX + (36 + CGFloat(i) * 46) * s, y: window.maxY - 52 * s, width: 26 * s, height: 26 * s)
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
    // Content lines
    NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
    for (i, width) in [380.0, 300.0, 340.0].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: window.minX + 50 * s, y: window.maxY - (140 + CGFloat(i) * 62) * s, width: CGFloat(width) * s, height: 30 * s),
                     xRadius: 15 * s, yRadius: 15 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Broadcast waves + live dot
    let center = NSPoint(x: 700 * s, y: 300 * s)
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 120 * s, y: center.y - 120 * s, width: 240 * s, height: 240 * s)).fill()
    let red = NSColor(calibratedRed: 0.93, green: 0.17, blue: 0.21, alpha: 1)
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 52 * s, y: center.y - 52 * s, width: 104 * s, height: 104 * s)).fill()
    red.setStroke()
    for radiusStep in [80.0, 108.0] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: CGFloat(radiusStep) * s, startAngle: -40, endAngle: 40)
        arc.lineWidth = 16 * s
        arc.lineCapStyle = .round
        arc.stroke()
        let arc2 = NSBezierPath()
        arc2.appendArc(withCenter: center, radius: CGFloat(radiusStep) * s, startAngle: 140, endAngle: 220)
        arc2.lineWidth = 16 * s
        arc2.lineCapStyle = .round
        arc2.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    let rep = drawIcon(size: size)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
}
print("Wrote \(sizes.count) icon images to \(output.path)")
