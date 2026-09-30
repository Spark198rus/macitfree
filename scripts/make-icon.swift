// Renders the MacItFree app icon into an .iconset folder (convert with `iconutil -c icns`).
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)

    // Rounded "squircle" tile with a blue→violet gradient (macOS Big Sur+ icon grid: ~10% margin).
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.03
    shadow.set()
    NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.60, blue: 1.00, alpha: 1),
        ending: NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.90, alpha: 1)
    )!.draw(in: path, angle: -90)
    NSShadow().set()

    // Zipper teeth down the middle.
    let toothWidth = size * 0.07
    let toothHeight = size * 0.035
    var y = tile.maxY - size * 0.06
    var left = true
    NSColor.white.withAlphaComponent(0.85).setFill()
    while y > tile.midY + size * 0.02 {
        let x = left ? size / 2 - toothWidth : size / 2
        NSBezierPath(roundedRect: NSRect(x: x, y: y - toothHeight, width: toothWidth, height: toothHeight), xRadius: toothHeight / 3, yRadius: toothHeight / 3).fill()
        y -= toothHeight * 1.25
        left.toggle()
    }

    // Archive box glyph.
    if let symbol = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.34, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let glyph = symbol.withSymbolConfiguration(config) {
            let glyphSize = glyph.size
            let rect = NSRect(x: (size - glyphSize.width) / 2, y: tile.minY + size * 0.12, width: glyphSize.width, height: glyphSize.height)
            glyph.draw(in: rect)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in variants {
    try render(pixels).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
print("Wrote \(variants.count) images to \(output)")
