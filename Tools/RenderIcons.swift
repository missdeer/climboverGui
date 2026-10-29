import AppKit

func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

@main
struct RenderIcons {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let iconset = output.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let image = bitmap(width: pixels, height: pixels) {
                    ClimbOverArtwork.drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                }
                try write(image, to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
            }
        }
        let preview = bitmap(width: 1200, height: 760) {
            NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 760)).fill()
            ClimbOverArtwork.drawAppIcon(in: NSRect(x: 30, y: 130, width: 620, height: 620))
            let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 29, weight: .semibold), .foregroundColor: NSColor(srgbRed: 0.12, green: 0.15, blue: 0.19, alpha: 1)]
            ("ClimbOver" as NSString).draw(at: NSPoint(x: 735, y: 590), withAttributes: text)
            for (x, size) in zip([710, 870, 975, 1060], [128, 64, 32, 16]) {
                ClimbOverArtwork.drawAppIcon(in: NSRect(x: x, y: 390, width: size, height: size))
            }
            let states: [ClimbOverArtwork.State] = [.stopped, .connected, .working, .warning, .external]
            for (index, state) in states.enumerated() {
                let glyph = ClimbOverArtwork.menuImage(state: state)
                glyph.isTemplate = false
                glyph.draw(in: NSRect(x: 725 + index * 78, y: 255, width: 40, height: 36))
            }
            let caption: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor(srgbRed: 0.38, green: 0.42, blue: 0.47, alpha: 1)]
            ("16–1024 px · Native macOS" as NSString).draw(at: NSPoint(x: 725, y: 180), withAttributes: caption)
        }
        try write(preview, to: output.appendingPathComponent("icon-preview.png"))
    }
}
