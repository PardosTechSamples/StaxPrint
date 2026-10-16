// Generates the StaxPrint logo: a stack of three instant-film prints, seen in perspective.
//   swift scripts/make-logo.swift        (from instax-swift/) -> assets/
// Writes SVG and PNG from the same geometry, plus a macOS AppIcon.icns.

import AppKit
import CoreText

// MARK: palette (from the sketch)
let navy = NSColor(srgbRed: 0.173, green: 0.357, blue: 0.482, alpha: 1)     // #2C5B7B frame
let navyDeep = NSColor(srgbRed: 0.106, green: 0.239, blue: 0.333, alpha: 1) // #1B3D55 card edge
let ink = NSColor(srgbRed: 0.055, green: 0.133, blue: 0.2, alpha: 1)        // #0E2233 outline
let green = NSColor(srgbRed: 0.42, green: 0.66, blue: 0.24, alpha: 1)       // #6BA83D photo rim
let paper = NSColor.white

func hex(_ c: NSColor) -> String {
    let c = c.usingColorSpace(.sRGB)!
    return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                  Int(round(c.blueComponent * 255)))
}

// MARK: geometry

struct Shape {
    var path: CGPath
    var fill: NSColor?
    var stroke: NSColor?
    var width: CGFloat = 0
}

/// One Polaroid-style print laid flat: card 88 x 107 with a square photo window and a deep bottom border.
/// Projected with the perspective of the original sketch: the card's width runs up-right, its height runs
/// down-right toward the viewer, so the deep border is the near edge. `s` = output px per sketch px.
func card(at center: CGPoint, scale s: CGFloat, turn: CGFloat) -> [Shape] {
    let W: CGFloat = 88, H: CGFloat = 107
    let a = turn * .pi / 180
    func rot(_ v: CGVector) -> CGVector { CGVector(dx: v.dx * cos(a) - v.dy * sin(a), dy: v.dx * sin(a) + v.dy * cos(a)) }
    let ex = rot(CGVector(dx: 340 / W * s, dy: -69 / W * s))      // sketch: left corner -> top corner
    let ey = rot(CGVector(dx: 320 / H * s, dy: 111 / H * s))      // sketch: left corner -> bottom corner
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let cx = x - W / 2, cy = y - H / 2
        return CGPoint(x: center.x + cx * ex.dx + cy * ey.dx, y: center.y + cx * ex.dy + cy * ey.dy)
    }
    func quad(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGPath {
        let m = CGMutablePath()
        m.addLines(between: [p(x0, y0), p(x1, y0), p(x1, y1), p(x0, y1)])
        m.closeSubpath()
        return m
    }
    // Card thickness: the outline pushed down, drawn first in a deeper navy.
    let thick = 9 * s
    let top = [p(0, 0), p(W, 0), p(W, H), p(0, H)]
    let hull = CGMutablePath()
    hull.addLines(between: convexHull(top + top.map { CGPoint(x: $0.x, y: $0.y + thick) }))
    hull.closeSubpath()
    return [
        Shape(path: hull, fill: navyDeep, stroke: ink, width: 4 * s),
        Shape(path: quad(0, 0, W, H), fill: navy, stroke: ink, width: 4 * s),
        Shape(path: quad(7, 7, W - 7, W - 7), fill: paper, stroke: green, width: 5 * s),
    ]
}

func convexHull(_ points: [CGPoint]) -> [CGPoint] {
    let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var lower = [CGPoint](), upper = [CGPoint]()
    for q in p { while lower.count >= 2 && cross(lower[lower.count - 2], lower.last!, q) <= 0 { lower.removeLast() }; lower.append(q) }
    for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper.last!, q) <= 0 { upper.removeLast() }; upper.append(q) }
    return Array(lower.dropLast() + upper.dropLast())
}

/// The mark: three prints, bottom one first, fanned slightly like a casual stack. Centre (c) is the top card.
func mark(center c: CGPoint, scale s: CGFloat) -> [Shape] {
    card(at: CGPoint(x: c.x - 6 * s, y: c.y + 150 * s), scale: s, turn: 3)
        + card(at: CGPoint(x: c.x - 12 * s, y: c.y + 78 * s), scale: s, turn: -2)
        + card(at: c, scale: s, turn: 0)
}

/// Text as outlines (y down), so the SVG looks the same without the font installed.
func textShapes(_ parts: [(String, NSColor)], size: CGFloat, center: CGPoint, baseline: CGFloat) -> [Shape] {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
    var total: CGFloat = 0
    var runs: [(CTLine, NSColor, CGFloat)] = []
    for (s, color) in parts {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .kern: -0.01 * size]))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        runs.append((line, color, total))
        total += w
    }
    var shapes = [Shape]()
    for (line, color, x0) in runs {
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<n {
                guard let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                // Flip y (glyphs are y-up) and place.
                var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: center.x - total / 2 + x0 + pos[i].x, ty: baseline)
                if let placed = g.copy(using: &t) { path.addPath(placed) }
            }
        }
        shapes.append(Shape(path: path, fill: color))
    }
    return shapes
}

// MARK: output

func svgPath(_ p: CGPath) -> String {
    var d = ""
    let f = { (v: CGFloat) in String(format: "%.2f", v) }
    p.applyWithBlock { e in
        let pt = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(f(pt[0].x)) \(f(pt[0].y))"
        case .addLineToPoint: d += "L\(f(pt[0].x)) \(f(pt[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(pt[0].x)) \(f(pt[0].y)) \(f(pt[1].x)) \(f(pt[1].y))"
        case .addCurveToPoint: d += "C\(f(pt[0].x)) \(f(pt[0].y)) \(f(pt[1].x)) \(f(pt[1].y)) \(f(pt[2].x)) \(f(pt[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func writeSVG(_ shapes: [Shape], size: CGSize, background: String? = nil, to url: URL, title: String) throws {
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(size.width)) \(Int(size.height))\" width=\"\(Int(size.width))\" height=\"\(Int(size.height))\">\n<title>\(title)</title>\n"
    if let background { s += background + "\n" }
    for sh in shapes {
        s += "<path d=\"\(svgPath(sh.path))\" fill=\"\(sh.fill.map(hex) ?? "none")\""
        if let st = sh.stroke { s += " stroke=\"\(hex(st))\" stroke-width=\"\(String(format: "%.2f", sh.width))\" stroke-linejoin=\"round\"" }
        s += "/>\n"
    }
    s += "</svg>\n"
    try s.write(to: url, atomically: true, encoding: .utf8)
}

func writePNG(_ shapes: [Shape], size: CGSize, px: Int, background: ((CGContext, CGFloat) -> Void)? = nil, to url: URL) throws {
    let scale = CGFloat(px) / size.width
    let h = Int(round(size.height * scale))
    let ctx = CGContext(data: nil, width: px, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)       // y down, like the SVG
    background?(ctx, scale)
    ctx.setLineJoin(.round)
    for sh in shapes {
        ctx.addPath(sh.path)
        if let f = sh.fill { ctx.setFillColor(f.cgColor) }
        if let st = sh.stroke { ctx.setStrokeColor(st.cgColor); ctx.setLineWidth(sh.width) }
        ctx.drawPath(using: sh.fill != nil && sh.stroke != nil ? .fillStroke : (sh.fill != nil ? .fill : .stroke))
    }
    let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dst)
}

let out = URL(fileURLWithPath: "assets", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// 1. Logo: mark with the wordmark under it (transparent background).
let logoSize = CGSize(width: 1000, height: 690)
let logo = mark(center: CGPoint(x: 500, y: 165), scale: 1.0)
    + textShapes([("Stax", navy), ("Print", green)], size: 150, center: CGPoint(x: 500, y: 0), baseline: 625)
try writeSVG(logo, size: logoSize, to: out.appendingPathComponent("staxprint-logo.svg"), title: "StaxPrint")
try writePNG(logo, size: logoSize, px: 2000, to: out.appendingPathComponent("staxprint-logo.png"))

// 2. Mark only.
let markSize = CGSize(width: 600, height: 460)
let markShapes = mark(center: CGPoint(x: 300, y: 150), scale: 0.78)
try writeSVG(markShapes, size: markSize, to: out.appendingPathComponent("staxprint-mark.svg"), title: "StaxPrint")
try writePNG(markShapes, size: markSize, px: 1200, to: out.appendingPathComponent("staxprint-mark.png"))

// 3. macOS app icon: the mark on a light rounded square (824 of 1024, Apple's icon grid).
let iconSize = CGSize(width: 1024, height: 1024)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
let top = NSColor(srgbRed: 0.97, green: 0.98, blue: 0.99, alpha: 1), bottom = NSColor(srgbRed: 0.85, green: 0.91, blue: 0.95, alpha: 1)
let iconShapes = mark(center: CGPoint(x: 512, y: 435), scale: 0.98)
let iconBG = """
<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(hex(top))"/><stop offset="1" stop-color="\(hex(bottom))"/></linearGradient></defs>
<path d="\(svgPath(tilePath))" fill="url(#bg)"/>
"""
try writeSVG(iconShapes, size: iconSize, background: iconBG, to: out.appendingPathComponent("staxprint-icon.svg"), title: "StaxPrint")
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let drawTile: (CGContext, CGFloat) -> Void = { ctx, _ in
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(bottom.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    ctx.restoreGState()
}
try writePNG(iconShapes, size: iconSize, px: 1024, background: drawTile, to: out.appendingPathComponent("staxprint-icon.png"))
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try writePNG(iconShapes, size: iconSize, px: px, background: drawTile, to: iconset.appendingPathComponent("icon_\(name).png"))
}
let ic = Process(); ic.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
ic.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try ic.run(); ic.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print("wrote assets/: logo, mark and icon as SVG + PNG, AppIcon.icns")
