// Renders every TV Display icon from one drawing:
//   swift art/make-icons.swift <out-dir>
// Produces AppIcon.iconset/ (for iconutil), tv_icon.png, tv_banner.png and tv_hero.png.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let top = NSColor(srgbRed: 0.40, green: 0.36, blue: 0.98, alpha: 1)    // indigo
let bottom = NSColor(srgbRed: 0.10, green: 0.70, blue: 1.00, alpha: 1) // sky

func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func gradient(_ ctx: CGContext, _ rect: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
}

/// White TV with a stand and broadcast waves, fitted into `r` (a square).
func glyph(_ ctx: CGContext, _ r: CGRect) {
    let s = r.width
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05,
                  color: NSColor(white: 0, alpha: 0.25).cgColor)
    let white = NSColor.white.cgColor

    // Screen bezel
    let body = CGRect(x: r.minX + s * 0.06, y: r.minY + s * 0.20, width: s * 0.88, height: s * 0.58)
    let bezel = CGPath(roundedRect: body, cornerWidth: s * 0.07, cornerHeight: s * 0.07, transform: nil)
    ctx.addPath(bezel)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(s * 0.065)
    ctx.strokePath()

    // Stand
    ctx.setFillColor(white)
    let neck = CGRect(x: r.midX - s * 0.045, y: r.minY + s * 0.10, width: s * 0.09, height: s * 0.10)
    ctx.fill(neck)
    let foot = CGRect(x: r.midX - s * 0.20, y: r.minY + s * 0.06, width: s * 0.40, height: s * 0.065)
    ctx.addPath(CGPath(roundedRect: foot, cornerWidth: s * 0.032, cornerHeight: s * 0.032, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // Waves radiating from the bottom of the screen
    ctx.saveGState()
    ctx.setStrokeColor(white)
    ctx.setLineCap(.round)
    let c = CGPoint(x: r.midX, y: body.minY + s * 0.11)
    ctx.setFillColor(white)
    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.045, y: c.y - s * 0.045, width: s * 0.09, height: s * 0.09))
    for (i, rad) in [0.15, 0.26, 0.37].enumerated() {
        ctx.setLineWidth(s * 0.055)
        ctx.setAlpha(1 - CGFloat(i) * 0.18)
        ctx.addArc(center: c, radius: s * rad, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

/// macOS-style app icon: rounded tile with margins, gradient, glyph.
func appIcon(_ px: Int, margin: Bool = true) -> NSBitmapImageRep {
    render(px, px) { ctx in
        let s = CGFloat(px)
        let tile = margin ? CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
                          : CGRect(x: 0, y: 0, width: s, height: s)
        let radius = tile.width * 0.225
        if margin {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025,
                          color: NSColor(white: 0, alpha: 0.35).cgColor)
            ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(top.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        gradient(ctx, tile)
        // soft top highlight
        let hl = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [NSColor(white: 1, alpha: 0.18).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
        ctx.restoreGState()
        let g = tile.width * 0.64
        glyph(ctx, CGRect(x: tile.midX - g / 2, y: tile.midY - g / 2 - tile.width * 0.01, width: g, height: g))
    }
}

// macOS iconset
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    let one = appIcon(base), two = appIcon(base * 2)
    try! one.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! two.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// Android TV launcher icon (full-bleed rounded tile) and hero art for the idle screen
save(appIcon(192, margin: false), "tv_icon.png")
save(render(320, 320) { ctx in glyph(ctx, CGRect(x: 0, y: 0, width: 320, height: 320)) }, "tv_hero.png")

// Android TV home-row banner, 320x180dp → 640x360px (xhdpi)
save(render(640, 360) { ctx in
    let r = CGRect(x: 0, y: 0, width: 640, height: 360)
    gradient(ctx, r)
    glyph(ctx, CGRect(x: 44, y: 70, width: 220, height: 220))
    let title = NSAttributedString(string: "TV Display", attributes: [
        .font: NSFont.systemFont(ofSize: 62, weight: .bold), .foregroundColor: NSColor.white])
    let sub = NSAttributedString(string: "Wireless screen for Mac", attributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.85)])
    title.draw(at: CGPoint(x: 290, y: 178))
    sub.draw(at: CGPoint(x: 292, y: 130))
}, "tv_banner.png")

print("icons written to \(out.path)")
