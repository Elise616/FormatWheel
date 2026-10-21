import AppKit

/// Each wheel slot shows a weapon silhouette, like GTA's weapon wheel, and plays its handling
/// sound when the action succeeds. Shapes are side profiles, muzzle to the right, in loose units.
enum Weapon: String, CaseIterable {
    case pistol, silencedPistol, microSMG, smg, rifle, sniper, shotgun, rpg, minigun
    case grenade, stickyBomb, molotov, knife, bat, wrench, flashlight, sprayCan, knuckles, jerryCan

    var title: String {
        switch self {
        case .pistol: return "手枪"
        case .silencedPistol: return "消音手枪"
        case .microSMG: return "微型冲锋枪"
        case .smg: return "冲锋枪"
        case .rifle: return "突击步枪"
        case .sniper: return "狙击步枪"
        case .shotgun: return "泵动霰弹枪"
        case .rpg: return "火箭筒"
        case .minigun: return "加特林"
        case .grenade: return "手雷"
        case .stickyBomb: return "粘弹"
        case .molotov: return "燃烧瓶"
        case .knife: return "匕首"
        case .bat: return "球棒"
        case .wrench: return "扳手"
        case .flashlight: return "手电筒"
        case .sprayCan: return "喷漆罐"
        case .knuckles: return "指虎"
        case .jerryCan: return "汽油桶"
        }
    }

    var sound: SFX.Kind {
        switch self {
        case .pistol, .silencedPistol, .microSMG, .smg: return .rackPistol
        case .rifle: return .rackRifle
        case .sniper: return .rackBolt
        case .shotgun: return .rackPump
        case .rpg, .minigun, .jerryCan: return .rackHeavy
        case .grenade, .stickyBomb, .molotov: return .pinPull
        case .knife: return .bladeDraw
        case .bat, .wrench, .flashlight, .sprayCan, .knuckles: return .meleeSwing
        }
    }

    /// Which weapon a wheel option wears. Formats get guns, tools get gear that fits the job.
    static func of(_ id: String) -> Weapon {
        if let hit = table[id] { return hit }
        if id.hasSuffix(".strip") { return .silencedPistol }
        if id.hasSuffix(".compress") { return .grenade }
        return .pistol
    }

    private static let table: [String: Weapon] = [
        "img.to.png": .rifle, "img.to.jpg": .pistol, "img.to.heic": .microSMG, "img.to.webp": .smg,
        "img.to.pdf": .rpg, "img.to.avif": .sniper, "img.to.gif": .shotgun, "img.to.tiff": .minigun,
        "img.half": .knuckles, "img.cutout": .knife, "img.ocr": .flashlight, "img.mono": .bat,
        "img.rotate": .wrench, "img.backdrop": .sprayCan,
        "pdf.to.png": .rifle, "pdf.to.jpg": .pistol, "pdf.to.long": .sniper, "pdf.to.docx": .shotgun,
        "pdf.to.txt": .knuckles, "pdf.to.md": .smg, "pdf.to.rtf": .microSMG, "pdf.to.html": .rpg,
        "pdf.split": .knife, "pdf.merge": .stickyBomb, "pdf.rotate": .wrench, "pdf.mono": .bat, "pdf.ocr": .flashlight,
        "vid.to.mp4": .rifle, "vid.to.mov": .pistol, "vid.to.hevc": .sniper, "vid.to.webm": .smg,
        "vid.to.gif": .shotgun, "vid.to.mp3": .microSMG, "vid.to.m4a": .molotov, "vid.to.wav": .minigun,
        "vid.mute": .silencedPistol, "vid.720p": .wrench, "vid.cover": .flashlight, "vid.fast": .smg,
        "vid.slow": .sniper, "vid.strip": .molotov,
        "aud.to.mp3": .pistol, "aud.to.m4a": .microSMG, "aud.to.wav": .minigun, "aud.to.flac": .rifle,
        "aud.to.aiff": .shotgun, "aud.to.opus": .sniper, "aud.to.alac": .smg, "aud.to.m4r": .stickyBomb,
        "aud.mono": .knife, "aud.loud": .bat, "aud.fast": .smg,
        "doc.to.pdf": .rpg, "doc.to.docx": .rifle, "doc.to.txt": .knuckles, "doc.to.md": .smg,
        "doc.to.html": .molotov, "doc.to.rtf": .microSMG, "doc.to.odt": .shotgun, "doc.to.doc": .pistol,
        "doc.count": .flashlight, "doc.copy": .knife,
        "gen.zip": .jerryCan, "gen.path": .knuckles, "gen.name": .knife, "gen.sha": .wrench,
    ]

    // MARK: - Drawing

    private static var cache: [Weapon: (shapes: [CGPath], detail: CGPath)] = [:]

    private var art: (shapes: [CGPath], detail: CGPath) {
        if let hit = Weapon.cache[self] { return hit }
        let pen = Pen()
        Weapon.sketch(self, pen)
        let result = (pen.shapes, pen.detail as CGPath)
        Weapon.cache[self] = result
        return result
    }

    /// Draws the silhouette fitted into `rect`: dark rim, white body with a soft top light, panel lines.
    func draw(in rect: CGRect, rim: CGFloat, alpha: CGFloat = 1) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let (pieces, detail) = art
        let box = pieces.reduce(detail.boundingBoxOfPath) { $0.union($1.boundingBoxOfPath) }
        let k = min(rect.width / box.width, rect.height / box.height)
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: k, y: k)
            .translatedBy(x: -box.midX, y: -box.midY)
        let shapes = pieces.compactMap { $0.copy(using: &t) }
        guard let lines = detail.copy(using: &t) else { return }
        let bounds = shapes.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }

        cg.saveGState()
        cg.setAlpha(alpha)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)

        // Rim: every piece stroked dark; the body painted next covers the strokes inside the union.
        cg.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 5, color: NSColor(white: 0, alpha: 0.55).cgColor)
        cg.setStrokeColor(NSColor(white: 0.04, alpha: 0.92).cgColor)
        cg.setLineWidth(rim * 2)
        cg.setLineJoin(.round)
        cg.setLineCap(.round)
        for shape in shapes {
            cg.addPath(shape)
            cg.strokePath()
        }
        cg.setShadow(offset: .zero, blur: 0, color: nil)

        // Body: each piece filled on its own, so overlapping pieces never cancel into holes.
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.setFillColor(NSColor.white.cgColor)
        for shape in shapes {
            cg.addPath(shape)
            cg.fillPath()
        }
        cg.setBlendMode(.sourceAtop)
        let shade = CGGradient(colorsSpace: nil, colors: [
            NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor, NSColor(white: 0.72, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 0.45, 1])!
        cg.drawLinearGradient(shade, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: bounds.minY), options: [])
        cg.addPath(lines)
        cg.setStrokeColor(NSColor(white: 0.16, alpha: 0.8).cgColor)
        cg.setLineWidth(max(0.8, rim * 0.55))
        cg.strokePath()
        cg.endTransparencyLayer()

        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    // MARK: - Shapes

    private final class Pen {
        var shapes: [CGPath] = []
        let detail = CGMutablePath()

        func add(_ path: CGPath) { shapes.append(path) }

        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) {
            let box = CGRect(x: x, y: y, width: w, height: h)
            add(r > 0 ? CGPath(roundedRect: box, cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
                      : CGPath(rect: box, transform: nil))
        }

        func poly(_ points: [(CGFloat, CGFloat)]) {
            let p = CGMutablePath()
            p.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
            p.closeSubpath()
            add(p)
        }

        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            add(CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil))
        }

        func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
            add(CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), transform: nil))
        }

        /// A ring (the stroke outline keeps its hole when filled).
        func ring(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, width: CGFloat) {
            let circle = CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil)
            add(circle.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }

        /// A thick stroked arc, e.g. a trigger guard. Angles in degrees, counter-clockwise from +x.
        func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, from a0: CGFloat, to a1: CGFloat, width: CGFloat) {
            let p = CGMutablePath()
            p.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
            add(p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }

        func bar(_ points: [(CGFloat, CGFloat)], width: CGFloat) {
            let p = CGMutablePath()
            p.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
            add(p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }

        func line(_ points: [(CGFloat, CGFloat)]) {
            detail.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        }

        func ticks(from x0: CGFloat, to x1: CGFloat, step: CGFloat, y0: CGFloat, y1: CGFloat) {
            var x = x0
            while x <= x1 {
                line([(x, y0), (x, y1)])
                x += step
            }
        }
    }

    private static func sketch(_ weapon: Weapon, _ p: Pen) {
        switch weapon {
        case .pistol, .silencedPistol:
            p.rect(18, 30, 82, 13, r: 2)
            p.rect(20, 22, 74, 9, r: 2)
            p.poly([(22, 25), (42, 25), (35, 2), (17, 0), (12, 4)])
            p.arc(50, 22, 7, from: 180, to: 360, width: 3)
            p.rect(98, 33, 7, 7, r: 1)
            p.line([(20, 30.5), (96, 30.5)])
            p.ticks(from: 24, to: 34, step: 3.4, y0: 33, y1: 41)
            p.line([(19, 14), (34, 16)])
            if weapon == .silencedPistol {
                p.rect(104, 31, 46, 11, r: 4)
                p.ticks(from: 116, to: 140, step: 8, y0: 32.5, y1: 40.5)
            }

        case .microSMG:
            p.rect(14, 26, 70, 16, r: 3)
            p.rect(84, 31, 18, 6, r: 1)
            p.poly([(42, 27), (56, 27), (54, 0), (44, 0)])
            p.arc(64, 23, 6, from: 180, to: 360, width: 3)
            p.rect(0, 31, 16, 4)
            p.rect(0, 28, 4, 12, r: 1.5)
            p.circle(30, 44, 3)
            p.line([(16, 34), (82, 34)])
            p.ticks(from: 46, to: 52, step: 3, y0: 4, y1: 22)

        case .smg:
            p.rect(26, 26, 72, 15, r: 3)
            p.rect(98, 30, 20, 8, r: 2)
            p.rect(116, 32, 8, 4)
            p.poly([(66, 27), (77, 27), (74, 2), (62, 5)])
            p.poly([(37, 27), (48, 27), (44, 6), (33, 7)])
            p.arc(55, 23, 5, from: 180, to: 360, width: 2.6)
            p.rect(0, 27, 27, 5)
            p.rect(0, 35, 27, 4)
            p.rect(0, 27, 5, 12, r: 1.5)
            p.ticks(from: 101, to: 113, step: 4, y0: 31, y1: 37)
            p.line([(28, 33.5), (96, 33.5)])

        case .rifle:
            p.poly([(0, 20), (28, 25), (28, 40), (4, 40), (0, 35)])
            p.rect(28, 24, 58, 16, r: 2)
            p.rect(38, 40, 36, 4, r: 1)
            p.poly([(58, 25), (69, 25), (70, 4), (59, 1)])
            p.poly([(35, 25), (46, 25), (42, 6), (31, 8)])
            p.rect(86, 26, 36, 12, r: 3)
            p.rect(122, 30.5, 24, 4)
            p.rect(141, 29, 7, 7, r: 1)
            p.rect(112, 38, 4, 8)
            p.arc(50, 21, 5, from: 180, to: 360, width: 2.6)
            p.ticks(from: 90, to: 118, step: 5.5, y0: 28.5, y1: 35.5)
            p.line([(30, 32), (84, 32)])
            p.ticks(from: 41, to: 71, step: 5, y0: 40.5, y1: 43.5)

        case .sniper:
            p.poly([(0, 14), (32, 22), (32, 36), (10, 38), (0, 34)])
            p.rect(32, 24, 44, 12, r: 2)
            p.rect(76, 28, 96, 5)
            p.rect(168, 26.5, 9, 8, r: 1)
            p.rect(40, 42, 42, 7, r: 3)
            p.poly([(31, 40), (40, 42), (40, 49), (31, 51)])
            p.poly([(82, 42), (93, 39.5), (93, 51.5), (82, 49)])
            p.rect(50, 36, 4, 7)
            p.rect(68, 36, 4, 7)
            p.poly([(36, 24), (46, 24), (42, 8), (32, 10)])
            p.rect(52, 18, 8, 7)
            p.bar([(140, 28), (131, 5)], width: 3)
            p.bar([(140, 28), (149, 5)], width: 3)
            p.bar([(64, 24), (67, 19)], width: 2.4)
            p.circle(67.5, 18.5, 3)
            p.line([(34, 30), (74, 30)])
            p.line([(10, 30), (24, 28)])

        case .shotgun:
            p.poly([(0, 14), (34, 22), (34, 36), (6, 36), (0, 32)])
            p.rect(34, 22, 34, 14, r: 2)
            p.rect(68, 30, 92, 5.5)
            p.rect(68, 23, 78, 6, r: 2)
            p.rect(92, 19, 30, 13, r: 4)
            p.poly([(40, 23), (50, 23), (46, 6), (36, 8)])
            p.arc(57, 19, 5, from: 180, to: 360, width: 2.6)
            p.ticks(from: 96, to: 118, step: 4, y0: 21, y1: 30)
            p.line([(36, 29), (66, 29)])

        case .rpg:
            p.rect(8, 22, 120, 13, r: 5)
            p.poly([(0, 19), (11, 22), (11, 35), (0, 38)])
            p.poly([(126, 24), (140, 13), (168, 28.5), (140, 44), (126, 33)])
            p.poly([(55, 23), (64, 23), (62, 0), (53, 0)])
            p.poly([(84, 23), (92, 23), (90, 6), (82, 6)])
            p.rect(66, 34, 10, 9, r: 1)
            p.line([(30, 22.5), (30, 34.5)])
            p.line([(110, 22.5), (110, 34.5)])
            p.line([(140, 16), (140, 41)])

        case .minigun:
            p.rect(14, 12, 46, 34, r: 9)
            p.rect(60, 17, 92, 5)
            p.rect(60, 26.5, 92, 5)
            p.rect(60, 36, 92, 5)
            p.rect(62, 14, 7, 30, r: 2)
            p.rect(104, 14, 6, 30, r: 2)
            p.rect(146, 14, 7, 30, r: 2)
            p.rect(0, 24, 15, 10, r: 3)
            p.arc(37, 45, 12, from: 0, to: 180, width: 5)
            p.line([(22, 20), (52, 20)])
            p.line([(22, 38), (52, 38)])

        case .grenade:
            p.ellipse(40, 24, 18, 22)
            p.rect(33, 44, 14, 8, r: 2)
            p.poly([(46, 49), (61, 47), (60, 18), (56, 18), (55, 43), (46, 45)])
            p.ring(27, 55, 6.5, width: 3)
            p.line([(25, 14), (55, 14)])
            p.line([(22.5, 24), (57.5, 24)])
            p.line([(25, 34), (55, 34)])
            p.line([(32, 4), (32, 44)])
            p.line([(48, 4), (48, 44)])

        case .stickyBomb:
            p.rect(6, 6, 96, 32, r: 6)
            p.rect(36, 37, 32, 9, r: 2)
            p.bar([(62, 45), (78, 64)], width: 2.6)
            p.circle(79, 65, 3)
            p.line([(26, 6), (26, 38)])
            p.line([(82, 6), (82, 38)])
            p.line([(40, 41.5), (52, 41.5)])

        case .molotov:
            p.rect(18, 0, 46, 44, r: 12)
            p.poly([(22, 42), (60, 42), (50, 56), (32, 56)])
            p.rect(35, 54, 12, 16, r: 2)
            p.rect(33, 68, 16, 6, r: 2)
            let flame = CGMutablePath()
            flame.move(to: CGPoint(x: 30, y: 74))
            flame.addCurve(to: CGPoint(x: 40, y: 108), control1: CGPoint(x: 22, y: 86), control2: CGPoint(x: 30, y: 98))
            flame.addCurve(to: CGPoint(x: 46, y: 92), control1: CGPoint(x: 42, y: 102), control2: CGPoint(x: 44, y: 96))
            flame.addCurve(to: CGPoint(x: 52, y: 100), control1: CGPoint(x: 48, y: 95), control2: CGPoint(x: 51, y: 97))
            flame.addCurve(to: CGPoint(x: 52, y: 74), control1: CGPoint(x: 60, y: 90), control2: CGPoint(x: 58, y: 80))
            flame.closeSubpath()
            p.add(flame)
            p.line([(20, 24), (62, 24)])
            p.line([(40, 78), (42, 94)])

        case .knife:
            p.rect(0, 20, 34, 13, r: 5)
            p.rect(34, 12, 6, 29, r: 2)
            p.poly([(40, 20), (110, 22), (132, 30), (112, 35.5), (40, 35.5)])
            p.line([(44, 26), (112, 27)])
            p.ticks(from: 7, to: 27, step: 6.5, y0: 22, y1: 31)

        case .bat:
            p.poly([(5, 22.5), (118, 17), (128, 21), (131, 27.5), (128, 34), (118, 38), (5, 30.5)])
            p.circle(4, 26.5, 6)
            p.line([(22, 22), (22, 31)])
            p.line([(30, 21.6), (30, 31.4)])

        case .wrench:
            p.rect(22, 21, 88, 10, r: 4)
            p.poly([(104, 16), (124, 9), (138, 17), (122, 22), (122, 30), (138, 35), (124, 43), (104, 36)])
            p.ring(14, 26, 9, width: 6)
            p.line([(36, 26), (96, 26)])

        case .flashlight:
            p.rect(0, 18, 86, 15, r: 6)
            p.poly([(86, 16), (110, 10), (110, 41), (86, 35)])
            p.rect(109, 9, 6, 33, r: 2)
            p.rect(40, 32, 12, 5, r: 2)
            p.ticks(from: 8, to: 30, step: 5.5, y0: 20, y1: 31)

        case .sprayCan:
            p.rect(30, 0, 34, 48, r: 6)
            p.rect(34, 47, 26, 9, r: 3)
            p.rect(41, 55, 12, 6, r: 2)
            p.rect(52, 57, 9, 3)
            p.circle(69, 60, 2.2)
            p.circle(76, 63, 1.7)
            p.circle(81, 57.5, 1.9)
            p.circle(87, 62, 1.3)
            p.circle(74, 54.5, 1.5)
            p.line([(30, 14), (64, 14)])
            p.line([(30, 34), (64, 34)])

        case .knuckles:
            for x: CGFloat in [18, 38, 58, 78] { p.ring(x, 31, 8.5, width: 5) }
            p.rect(8, 4, 82, 16, r: 8)
            p.line([(16, 12), (82, 12)])

        case .jerryCan:
            p.rect(6, 0, 70, 60, r: 6)
            p.rect(12, 59, 34, 10, r: 3)
            p.poly([(55, 59), (64, 59), (73, 73), (66, 76)])
            p.line([(12, 6), (70, 54)])
            p.line([(12, 54), (70, 6)])
        }
    }
}
