import AppKit

/// Slot icons that say what the format *is*: a page with a transparency strip for PNG, a framed
/// photo for JPG, a browser for WebP, a printer for TIFF… Drawn GTA-HUD style — light bodies,
/// dark rims, a few colour accents — in a 100×100 box with y up.
enum Glyph {
    case png, jpg, heic, webp, avif, gif, tiff, pdf
    case longImage, word(String), text, markdown, rtf, html, odt
    case clapper, film, filmBadge(String), webVideo, loop, note(String, NSColor), waves, wavesBadge(String, NSColor), voice, vinyl, bell
    case compress, shrink, cutout, scan, mono, rotate, unpin, backdrop
    case split, merge, mute, screen720, cover, fast, slow
    case speaker, meter, counter, clipboard, zip, link, tag, fingerprint

    static func of(_ id: String) -> Glyph {
        switch id {
        case "img.to.png", "pdf.to.png": return .png
        case "img.to.jpg", "pdf.to.jpg": return .jpg
        case "img.to.heic": return .heic
        case "img.to.webp": return .webp
        case "img.to.avif": return .avif
        case "img.to.gif": return .gif
        case "img.to.tiff": return .tiff
        case "img.to.pdf", "doc.to.pdf": return .pdf
        case "pdf.to.long": return .longImage
        case "pdf.to.docx", "doc.to.docx": return .word("DOCX")
        case "doc.to.doc": return .word("DOC")
        case "pdf.to.txt", "doc.to.txt": return .text
        case "pdf.to.md", "doc.to.md": return .markdown
        case "pdf.to.rtf", "doc.to.rtf": return .rtf
        case "pdf.to.html", "doc.to.html": return .html
        case "doc.to.odt": return .odt
        case "vid.to.mp4": return .clapper
        case "vid.to.mov": return .film
        case "vid.to.hevc": return .filmBadge("H.265")
        case "vid.to.webm": return .webVideo
        case "vid.to.gif": return .loop
        case "vid.to.mp3", "aud.to.mp3": return .note("MP3", Ink.orange)
        case "vid.to.m4a", "aud.to.m4a": return .note("M4A", Ink.blue)
        case "vid.to.wav", "aud.to.wav": return .waves
        case "aud.to.flac": return .wavesBadge("FLAC", Ink.gold)
        case "aud.to.aiff": return .wavesBadge("AIFF", Ink.slate)
        case "aud.to.opus": return .voice
        case "aud.to.alac": return .vinyl
        case "aud.to.m4r": return .bell
        case "img.half": return .shrink
        case "img.cutout": return .cutout
        case "img.ocr", "pdf.ocr": return .scan
        case "img.mono", "pdf.mono": return .mono
        case "img.rotate", "pdf.rotate": return .rotate
        case "img.backdrop": return .backdrop
        case "pdf.split": return .split
        case "pdf.merge": return .merge
        case "vid.mute": return .mute
        case "vid.720p": return .screen720
        case "vid.cover": return .cover
        case "vid.fast", "aud.fast": return .fast
        case "vid.slow": return .slow
        case "aud.mono": return .speaker
        case "aud.loud": return .meter
        case "doc.count": return .counter
        case "doc.copy": return .clipboard
        case "gen.zip": return .zip
        case "gen.path": return .link
        case "gen.name": return .tag
        case "gen.sha": return .fingerprint
        default:
            if id.hasSuffix(".compress") { return .compress }
            if id.hasSuffix(".strip") { return .unpin }
            return .text
        }
    }

    /// Draws the icon fitted into `rect`, with a soft drop shadow under the whole group.
    func draw(in rect: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let side = min(rect.width, rect.height)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -side * 0.03), blur: side * 0.09, color: NSColor(white: 0, alpha: 0.55).cgColor)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.translateBy(x: rect.midX - side / 2, y: rect.midY - side / 2)
        cg.scaleBy(x: side / 100, y: side / 100)
        Painter(cg).paint(self)
        cg.endTransparencyLayer()
        cg.restoreGState()
    }
}

enum Ink {
    static let rim = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
    static let paper = (NSColor.white, NSColor(srgbRed: 0.85, green: 0.87, blue: 0.90, alpha: 1))
    static let metal = (NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.64, green: 0.67, blue: 0.71, alpha: 1))
    static let shadowMetal = (NSColor(srgbRed: 0.80, green: 0.82, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1))
    static let dark = (NSColor(srgbRed: 0.33, green: 0.35, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1))
    static let sky = (NSColor(srgbRed: 0.33, green: 0.63, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.78, green: 0.90, blue: 0.99, alpha: 1))
    static let sun = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.24, alpha: 1)
    static let hillBack = NSColor(srgbRed: 0.55, green: 0.80, blue: 0.37, alpha: 1)
    static let hillFront = NSColor(srgbRed: 0.27, green: 0.60, blue: 0.24, alpha: 1)
    static let red = NSColor(srgbRed: 0.85, green: 0.19, blue: 0.17, alpha: 1)
    static let blue = NSColor(srgbRed: 0.17, green: 0.43, blue: 0.82, alpha: 1)
    static let word = NSColor(srgbRed: 0.16, green: 0.34, blue: 0.62, alpha: 1)
    static let orange = NSColor(srgbRed: 0.93, green: 0.45, blue: 0.13, alpha: 1)
    static let gold = NSColor(srgbRed: 0.92, green: 0.68, blue: 0.14, alpha: 1)
    static let teal = NSColor(srgbRed: 0.08, green: 0.57, blue: 0.62, alpha: 1)
    static let purple = NSColor(srgbRed: 0.50, green: 0.32, blue: 0.78, alpha: 1)
    static let green = NSColor(srgbRed: 0.22, green: 0.64, blue: 0.33, alpha: 1)
    static let slate = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)
    static let ink = NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1)
}

private struct Painter {
    let cg: CGContext
    let rim: CGFloat = 3.6

    init(_ cg: CGContext) { self.cg = cg }

    // MARK: Primitives

    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0) -> CGPath {
        let box = CGRect(x: x, y: y, width: w, height: h)
        return r > 0 ? CGPath(roundedRect: box, cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil) : CGPath(rect: box, transform: nil)
    }

    func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts.map { CGPoint(x: $0.0, y: $0.1) })
        p.closeSubpath()
        return p
    }

    func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
    }

    /// Fill (flat or top→bottom gradient) then the dark rim.
    func body(_ path: CGPath, _ colors: (NSColor, NSColor), rim width: CGFloat? = nil) {
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        let box = path.boundingBoxOfPath
        let g = CGGradient(colorsSpace: nil, colors: [colors.0.cgColor, colors.1.cgColor] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(g, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
        cg.restoreGState()
        outline(path, width ?? rim)
    }

    func solid(_ path: CGPath, _ color: NSColor, rim width: CGFloat? = nil) {
        body(path, (color.mixed(with: .white, 0.18), color.mixed(with: .black, 0.12)), rim: width)
    }

    func outline(_ path: CGPath, _ width: CGFloat) {
        guard width > 0 else { return }
        cg.saveGState()
        cg.addPath(path)
        cg.setStrokeColor(Ink.rim.cgColor)
        cg.setLineWidth(width)
        cg.setLineJoin(.round)
        cg.setLineCap(.round)
        cg.strokePath()
        cg.restoreGState()
    }

    func line(_ pts: [(CGFloat, CGFloat)], _ color: NSColor = Ink.rim, width: CGFloat = 3) {
        let p = CGMutablePath()
        p.addLines(between: pts.map { CGPoint(x: $0.0, y: $0.1) })
        cg.saveGState()
        cg.addPath(p)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
        cg.restoreGState()
    }

    func clipped(_ path: CGPath, _ body: () -> Void) {
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        body()
        cg.restoreGState()
    }

    func label(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor = .white, font: NSFont? = nil) {
        Draw.text(s, TextStyle(font: font ?? Fonts.badge(size), color: color, shadow: 0), center: CGPoint(x: x, y: y))
    }

    // MARK: Building blocks

    /// A sheet of paper with a folded top-right corner; `inside` draws clipped to the sheet.
    func page(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, fold: CGFloat = 17, inside: () -> Void = {}) {
        let sheet = poly([(x, y), (x, y + h), (x + w - fold, y + h), (x + w, y + h - fold), (x + w, y)])
        body(sheet, Ink.paper, rim: 0)
        clipped(sheet, inside)
        outline(sheet, rim)
        let flap = poly([(x + w - fold, y + h), (x + w - fold, y + h - fold), (x + w, y + h - fold)])
        body(flap, Ink.shadowMetal)
    }

    /// Blue sky, sun and two green hills.
    func landscape(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, gray: Bool = false) {
        let frame = rr(x, y, w, h, 1.5)
        func tone(_ c: NSColor) -> NSColor {
            guard gray, let rgb = c.usingColorSpace(.sRGB) else { return c }
            let l = 0.3 * rgb.redComponent + 0.59 * rgb.greenComponent + 0.11 * rgb.blueComponent
            return NSColor(white: l, alpha: 1)
        }
        clipped(frame) {
            let g = CGGradient(colorsSpace: nil, colors: [tone(Ink.sky.0).cgColor, tone(Ink.sky.1).cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(g, start: CGPoint(x: 0, y: y + h), end: CGPoint(x: 0, y: y), options: [])
            cg.setFillColor(tone(Ink.sun).cgColor)
            cg.addPath(oval(x + w * 0.74, y + h * 0.72, h * 0.13, h * 0.13))
            cg.fillPath()
            cg.setFillColor(tone(Ink.hillBack).cgColor)
            cg.addPath(poly([(x - 2, y), (x - 2, y + h * 0.35), (x + w * 0.32, y + h * 0.66), (x + w * 0.62, y + h * 0.3), (x + w + 2, y + h * 0.2), (x + w + 2, y)]))
            cg.fillPath()
            cg.setFillColor(tone(Ink.hillFront).cgColor)
            cg.addPath(poly([(x - 2, y), (x - 2, y + h * 0.12), (x + w * 0.5, y + h * 0.4), (x + w + 2, y + h * 0.1), (x + w + 2, y)]))
            cg.fillPath()
        }
        outline(frame, 2.6)
    }

    func badge(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor, _ text: String, size: CGFloat? = nil) {
        solid(rr(x, y, w, h, 3), color, rim: 3)
        label(text, x + w / 2, y + h / 2, size: size ?? h * 0.74)
    }

    func textLines(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, rows: Int, gap: CGFloat = 8, bold first: Bool = false) {
        for i in 0..<rows {
            let width = i == rows - 1 ? w * 0.6 : w
            line([(x, y - CGFloat(i) * gap), (x + width, y - CGFloat(i) * gap)], i == 0 && first ? Ink.ink : Ink.slate.withAlphaComponent(0.8), width: i == 0 && first ? 4.2 : 3)
        }
    }

    func checker(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, cell: CGFloat = 6) {
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: x, y: y, width: w, height: h))
        cg.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor)
        var row = 0
        var cy = y
        while cy < y + h {
            var cx = x + (row % 2 == 0 ? 0 : cell)
            while cx < x + w {
                cg.fill(CGRect(x: cx, y: cy, width: cell, height: cell))
                cx += cell * 2
            }
            cy += cell
            row += 1
        }
    }

    func browser(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, inside: () -> Void) {
        let window = rr(x, y, w, h, 6)
        body(window, Ink.paper, rim: 0)
        clipped(window) {
            cg.setFillColor(Ink.shadowMetal.0.cgColor)
            cg.fill(CGRect(x: x, y: y + h - 15, width: w, height: 15))
            inside()
        }
        line([(x, y + h - 15), (x + w, y + h - 15)], width: 2.6)
        for k in 0..<3 {
            cg.setFillColor(Ink.rim.cgColor)
            cg.addPath(oval(x + 9 + CGFloat(k) * 8, y + h - 7.5, 2.6, 2.6))
            cg.fillPath()
        }
        outline(window, rim)
    }

    func globe(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        body(oval(cx, cy, r, r), (NSColor(srgbRed: 0.88, green: 0.93, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.66, green: 0.77, blue: 0.90, alpha: 1)), rim: 3)
        clipped(oval(cx, cy, r, r)) {
            for path in [oval(cx, cy, r * 0.45, r), oval(cx, cy, r, r * 0.42)] { outline(path, 2.2) }
            line([(cx - r, cy), (cx + r, cy)], width: 2.2)
            line([(cx, cy - r), (cx, cy + r)], width: 2.2)
        }
        outline(oval(cx, cy, r, r), 3)
    }

    func play(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat, color: NSColor = .white) {
        let tri = poly([(cx - s * 0.42, cy - s * 0.5), (cx - s * 0.42, cy + s * 0.5), (cx + s * 0.52, cy)])
        solid(tri, color, rim: 2.8)
    }

    /// A film strip with perforated edges left and right; returns the picture window.
    @discardableResult
    func film(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        body(rr(x, y, w, h, 5), Ink.dark)
        for side in [x + 3, x + w - 11] {
            var hy = y + 6
            while hy + 6 < y + h - 3 {
                cg.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
                cg.addPath(rr(side, hy, 8, 6, 1.5))
                cg.fillPath()
                hy += 10
            }
        }
        let window = CGRect(x: x + 15, y: y + 6, width: w - 30, height: h - 12)
        body(CGPath(roundedRect: window, cornerWidth: 3, cornerHeight: 3, transform: nil),
             (NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1), NSColor(srgbRed: 0.22, green: 0.24, blue: 0.27, alpha: 1)), rim: 2.6)
        return window
    }

    func arrow(from a: CGPoint, to b: CGPoint, shaft: CGFloat = 8, head: CGFloat = 18, color: NSColor = .white) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let neck = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        let p = poly([
            (a.x + nx * shaft / 2, a.y + ny * shaft / 2), (neck.x + nx * shaft / 2, neck.y + ny * shaft / 2),
            (neck.x + nx * head * 0.62, neck.y + ny * head * 0.62), (b.x, b.y),
            (neck.x - nx * head * 0.62, neck.y - ny * head * 0.62), (neck.x - nx * shaft / 2, neck.y - ny * shaft / 2),
            (a.x - nx * shaft / 2, a.y - ny * shaft / 2),
        ])
        solid(p, color, rim: 3)
    }

    func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, gray: Bool = false) {
        body(rr(x, y, w, h, 4), Ink.metal)
        landscape(x + 6, y + 6, w - 12, h - 12, gray: gray)
    }

    func waveBars(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, color: NSColor) {
        let heights: [CGFloat] = [0.25, 0.55, 0.85, 0.45, 1, 0.65, 0.3, 0.75, 0.4]
        let step = w / CGFloat(heights.count)
        for (i, k) in heights.enumerated() {
            let bh = h * k
            cg.setFillColor(color.cgColor)
            cg.addPath(rr(x + CGFloat(i) * step + step * 0.22, y + (h - bh) / 2, step * 0.56, bh, step * 0.28))
            cg.fillPath()
        }
    }

    // MARK: Glyphs

    func paint(_ glyph: Glyph) {
        switch glyph {
        case .png:
            page(18, 6, 62, 88) {
                checker(62, 6, 18, 74)
                line([(62, 6), (62, 78)], width: 2.4)
            }
            landscape(25, 34, 33, 30)

        case .jpg:
            frame(8, 16, 84, 68)

        case .heic:
            page(20, 6, 60, 88) { textLines(29, 76, 30, rows: 2) }
            badge(11, 26, 78, 26, Ink.blue, "HEIC")

        case .pdf:
            page(20, 6, 60, 88) { textLines(29, 76, 30, rows: 2) }
            badge(11, 26, 78, 26, Ink.red, "PDF")

        case .webp:
            browser(7, 14, 86, 72) { globe(50, 41, 20) }

        case .avif:
            page(14, 10, 60, 86) {}
            landscape(21, 40, 34, 30)
            arrow(from: CGPoint(x: 62, y: 38), to: CGPoint(x: 92, y: 6), shaft: 9, head: 20)

        case .gif:
            let w = film(6, 18, 88, 64)
            play(w.midX + 2, w.midY, 26)

        case .tiff:
            body(rr(27, 52, 46, 40, 2), Ink.paper)
            textLines(34, 82, 32, rows: 2, gap: 8)
            body(rr(8, 26, 84, 38, 8), Ink.metal)
            line([(22, 56), (78, 56)], width: 3)
            cg.setFillColor(NSColor(srgbRed: 0.35, green: 0.85, blue: 0.40, alpha: 1).cgColor)
            cg.addPath(oval(80, 40, 3.6, 3.6))
            cg.fillPath()
            outline(oval(80, 40, 3.6, 3.6), 1.8)
            body(rr(20, 8, 60, 22, 2), Ink.paper)
            textLines(28, 22, 44, rows: 2, gap: 7)

        case .longImage:
            body(rr(30, 2, 40, 96, 3), Ink.paper)
            for (k, y) in [CGFloat(68), 37, 6].enumerated() {
                landscape(35, y + 2, 30, 24, gray: k == 1 && false)
            }

        case .word(let text):
            page(20, 6, 60, 88) { textLines(29, 78, 34, rows: 3) }
            badge(11, 22, 78, 26, Ink.word, text, size: text.count > 3 ? 18 : 20)

        case .text:
            page(20, 6, 60, 88) { textLines(29, 76, 36, rows: 7, gap: 8.5) }

        case .markdown:
            page(20, 6, 60, 88) {}
            solid(rr(24, 28, 52, 34, 5), Ink.ink, rim: 3)
            label("M↓", 50, 45, size: 24)

        case .rtf:
            page(20, 6, 60, 88) { textLines(29, 78, 34, rows: 3, bold: true) }
            badge(11, 22, 78, 26, Ink.purple, "RTF")

        case .html:
            browser(7, 14, 86, 72) {
                label("</>", 50, 41, size: 34, color: Ink.orange)
            }

        case .odt:
            page(20, 6, 60, 88) { textLines(29, 78, 34, rows: 3) }
            badge(11, 22, 78, 26, Ink.teal, "ODT")

        case .clapper:
            body(rr(10, 10, 80, 54, 5), Ink.dark)
            play(52, 37, 24)
            cg.saveGState()
            cg.translateBy(x: 10, y: 66)
            cg.rotate(by: 0.18)
            let stick = rr(0, 0, 80, 16, 3)
            body(stick, Ink.dark, rim: 0)
            clipped(stick) {
                cg.setFillColor(NSColor.white.cgColor)
                for k in 0..<5 {
                    let sx = CGFloat(k) * 18 + 4
                    cg.addPath(poly([(sx, 0), (sx + 9, 0), (sx + 17, 16), (sx + 8, 16)]))
                    cg.fillPath()
                }
            }
            outline(stick, rim)
            cg.restoreGState()
            body(rr(8, 62, 84, 6, 2), Ink.dark)

        case .film:
            let w = film(6, 18, 88, 64)
            play(w.midX + 2, w.midY, 26)

        case .filmBadge(let text):
            film(6, 24, 88, 62)
            badge(22, 8, 56, 24, Ink.green, text, size: 17)

        case .webVideo:
            browser(7, 14, 86, 72) {
                solid(rr(30, 26, 40, 28, 8), Ink.red, rim: 3)
                play(51, 40, 16)
            }

        case .loop:
            body(rr(8, 14, 84, 70, 6), Ink.metal)
            body(rr(15, 21, 70, 56, 3), Ink.dark, rim: 2.6)
            let arc = CGMutablePath()
            arc.addArc(center: CGPoint(x: 50, y: 49), radius: 18, startAngle: 0.5, endAngle: 0.5 + .pi * 1.55, clockwise: false)
            cg.saveGState()
            cg.addPath(arc.copy(strokingWithWidth: 7, lineCap: .butt, lineJoin: .round, miterLimit: 1))
            cg.setFillColor(NSColor.white.cgColor)
            cg.fillPath()
            cg.restoreGState()
            outline(arc.copy(strokingWithWidth: 7, lineCap: .butt, lineJoin: .round, miterLimit: 1), 2.2)
            arrow(from: CGPoint(x: 66, y: 60), to: CGPoint(x: 62, y: 72), shaft: 0.1, head: 14)
            label("GIF", 50, 49, size: 14)

        case .note(let text, let color):
            page(20, 10, 60, 84) {}
            label("♫", 48, 62, size: 46, color: Ink.ink, font: NSFont.systemFont(ofSize: 46, weight: .bold))
            badge(11, 16, 78, 26, color, text)

        case .waves:
            body(rr(6, 22, 88, 56, 8), Ink.dark)
            waveBars(14, 30, 72, 40, color: NSColor(srgbRed: 0.55, green: 0.80, blue: 1, alpha: 1))

        case .wavesBadge(let text, let color):
            body(rr(6, 30, 88, 56, 8), Ink.dark)
            waveBars(14, 38, 72, 40, color: NSColor(srgbRed: 0.55, green: 0.80, blue: 1, alpha: 1))
            badge(24, 6, 52, 24, color, text, size: 17)

        case .voice:
            let bubble = CGMutablePath()
            bubble.move(to: CGPoint(x: 22, y: 26))
            bubble.addLine(to: CGPoint(x: 13, y: 8))
            bubble.addLine(to: CGPoint(x: 40, y: 26))
            bubble.addLine(to: CGPoint(x: 80, y: 26))
            bubble.addArc(tangent1End: CGPoint(x: 94, y: 26), tangent2End: CGPoint(x: 94, y: 40), radius: 14)
            bubble.addLine(to: CGPoint(x: 94, y: 72))
            bubble.addArc(tangent1End: CGPoint(x: 94, y: 86), tangent2End: CGPoint(x: 80, y: 86), radius: 14)
            bubble.addLine(to: CGPoint(x: 20, y: 86))
            bubble.addArc(tangent1End: CGPoint(x: 6, y: 86), tangent2End: CGPoint(x: 6, y: 72), radius: 14)
            bubble.addLine(to: CGPoint(x: 6, y: 40))
            bubble.addArc(tangent1End: CGPoint(x: 6, y: 26), tangent2End: CGPoint(x: 22, y: 26), radius: 14)
            bubble.closeSubpath()
            body(bubble, Ink.paper)
            waveBars(16, 36, 68, 40, color: Ink.teal)

        case .vinyl:
            body(oval(50, 50, 44, 44), Ink.dark)
            for r: CGFloat in [36, 29, 22] { outline(oval(50, 50, r, r), 1.2) }
            cg.saveGState()
            cg.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
            cg.setLineWidth(3)
            cg.addArc(center: CGPoint(x: 50, y: 50), radius: 32, startAngle: 2.2, endAngle: 2.9, clockwise: false)
            cg.strokePath()
            cg.restoreGState()
            solid(oval(50, 50, 14, 14), Ink.gold, rim: 2.6)
            body(oval(50, 50, 3.5, 3.5), Ink.dark, rim: 1.6)

        case .bell:
            let bell = CGMutablePath()
            bell.move(to: CGPoint(x: 16, y: 26))
            bell.addLine(to: CGPoint(x: 84, y: 26))
            bell.addCurve(to: CGPoint(x: 70, y: 52), control1: CGPoint(x: 76, y: 32), control2: CGPoint(x: 72, y: 40))
            bell.addCurve(to: CGPoint(x: 30, y: 52), control1: CGPoint(x: 68, y: 92), control2: CGPoint(x: 32, y: 92))
            bell.addCurve(to: CGPoint(x: 16, y: 26), control1: CGPoint(x: 28, y: 40), control2: CGPoint(x: 24, y: 32))
            bell.closeSubpath()
            body(oval(50, 18, 9, 9), Ink.metal)
            body(bell, (NSColor(srgbRed: 1, green: 0.88, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.88, green: 0.62, blue: 0.12, alpha: 1)))
            body(rr(46, 84, 8, 8, 3), Ink.metal, rim: 2.4)
            for (a0, a1) in [(CGFloat.pi * 0.83, CGFloat.pi * 1.07), (-CGFloat.pi * 0.07, CGFloat.pi * 0.17)] {
                let wave = CGMutablePath()
                wave.addArc(center: CGPoint(x: 50, y: 56), radius: 44, startAngle: a0, endAngle: a1, clockwise: false)
                cg.addPath(wave)
                cg.setStrokeColor(Ink.rim.cgColor)
                cg.setLineWidth(4)
                cg.setLineCap(.round)
                cg.strokePath()
            }

        case .compress:
            page(32, 12, 36, 76, fold: 12) { textLines(38, 74, 22, rows: 6, gap: 9) }
            arrow(from: CGPoint(x: 2, y: 50), to: CGPoint(x: 30, y: 50), shaft: 9, head: 18)
            arrow(from: CGPoint(x: 98, y: 50), to: CGPoint(x: 70, y: 50), shaft: 9, head: 18)

        case .shrink:
            frame(4, 30, 64, 52)
            body(oval(70, 38, 17, 17), (NSColor(srgbRed: 0.90, green: 0.95, blue: 1, alpha: 0.95), NSColor(srgbRed: 0.68, green: 0.80, blue: 0.92, alpha: 0.95)))
            line([(62, 38), (78, 38)], width: 5)
            body(poly([(80, 25), (84, 21), (97, 8), (93, 4), (80, 17), (76, 21)]), Ink.dark)

        case .cutout:
            let card = rr(8, 8, 84, 84, 6)
            clipped(card) { checker(8, 8, 84, 84, cell: 8) }
            outline(card, rim)
            let person = CGMutablePath()
            person.addPath(oval(50, 60, 15, 16))
            body(oval(50, 60, 15, 16), (NSColor(srgbRed: 1, green: 0.86, blue: 0.72, alpha: 1), NSColor(srgbRed: 0.93, green: 0.70, blue: 0.55, alpha: 1)))
            let torso = CGMutablePath()
            torso.move(to: CGPoint(x: 18, y: 8))
            torso.addCurve(to: CGPoint(x: 82, y: 8), control1: CGPoint(x: 20, y: 52), control2: CGPoint(x: 80, y: 52))
            torso.closeSubpath()
            body(torso, (NSColor(srgbRed: 0.35, green: 0.55, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.18, green: 0.32, blue: 0.70, alpha: 1)))
            let dash = CGMutablePath()
            dash.addPath(oval(50, 60, 21, 22))
            cg.saveGState()
            cg.addPath(dash)
            cg.setLineDash(phase: 0, lengths: [5, 4])
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(2.6)
            cg.strokePath()
            cg.restoreGState()

        case .scan:
            page(24, 10, 52, 80, fold: 14) {}
            label("T", 50, 48, size: 46, color: Ink.ink, font: NSFont(name: "Georgia-Bold", size: 46))
            for (cx, cy, sx, sy): (CGFloat, CGFloat, CGFloat, CGFloat) in [(10, 92, 1, -1), (90, 92, -1, -1), (10, 8, 1, 1), (90, 8, -1, 1)] {
                line([(cx, cy + sy * 16), (cx, cy), (cx + sx * 16, cy)], Ink.blue, width: 6)
            }

        case .mono:
            body(rr(8, 16, 84, 68, 4), Ink.metal)
            landscape(14, 22, 72, 56)
            clipped(rr(14, 22, 36, 56)) { landscape(14, 22, 72, 56, gray: true) }
            line([(50, 22), (50, 78)], width: 2.6)

        case .rotate:
            cg.saveGState()
            cg.translateBy(x: 46, y: 46)
            cg.rotate(by: -0.26)
            frame(-34, -26, 68, 54)
            cg.restoreGState()
            let arc = CGMutablePath()
            arc.addArc(center: CGPoint(x: 50, y: 50), radius: 44, startAngle: 1.75, endAngle: 0.55, clockwise: true)
            let band = arc.copy(strokingWithWidth: 7, lineCap: .butt, lineJoin: .round, miterLimit: 1)
            solid(band, NSColor.white, rim: 2.6)
            arrow(from: CGPoint(x: 84, y: 76), to: CGPoint(x: 92, y: 62), shaft: 0.1, head: 15)

        case .unpin:
            let pin = CGMutablePath()
            pin.move(to: CGPoint(x: 50, y: 4))
            pin.addCurve(to: CGPoint(x: 22, y: 62), control1: CGPoint(x: 38, y: 24), control2: CGPoint(x: 22, y: 40))
            pin.addArc(center: CGPoint(x: 50, y: 62), radius: 28, startAngle: .pi, endAngle: 0, clockwise: true)
            pin.addCurve(to: CGPoint(x: 50, y: 4), control1: CGPoint(x: 78, y: 40), control2: CGPoint(x: 62, y: 24))
            pin.closeSubpath()
            solid(pin, Ink.red)
            body(oval(50, 62, 11, 11), Ink.paper, rim: 2.8)
            let slash = poly([(10, 14), (16, 8), (92, 84), (86, 90)])
            solid(slash, .white, rim: 3)

        case .backdrop:
            let card = rr(4, 4, 92, 92, 14)
            cg.saveGState()
            cg.addPath(card)
            cg.clip()
            let g = CGGradient(colorsSpace: nil, colors: [NSColor(srgbRed: 0.98, green: 0.36, blue: 0.52, alpha: 1).cgColor,
                                                          NSColor(srgbRed: 1, green: 0.62, blue: 0.36, alpha: 1).cgColor,
                                                          NSColor(srgbRed: 1, green: 0.82, blue: 0.42, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
            cg.drawLinearGradient(g, start: CGPoint(x: 4, y: 96), end: CGPoint(x: 96, y: 4), options: [])
            cg.restoreGState()
            outline(card, rim)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: NSColor(white: 0, alpha: 0.35).cgColor)
            body(rr(18, 22, 64, 54, 6), Ink.paper, rim: 2.6)
            cg.restoreGState()
            landscape(23, 27, 54, 44)

        case .split:
            page(22, 6, 56, 88) { textLines(30, 80, 32, rows: 3) }
            cg.saveGState()
            cg.setLineDash(phase: 0, lengths: [7, 5])
            line([(30, 46), (94, 46)], Ink.red, width: 4)
            cg.restoreGState()
            if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 30, weight: .heavy)) {
                let tinted = Symbols.tinted(scissors, Ink.ink)
                tinted.draw(in: CGRect(x: 0, y: 32, width: 30, height: 28))
            }

        case .merge:
            page(36, 22, 50, 72, fold: 14) { textLines(43, 80, 30, rows: 3) }
            page(14, 6, 50, 72, fold: 14) { textLines(21, 64, 30, rows: 4) }
            solid(oval(74, 22, 16, 16), Ink.green, rim: 3)
            label("+", 74, 23, size: 30)

        case .mute:
            let speaker = poly([(10, 36), (30, 36), (52, 16), (52, 84), (30, 64), (10, 64)])
            body(speaker, Ink.metal)
            line([(62, 34), (90, 66)], Ink.red, width: 8)
            line([(90, 34), (62, 66)], Ink.red, width: 8)

        case .screen720:
            body(rr(30, 6, 40, 10, 3), Ink.metal, rim: 3)
            body(rr(44, 14, 12, 12), Ink.shadowMetal, rim: 2.6)
            body(rr(4, 24, 92, 64, 6), Ink.dark)
            label("720P", 50, 56, size: 30)

        case .cover:
            film(4, 36, 62, 58)
            cg.saveGState()
            cg.translateBy(x: 0, y: 0)
            frame(34, 6, 62, 50)
            cg.restoreGState()

        case .fast:
            let a = poly([(8, 16), (52, 50), (8, 84)]), b = poly([(48, 16), (92, 50), (48, 84)])
            solid(a, Ink.gold)
            solid(b, Ink.gold)

        case .slow:
            body(rr(20, 86, 60, 8, 3), Ink.dark)
            body(rr(20, 6, 60, 8, 3), Ink.dark)
            let glass = poly([(26, 86), (74, 86), (54, 50), (74, 14), (26, 14), (46, 50)])
            body(glass, (NSColor(srgbRed: 0.92, green: 0.96, blue: 1, alpha: 1), NSColor(srgbRed: 0.75, green: 0.84, blue: 0.94, alpha: 1)))
            solid(poly([(36, 76), (64, 76), (50, 56)]), Ink.gold, rim: 0)
            solid(poly([(32, 18), (68, 18), (50, 36)]), Ink.gold, rim: 0)
            outline(glass, rim)

        case .speaker:
            let speaker = poly([(8, 36), (28, 36), (50, 16), (50, 84), (28, 64), (8, 64)])
            body(speaker, Ink.metal)
            let wave = CGMutablePath()
            wave.addArc(center: CGPoint(x: 52, y: 50), radius: 22, startAngle: -0.8, endAngle: 0.8, clockwise: false)
            cg.addPath(wave)
            cg.setStrokeColor(Ink.rim.cgColor)
            cg.setLineWidth(6)
            cg.setLineCap(.round)
            cg.strokePath()
            label("1", 84, 50, size: 30, color: .white)

        case .meter:
            body(rr(6, 8, 88, 84, 8), Ink.dark)
            let colors = [Ink.green, Ink.green, Ink.gold, Ink.orange, Ink.red]
            for i in 0..<5 {
                let h = CGFloat(14 + i * 13)
                solid(rr(16 + CGFloat(i) * 15, 16, 10, h, 2), colors[i], rim: 2)
            }
            line([(14, 72), (86, 72)], NSColor(white: 1, alpha: 0.8), width: 2.4)

        case .counter:
            body(rr(6, 18, 88, 64, 8), Ink.paper)
            label("123", 50, 50, size: 42, color: Ink.ink)

        case .clipboard:
            body(rr(16, 4, 68, 86, 6), (NSColor(srgbRed: 0.85, green: 0.66, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.66, green: 0.46, blue: 0.26, alpha: 1)))
            body(rr(24, 10, 52, 68, 2), Ink.paper, rim: 2.6)
            textLines(31, 66, 38, rows: 5, gap: 10)
            body(rr(36, 80, 28, 14, 4), Ink.metal, rim: 3)

        case .zip:
            let folder = CGMutablePath()
            folder.addPath(poly([(6, 12), (6, 82), (36, 82), (44, 74), (94, 74), (94, 12)]))
            body(folder, (NSColor(srgbRed: 1, green: 0.86, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.90, green: 0.66, blue: 0.20, alpha: 1)))
            for k in 0..<7 {
                let y = 66 - CGFloat(k) * 8
                body(rr(k % 2 == 0 ? 44 : 50, y, 6, 5, 1), Ink.dark, rim: 1.4)
            }
            body(rr(42, 14, 16, 12, 3), Ink.metal, rim: 2.6)

        case .link:
            for (cx, cy) in [(CGFloat(36), CGFloat(36)), (64, 64)] {
                cg.saveGState()
                cg.translateBy(x: cx, y: cy)
                cg.rotate(by: .pi / 4)
                let ring = rr(-26, -12, 52, 24, 12).copy(strokingWithWidth: 9, lineCap: .round, lineJoin: .round, miterLimit: 1)
                body(ring, Ink.metal, rim: 2.6)
                cg.restoreGState()
            }

        case .tag:
            let tag = poly([(6, 34), (30, 10), (94, 10), (94, 58), (30, 58)])
            body(tag, Ink.paper)
            outline(oval(24, 34, 5, 5), 3)
            label("Aa", 62, 34, size: 32, color: Ink.ink)

        case .fingerprint:
            let shield = CGMutablePath()
            shield.move(to: CGPoint(x: 50, y: 96))
            shield.addCurve(to: CGPoint(x: 12, y: 80), control1: CGPoint(x: 36, y: 88), control2: CGPoint(x: 24, y: 84))
            shield.addCurve(to: CGPoint(x: 50, y: 4), control1: CGPoint(x: 10, y: 40), control2: CGPoint(x: 24, y: 18))
            shield.addCurve(to: CGPoint(x: 88, y: 80), control1: CGPoint(x: 76, y: 18), control2: CGPoint(x: 90, y: 40))
            shield.addCurve(to: CGPoint(x: 50, y: 96), control1: CGPoint(x: 76, y: 84), control2: CGPoint(x: 64, y: 88))
            shield.closeSubpath()
            body(shield, Ink.metal)
            label("#", 50, 50, size: 52, color: Ink.blue)
        }
    }
}
