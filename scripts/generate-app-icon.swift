// Renders the app icon set from code: a window pouring into the Dock, the way
// it minimizes, so the project needs no design tool to produce
// EasyDockApp/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Run once (or whenever the look changes):
//   swift scripts/generate-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("EasyDockApp/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(blur: CGFloat, y: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Drawn on a 1024-point canvas; every size is scaled down from it.
func drawIcon() {
    // macOS icon grid: the squircle occupies ~80% of the canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [color(0x3E6BF0), color(0x1A2466)])!.draw(in: squircle, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 600, width: 824, height: 324), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The Dock, with an app on each side of the one the window goes into.
    withShadow(blur: 24, y: -8, alpha: 0.25) {
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: 196, y: 172, width: 632, height: 104), xRadius: 34, yRadius: 34).fill()
    }
    for (x, hex) in [(CGFloat(318), UInt32(0xFF8A5B)), (706, 0x5BE3B5)] {
        color(hex).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 38, y: 186, width: 76, height: 76), xRadius: 20, yRadius: 20).fill()
    }

    // The window and the funnel it narrows into, as one shape.
    let top: CGFloat = 836, waist: CGFloat = 556, left: CGFloat = 238, right: CGFloat = 786
    let neckLeft: CGFloat = 474, neckRight: CGFloat = 550, neckY: CGFloat = 214
    let window = NSBezierPath()
    window.move(to: NSPoint(x: left, y: top - 34))
    window.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: left + 34, y: top), radius: 34)
    window.line(to: NSPoint(x: right - 34, y: top))
    window.appendArc(from: NSPoint(x: right, y: top), to: NSPoint(x: right, y: top - 34), radius: 34)
    window.line(to: NSPoint(x: right, y: waist))
    window.curve(to: NSPoint(x: neckRight, y: neckY), controlPoint1: NSPoint(x: right, y: 400), controlPoint2: NSPoint(x: neckRight, y: 380))
    window.line(to: NSPoint(x: neckLeft, y: neckY))
    window.curve(to: NSPoint(x: left, y: waist), controlPoint1: NSPoint(x: neckLeft, y: 380), controlPoint2: NSPoint(x: left, y: 400))
    window.close()
    withShadow(blur: 40, y: -14, alpha: 0.30) {
        NSColor.white.setFill()
        window.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    window.addClip()
    NSGradient(colors: [color(0xFFFFFF), color(0xEAF0FF), color(0xB9CBFF)])!
        .draw(in: NSRect(x: left, y: neckY, width: right - left, height: top - neckY), angle: -90)
    color(0xDDE5F7).setFill()
    NSRect(x: left, y: top - 78, width: right - left, height: 78).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        color(hex).setFill()
        NSBezierPath(ovalIn: NSRect(x: left + 37 + CGFloat(index) * 46, y: top - 54, width: 30, height: 30)).fill()
    }
    color(0xC9D5F2).setFill()
    for (index, width) in [CGFloat(330), 260, 300].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: left + 52, y: top - 140 - CGFloat(index) * 52, width: width, height: 22), xRadius: 11, yRadius: 11).fill()
    }
}

var entries: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    entries.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: iconset.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icons to \(iconset.path)")
