// Renders Resources/AppIcon.icns: a black rounded tile with a white play triangle sliced
// into horizontal bands (a nod to custom playback speed).
// Usage: swift tools/make_icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let black = CGColor(gray: 0.06, alpha: 1)
let white = CGColor(gray: 0.97, alpha: 1)

/// Right-pointing triangle with rounded vertices; (cx, cy) is its centroid.
func triangle(cx: CGFloat, cy: CGFloat, r: CGFloat, corner: CGFloat) -> CGPath {
    let p = [CGPoint(x: cx + r, y: cy),
             CGPoint(x: cx - r * 0.5, y: cy + r * 0.866),
             CGPoint(x: cx - r * 0.5, y: cy - r * 0.866)]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (p[0].x + p[2].x) / 2, y: (p[0].y + p[2].y) / 2))
    for i in 0..<3 { path.addArc(tangent1End: p[i], tangent2End: p[(i + 1) % 3], radius: corner) }
    path.closeSubpath()
    return path
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)   // draw in a 1024 grid

    // macOS icon grid: 824pt body inset 100pt, corner radius ~185pt, soft drop shadow.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    c.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                     cornerWidth: 185, cornerHeight: 185, transform: nil))
    c.setFillColor(black)
    c.fillPath()
    c.restoreGState()

    // The bands make the flat left edge read heavy, so the triangle is placed by its bounding
    // box (nudged 32pt right to offset the rounded tip) rather than by its centroid.
    let r: CGFloat = 270, cy: CGFloat = 512
    let cx = 512 + 32 - r / 4
    // Small sizes get fewer, chunkier bands so the gaps survive downsampling.
    let bands = px <= 64 ? 3 : 5
    let gap: CGFloat = px <= 64 ? 56 : 30
    c.saveGState()
    c.addPath(triangle(cx: cx, cy: cy, r: r, corner: 34))
    c.clip()
    let height = r * 0.866 * 2, top = cy + r * 0.866
    let bandH = (height - gap * CGFloat(bands - 1)) / CGFloat(bands)
    for i in 0..<bands {
        c.addRect(CGRect(x: cx - r / 2, y: top - CGFloat(i + 1) * bandH - CGFloat(i) * gap,
                         width: r * 1.6, height: bandH))
    }
    c.setFillColor(white)
    c.fillPath()
    c.restoreGState()

    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(iconset.path)")
