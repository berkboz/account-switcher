// Renders the app icon (a people symbol on a rounded gradient tile) into assets/AppIcon.iconset.
// Run from the repo root:
//   swift assets/make-icon.swift && iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
import AppKit

func tile(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
        let path = NSBezierPath(roundedRect: inset, xRadius: size * 0.18, yRadius: size * 0.18)
        NSGradient(starting: NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                   ending: NSColor(red: 0.36, green: 0.30, blue: 0.78, alpha: 1))!.draw(in: path, angle: -60)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = sym.size
            sym.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
}

let dir = URL(fileURLWithPath: "assets/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        tile(px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
