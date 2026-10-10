// Renders Resources/AppIcon.icns from an SF Symbol on a gradient squircle.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.36, green: 0.55, blue: 1, alpha: 1),
               ending: NSColor(red: 0.47, green: 0.25, blue: 0.93, alpha: 1))!.draw(in: path, angle: -70)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let r = NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2 - s * 0.01,
                       width: sym.size.width, height: sym.size.height)
        sym.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in sizes {
    if px <= 512 { try! render(px).write(to: iconset.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try! render(px).write(to: iconset.appendingPathComponent("icon_\(px / 2)x\(px / 2)@2x.png")) }
}
