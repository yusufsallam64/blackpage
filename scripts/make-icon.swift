// Draws the app icon and writes Resources/AppIcon.icns.
// usage: swift scripts/make-icon.swift <scratch-dir>
import AppKit

let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // body: macOS icon grid, 824pt square with ~185pt corners
    let body = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                            xRadius: 185 * s, yRadius: 185 * s)
    NSColor.black.setFill()
    body.fill()
    let rim = NSBezierPath(roundedRect: NSRect(x: 102 * s, y: 102 * s, width: 820 * s, height: 820 * s),
                           xRadius: 183 * s, yRadius: 183 * s)
    rim.lineWidth = max(1, 4 * s)
    NSColor(white: 1, alpha: 0.10).setStroke()
    rim.stroke()

    // three lines of "text", the last one short, followed by the caret
    let ink = NSColor(srgbRed: 0.36, green: 0.35, blue: 0.33, alpha: 1)
    let x0: CGFloat = 250
    let lines: [(CGFloat, CGFloat)] = [(604, 520), (512, 440), (420, 230)]  // center y, width
    ink.setFill()
    for (y, w) in lines {
        NSBezierPath(roundedRect: NSRect(x: x0 * s, y: (y - 17) * s, width: w * s, height: 34 * s),
                     xRadius: 17 * s, yRadius: 17 * s).fill()
    }
    NSColor(srgbRed: 0.918, green: 0.902, blue: 0.871, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: (x0 + 230 + 34) * s, y: 368 * s, width: 22 * s, height: 104 * s),
                 xRadius: 11 * s, yRadius: 11 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try! draw(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print(iconset.path)
