// Renders the Shelfy app icon ("pile" logo) into an .iconset folder.
//
//   swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
//
// Drawn natively with CoreGraphics on the macOS icon grid (824 pt body in a 1024 pt canvas).
import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let indigoTop = color(0x7690F4)
let indigoBottom = color(0x5B72E6)
let navy = color(0x0F1530)
let deepIndigo = color(0x2A3A8F)
let periwinkle = color(0xC7CEFB)
let accent = color(0x6A82EE)
let white = color(0xFFFFFF)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work top-down like the SVG master.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)

    // Body with a soft drop shadow and a gentle top-to-bottom gradient.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03, color: color(0x0F1530, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(indigoBottom)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [indigoTop, indigoBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

    // Artwork in 120-unit SVG coordinates mapped onto the body.
    let u = body.width / 120
    ctx.translateBy(x: body.minX, y: body.minY)
    ctx.scaleBy(x: u, y: u)
    // Enlarge the pile around its center so it reads at Dock and Finder sizes.
    ctx.translateBy(x: 60, y: 61)
    ctx.scaleBy(x: 1.32, y: 1.32)
    ctx.translateBy(x: -60, y: -61)

    func card(_ outer: CGRect, _ inner: CGRect, fill: CGColor, angle: CGFloat, pivot: CGPoint, shadow: Bool = true) {
        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: angle * .pi / 180)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 1.2 * u), blur: 3 * u, color: color(0x0F1530, 0.28)) }
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(white)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }

    card(CGRect(x: 30, y: 38, width: 56, height: 44), CGRect(x: 34, y: 42, width: 48, height: 36), fill: deepIndigo, angle: -12, pivot: CGPoint(x: 60, y: 64))
    card(CGRect(x: 34, y: 36, width: 56, height: 44), CGRect(x: 38, y: 40, width: 48, height: 36), fill: navy, angle: 9, pivot: CGPoint(x: 60, y: 60))
    card(CGRect(x: 31, y: 40, width: 58, height: 45), CGRect(x: 35, y: 44, width: 50, height: 37), fill: periwinkle, angle: 0, pivot: .zero)

    // Front photo: mountains and a sun, clipped to the photo area.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 35, y: 44, width: 50, height: 37), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
    ctx.clip()
    let mountains = CGMutablePath()
    mountains.move(to: CGPoint(x: 35, y: 81))
    mountains.addLine(to: CGPoint(x: 52, y: 63))
    mountains.addLine(to: CGPoint(x: 63, y: 73))
    mountains.addLine(to: CGPoint(x: 70, y: 66))
    mountains.addLine(to: CGPoint(x: 85, y: 81))
    mountains.closeSubpath()
    ctx.addPath(mountains)
    ctx.setFillColor(accent)
    ctx.fillPath()
    ctx.setFillColor(white)
    ctx.fillEllipse(in: CGRect(x: 69, y: 49, width: 10, height: 10))
    ctx.restoreGState()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Wrote \(iconset.path)")
