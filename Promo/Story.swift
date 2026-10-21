import AppKit

/// A sound effect placed on the film's timeline.
struct Cue {
    let time: Double
    let kind: SFX.Kind
    var gain: Float = 1
}

/// The launch film: 40 s at 100 BPM (one beat = 0.6 s), every frame a pure function of time.
final class Film {
    let duration = 40.2

    // Generated art.
    let wall = Art.wallpaper()
    lazy var frost = Art.frosted(wall)
    lazy var grayFrost = Art.grayscale(frost)
    let icon = Art.icon(512)
    lazy var photo = Art.crop(wall, CGRect(x: 820, y: 230, width: 720, height: 540))
    let pdfThumb = Art.canvas(240, 180) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.2, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 24, y: 138, width: 90, height: 18))
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        for k in 0..<6 { ctx.fill(CGRect(x: 24, y: 112 - CGFloat(k) * 17, width: k == 5 ? 110 : 192, height: 8)) }
    }

    // Parts borrowed from the app, so the film shows the real UI.
    let overlay = OverlayContent(frame: CGRect(x: 0, y: 0, width: W, height: H))
    let wheel = WheelView()
    let banner = BannerView(frame: CGRect(x: 0, y: H / 2 - BannerView.height / 2 + 40, width: W, height: BannerView.height))
    let wasted = BannerView(frame: CGRect(x: 0, y: 0, width: W, height: H))
    let bigStars = WantedView(frame: CGRect(origin: .zero, size: WantedView.size))
    let bigStats = StatsPanelView()

    let demoCenter = CGPoint(x: 960, y: 560)
    let demoRadius: CGFloat = 300
    let photoSpot = CGPoint(x: 300, y: 730)
    let demoWanted = Wanted(level: 4, reasons: ["GPS 定位", "iPhone 15 Pro", "拍摄时间"])
    var demoContext: WheelContext
    private var hoverTrack: [(time: Double, slot: Int?)] = []
    private(set) var cues: [Cue] = []

    struct Shot {
        let file: String
        let page: Int
        let slot: Int
        let label: [(String, NSColor)]
    }

    let shots: [Shot] = [
        Shot(file: "年度报告.pdf", page: 0, slot: 2, label: [("PDF", .white), ("  →  ", Palette.gold), ("长图", .white)]),
        Shot(file: "年度报告.pdf", page: 0, slot: 5, label: [("PDF", .white), ("  →  ", Palette.gold), ("Markdown", .white)]),
        Shot(file: "旅行 vlog.mov", page: 0, slot: 4, label: [("视频", .white), ("  →  ", Palette.gold), ("GIF 动图", .white)]),
        Shot(file: "旅行 vlog.mov", page: 1, slot: 0, label: [("视频", .white), ("  ·  ", Palette.gold), ("压缩一半", .white)]),
        Shot(file: "demo.mp3", page: 0, slot: 7, label: [("音乐", .white), ("  →  ", Palette.gold), ("iPhone 铃声", .white)]),
        Shot(file: "录音.wav", page: 0, slot: 0, label: [("WAV", .white), ("  →  ", Palette.gold), ("MP3", .white)]),
        Shot(file: "人像.jpg", page: 1, slot: 2, label: [("一键", .white), ("抠图", Palette.gold)]),
        Shot(file: "截图.png", page: 1, slot: 3, label: [("截图", .white), ("识字", Palette.gold)]),
        Shot(file: "截图.png", page: 1, slot: 7, label: [("截图", .white), ("加背景", Palette.gold)]),
        Shot(file: "合同.docx", page: 0, slot: 0, label: [("Word", .white), ("  →  ", Palette.gold), ("PDF", .white)]),
        Shot(file: "年度报告.pdf", page: 1, slot: 1, label: [("PDF", .white), ("  ·  ", Palette.gold), ("拆页", .white)]),
        Shot(file: "素材", page: 0, slot: 0, label: [("文件夹", .white), ("  →  ", Palette.gold), ("ZIP", .white)]),
    ]
    private var shotContexts: [WheelContext] = []

    init() {
        var context = Catalog.context(for: [URL(fileURLWithPath: "/tmp/IMG_2049.HEIC")])
        context.headline = "IMG_2049.HEIC"
        context.summary = "2.4 MB · 4032×3024 · HEIC"
        demoContext = context
        shotContexts = shots.map { Catalog.context(for: [URL(fileURLWithPath: "/tmp/\($0.file)")]) }

        overlay.arrange(wheelCenter: demoCenter, radius: demoRadius, topInset: 0, rows: context.statLabels.count)
        overlay.setAccent(Palette.blue)
        wheel.accent = Palette.blue
        wheel.radius = 280
        let side = WheelView.side(for: 280)
        wheel.frame = CGRect(x: 0, y: 0, width: side, height: side)

        var stillShot = Catalog.context(for: [URL(fileURLWithPath: "/tmp/截图.png")])
        stillShot.headline = "截图.png"
        let jpg = stillShot.pages[0].slots[1]!
        bigStats.frame = CGRect(x: 0, y: 0, width: StatsPanelView.width, height: StatsPanelView.height(rows: 4))
        bigStats.labels = stillShot.statLabels
        bigStats.base = stillShot.base
        bigStats.target = jpg.stats ?? stillShot.base
        bigStats.title = "JPG"
        bigStats.caption = "截图.png  →  JPG"
        bigStats.accent = Palette.blue

        buildHoverTrack()
        buildCues()
    }

    // MARK: - Timeline

    func draw(_ s: Stage, at t: Double) {
        s.fill(Palette.ink)
        switch t {
        case ..<3.6: hook(s, t)
        case ..<7.2: reveal(s, t - 3.6)
        case ..<16.8: demo(s, t - 7.2)
        case ..<24.0: montage(s, t - 16.8)
        case ..<27.6: statsScene(s, t - 24.0)
        case ..<33.0: wantedScene(s, t - 27.6)
        case ..<35.4: wastedScene(s, t - 33.0)
        default: endCard(s, t - 35.4)
        }
    }

    // MARK: 1 · Hook (0–3.6)

    private func hook(_ s: Stage, _ t: Double) {
        s.vignette(strength: 0.7)
        let out = Ease.inOut(span(t, 3.15, 0.45))
        s.transform(pivot: CGPoint(x: W / 2, y: H / 2), scale: CGFloat(1 - 0.06 * out)) {
            s.group(alpha: CGFloat(1 - out)) {
                s.reveal([("转个格式", .white)], font: Typeset.heavy(132), center: CGPoint(x: W / 2, y: 600), t: t, start: 0.12)
                let steps: [(String, NSColor)] = [("还要 ", Palette.dim), ("找网站", .white), (" → ", Palette.dim), ("上传", .white),
                                                   (" → ", Palette.dim), ("等待", .white), (" → ", Palette.dim), ("下载", .white), ("？", .white)]
                let strike = Ease.out(span(t, 2.35, 0.35))
                s.reveal(steps, font: Typeset.bold(60), center: CGPoint(x: W / 2, y: 440), t: t, start: 0.75, stagger: 0.13,
                         alpha: CGFloat(1 - 0.55 * strike))
                if strike > 0 {
                    let width = steps.reduce(CGFloat(0)) { $0 + s.width($1.0, font: Typeset.bold(60)) }
                    s.ctx.setFillColor(Palette.red.cgColor)
                    s.ctx.fill(CGRect(x: W / 2 - width / 2 - 10, y: 436, width: (width + 20) * CGFloat(strike), height: 9))
                }
            }
        }
    }

    // MARK: 2 · Reveal (3.6–7.2)

    private func reveal(_ s: Stage, _ t: Double) {
        let flash = max(0, 1 - t / 0.18)
        s.glow(Palette.gold, at: CGPoint(x: W / 2, y: H / 2), radius: 900, alpha: 0.22)
        // The wheel turning in behind the words.
        wheel.context = demoContext
        wheel.page = 0
        wheel.hover = nil
        wheel.glow = Array(repeating: 0, count: 8)
        wheel.contentFade = 1
        wheel.pop = 1
        let spin = Ease.out(span(t, 0, 1.4))
        let center = CGPoint(x: W / 2, y: H / 2 + 20)
        s.transform(pivot: center, scale: CGFloat(1.5 - 0.25 * spin), rotate: CGFloat(-0.5 * (1 - spin))) {
            s.view(wheel, at: CGPoint(x: center.x - wheel.bounds.width / 2, y: center.y - wheel.bounds.height / 2), alpha: 0.32)
        }
        s.fill(NSColor(white: 0, alpha: 0.35))

        let exit = Ease.inOut(span(t, 3.2, 0.4))
        s.group(alpha: CGFloat(1 - exit)) {
            s.reveal([("所以我们把它", NSColor(white: 1, alpha: 0.85))], font: Typeset.bold(56), center: CGPoint(x: W / 2, y: 660), t: t, start: 0.1)
            let slam = span(t, 0.5, 0.32)
            if slam > 0 {
                let shake = t < 0.95 ? CGFloat(sin(t * 90) * 10 * (0.95 - t)) : 0
                s.transform(pivot: CGPoint(x: W / 2, y: 480), scale: CGFloat(1.7 - 0.7 * Ease.back(slam)), offset: CGPoint(x: shake, y: shake * 0.6)) {
                    s.text("做成了武器轮盘", font: Typeset.heavy(150), color: Palette.gold, center: CGPoint(x: W / 2, y: 480),
                           alpha: CGFloat(min(1, slam * 3)), outline: 5, shadow: 18)
                }
            }
            s.reveal([("拖着文件，按一下 ", NSColor(white: 1, alpha: 0.7)), ("Shift", .white)], font: Typeset.medium(40),
                     center: CGPoint(x: W / 2, y: 320), t: t, start: 1.5)
        }
        if flash > 0 { s.fill(NSColor(white: 1, alpha: CGFloat(flash) * 0.85)) }
    }

    // MARK: 3 · The gesture on a desktop (7.2–16.8)

    private func demoCursor(_ u: Double) -> CGPoint {
        let start = CGPoint(x: 1500, y: 250)
        let grab = CGPoint(x: photoSpot.x + 8, y: photoSpot.y + 6)
        if u < 0.2 { return start }
        if u < 1.0 { return lerp(start, grab, Ease.inOut(span(u, 0.2, 0.8))) }
        if u < 1.1 { return grab }
        if u < 1.7 { return lerp(grab, demoCenter, Ease.inOut(span(u, 1.1, 0.6))) }
        let path: [(Double, CGFloat, CGFloat)] = [(2.25, 0, 0), (2.7, -125, -125), (3.1, -178, 0), (3.5, -125, 125),
                                                  (3.9, 0, 178), (4.45, 125, 125)]
        if u < path[0].0 { return demoCenter }
        for i in 0..<(path.count - 1) where u < path[i + 1].0 {
            let a = path[i], b = path[i + 1]
            let k = Ease.inOut((u - a.0) / (b.0 - a.0))
            return CGPoint(x: demoCenter.x + lerp(a.1, b.1, k), y: demoCenter.y + lerp(a.2, b.2, k))
        }
        return CGPoint(x: demoCenter.x + 125, y: demoCenter.y + 125)
    }

    /// Same direction rule as the app: outside the dead zone, the nearest 45° sector wins.
    private func slot(at p: CGPoint) -> Int? {
        let dx = p.x - demoCenter.x, dy = p.y - demoCenter.y
        guard hypot(dx, dy) >= 54 else { return nil }
        var theta = atan2(dx, dy)
        if theta < 0 { theta += 2 * .pi }
        return Int((theta + .pi / 8) / (.pi / 4)) % 8
    }

    private func buildHoverTrack() {
        var last: Int?? = .none
        var u = 1.82
        while u <= 5.4 {
            let current = slot(at: demoCursor(u))
            if last == .none || last! != current {
                hoverTrack.append((u, current))
                last = .some(current)
            }
            u += 1.0 / 600
        }
    }

    private func hoverState(_ u: Double) -> (slot: Int?, since: Double, previous: Int?) {
        var state: (Int?, Double, Int?) = (nil, 0, nil)
        for (i, entry) in hoverTrack.enumerated() where entry.time <= u {
            state = (entry.slot, entry.time, i > 0 ? hoverTrack[i - 1].slot : nil)
        }
        return state
    }

    private func demo(_ s: Stage, _ u: Double) {
        let open = 1.82, release = 5.4
        let showWheel = u >= open && u < release + 0.2
        let veil = u < release ? Ease.out(span(u, open, 0.14)) : 1 - Ease.out(span(u, release, 0.2))
        let cursor = demoCursor(u)

        s.image(wall, in: CGRect(x: 0, y: 0, width: W, height: H))
        // Desktop icons; the converted copy appears after the drop.
        let dragging = u >= 1.1 && u < release
        s.fileIcon(pdfThumb, name: "年度报告.pdf", center: CGPoint(x: 300, y: 920))
        s.fileIcon(photo, name: "IMG_2049.HEIC", center: photoSpot, selected: u >= 1.05, alpha: dragging ? 0.55 : 1)
        let born = span(u, 6.6, 0.35)
        if born > 0 {
            s.fileIcon(photo, name: "IMG_2049.jpg", center: CGPoint(x: 300, y: 540), selected: true, scale: CGFloat(Ease.back(born)))
        }

        if veil > 0.001 {
            s.image(frost, in: CGRect(x: 0, y: 0, width: W, height: H), alpha: CGFloat(veil))
            overlay.dim.focus = demoCenter
            s.view(overlay.dim, at: .zero, alpha: CGFloat(veil))
        }
        if showWheel {
            let state = hoverState(u)
            overlay.apply(context: demoContext, page: 0, hover: state.slot)
            var glow = [CGFloat](repeating: 0, count: 8)
            let k = CGFloat(1 - exp(-(u - state.since) * 24))
            if let current = state.slot { glow[current] = k }
            if let previous = state.previous, previous != state.slot { glow[previous] = max(glow[previous], 1 - k) }
            overlay.wheel.glow = glow
            overlay.wheel.pop = CGFloat(span(u, open, 0.16))
            overlay.wheel.contentFade = 1
            overlay.stats.shown = overlay.stats.target
            overlay.wanted.show(demoWanted)
            overlay.wanted.appear = CGFloat(span(u, open + 0.28, 0.9))
            overlay.wanted.phase = CGFloat(u - open)
            let a = CGFloat(veil)
            s.view(overlay.wheel, at: overlay.wheel.frame.origin, alpha: a)
            s.view(overlay.help, at: overlay.help.frame.origin, alpha: a)
            s.view(overlay.stats, at: overlay.stats.frame.origin, alpha: a)
            s.view(overlay.wanted, at: overlay.wanted.frame.origin, alpha: a)
        }

        // The dragged file follows the pointer, with the green "+" once a slot will take it.
        if dragging {
            let over = showWheel && hoverState(u).slot != nil
            s.fileIcon(photo, name: "IMG_2049.HEIC", center: CGPoint(x: cursor.x + 34, y: cursor.y - 40), alpha: 0.72, scale: 0.72, badge: over)
        }
        if u < release + 2.5 || u > 6.4 {
            s.cursor(at: cursor, pressed: u >= 1.05 && u < release)
        }

        // Shift keycap.
        let capIn = span(u, 1.4, 0.18), capOut = span(u, 2.3, 0.25)
        let press = CGFloat(span(u, 1.78, 0.05) * (1 - span(u, 2.0, 0.08)))
        if capIn > 0 && capOut < 1 {
            s.keycap("⇧ shift", center: CGPoint(x: 1520, y: 300), press: press, alpha: CGFloat(Ease.out(capIn) * (1 - capOut)))
        }

        let captions: [(String, String, Double, Double)] = [("1", "拖住文件", 0.3, 1.6), ("2", "按一下 Shift", 1.6, 2.4),
                                                            ("3", "朝格子方向一甩", 2.4, 5.35), ("4", "松手，完成", 5.4, 7.0)]
        for (step, text, from, to) in captions {
            let a = Ease.out(span(u, from, 0.2)) * (1 - Ease.out(span(u, to - 0.15, 0.15)))
            if a > 0 { s.caption(step: step, text, alpha: CGFloat(a)) }
        }

        let bannerIn = span(u, release + 0.05, 0.28)
        let bannerOut = span(u, 7.15, 0.35)
        if bannerIn > 0 && bannerOut < 1 {
            banner.configure(passed: true, title: "IMG_2049.HEIC  →  JPG", detail: "2.4 MB → 1.1 MB · 存到「桌面」")
            banner.progress = CGFloat(bannerIn)
            s.view(banner, at: banner.frame.origin, alpha: CGFloat(1 - bannerOut))
        }

        let outro = span(u, 7.2, 0.3) * (1 - span(u, 9.3, 0.3))
        if outro > 0 {
            s.fill(NSColor(white: 0, alpha: CGFloat(outro) * 0.62))
            s.reveal([("从拖到转，", .white), ("不到 1 秒", Palette.gold)], font: Typeset.heavy(104), center: CGPoint(x: W / 2, y: 560),
                     t: u, start: 7.25, alpha: CGFloat(1 - span(u, 9.3, 0.3)))
        }
    }

    // MARK: 4 · Montage (16.8–24.0), one cut per beat

    private func montage(_ s: Stage, _ t: Double) {
        let index = min(Int(t / 0.6), shots.count - 1)
        let v = t - Double(index) * 0.6
        let shot = shots[index], context = shotContexts[index]
        let tint = index % 2 == 0 ? Palette.blue : Palette.gold
        s.glow(tint, at: CGPoint(x: W / 2, y: 600), radius: 820, alpha: 0.2)
        s.vignette(strength: 0.6)

        wheel.context = context
        wheel.page = shot.page
        wheel.hover = shot.slot
        var glow = [CGFloat](repeating: 0, count: 8)
        glow[shot.slot] = CGFloat(1 - exp(-v * 30))
        wheel.glow = glow
        wheel.contentFade = 1
        wheel.pop = 1
        let inK = Ease.out(span(v, 0, 0.22))
        let center = CGPoint(x: W / 2, y: 600)
        s.transform(pivot: center, scale: CGFloat(0.93 + 0.07 * inK), rotate: CGFloat(-0.07 * (1 - inK))) {
            s.view(wheel, at: CGPoint(x: center.x - wheel.bounds.width / 2, y: center.y - wheel.bounds.height / 2))
        }
        s.reveal(shot.label, font: Typeset.heavy(66), center: CGPoint(x: W / 2, y: 175), t: v, start: 0.02, stagger: 0.05, duration: 0.25, rise: 18)
        let header = Ease.out(span(t, 0, 0.3))
        s.text("一个手势 · 60 种操作", font: Typeset.bold(40), color: Palette.dim, center: CGPoint(x: W / 2, y: 1000), alpha: CGFloat(header))
        s.text(String(format: "%02d / %02d", index + 1, shots.count), font: Typeset.medium(26), color: Palette.dim,
               center: CGPoint(x: W - 120, y: 1000), alpha: CGFloat(header))
    }

    // MARK: 5 · Weapon stats (24.0–27.6)

    private func statsScene(_ s: Stage, _ t: Double) {
        s.image(frost, in: CGRect(x: 0, y: 0, width: W, height: H))
        s.fill(NSColor(white: 0, alpha: 0.45))
        s.reveal([("每种格式，都有", .white), ("武器属性", Palette.gold)], font: Typeset.heavy(78), center: CGPoint(x: W / 2, y: 930), t: t, start: 0.05)

        let k = Ease.inOut(span(t, 0.7, 0.9))
        bigStats.shown = zip(bigStats.base, bigStats.target).map { $0 + ($1 - $0) * k }
        let scale: CGFloat = 2.3
        let size = bigStats.bounds.size
        let origin = CGPoint(x: W / 2 - size.width * scale / 2, y: 470 - size.height * scale / 2)
        s.transform(pivot: origin, scale: scale, offset: .zero) {
            s.view(bigStats, at: origin, alpha: CGFloat(Ease.out(span(t, 0.2, 0.3))))
        }
        let legend = Ease.out(span(t, 1.7, 0.3))
        s.group(alpha: CGFloat(legend)) {
            s.ctx.setFillColor(Theme.gain.cgColor)
            s.ctx.fill(CGRect(x: W / 2 - 330, y: 128, width: 36, height: 16))
            s.text("蓝色 = 提升", font: Typeset.bold(36), center: CGPoint(x: W / 2 - 190, y: 136))
            s.ctx.setFillColor(Theme.loss.cgColor)
            s.ctx.fill(CGRect(x: W / 2 + 60, y: 128, width: 36, height: 16))
            s.text("红色 = 牺牲", font: Typeset.bold(36), center: CGPoint(x: W / 2 + 200, y: 136))
        }
    }

    // MARK: 6 · Wanted level (27.6–33.0)

    private func wantedScene(_ s: Stage, _ q: Double) {
        let evade = span(q, 2.9, 1.3)
        // Police lights sweeping the frame edges while wanted.
        if q > 0.5 && evade < 1 {
            let red = Int(q * 4) % 2 == 0
            let light = red ? NSColor(srgbRed: 0.95, green: 0.12, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.15, green: 0.35, blue: 1, alpha: 1)
            s.glow(light, at: CGPoint(x: red ? 0 : W, y: H / 2), radius: 900, alpha: CGFloat(0.35 * (1 - evade)))
        }
        s.vignette(strength: 0.6)

        let lostCops = q >= 2.6
        let headA = 1 - span(q, 2.45, 0.2)
        s.reveal([("照片里，藏着你的", .white), ("位置", Palette.red)], font: Typeset.heavy(80), center: CGPoint(x: W / 2, y: 940), t: q, start: 0.15,
                 alpha: CGFloat(headA))
        if lostCops {
            s.reveal([("一键", .white), ("去隐私", Palette.gold), ("，甩掉警察", .white)], font: Typeset.heavy(80),
                     center: CGPoint(x: W / 2, y: 940), t: q, start: 2.65)
        }

        // The photo's dossier on the left.
        let card = CGRect(x: 250, y: 300, width: 560, height: 420)
        s.group(alpha: CGFloat(Ease.out(span(q, 0.1, 0.3)))) {
            s.ctx.saveGState()
            s.ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: NSColor(white: 0, alpha: 0.6).cgColor)
            s.ctx.setFillColor(NSColor.white.cgColor)
            s.ctx.fill(card)
            s.ctx.restoreGState()
            s.image(photo, in: card.insetBy(dx: 14, dy: 14))
        }
        let facts = ["📍  22.28°N, 114.16°E", "📱  iPhone 15 Pro", "🕒  2026-10-01  12:00"]
        for (i, fact) in facts.enumerated() {
            let y = 230 - CGFloat(i) * 56
            let a = Ease.out(span(q, 0.6 + Double(i) * 0.25, 0.3))
            s.text(fact, font: Typeset.bold(36), center: CGPoint(x: card.midX, y: y), alpha: CGFloat(a))
            let cut = Ease.out(span(q, 3.0 + Double(i) * 0.15, 0.25))
            if cut > 0 {
                let w = s.width(fact, font: Typeset.bold(36)) + 20
                s.ctx.setFillColor(Palette.red.cgColor)
                s.ctx.fill(CGRect(x: card.midX - w / 2, y: y - 3, width: w * CGFloat(cut), height: 6))
            }
        }

        // The stars, huge, on the right.
        bigStars.show(demoWanted)
        bigStars.appear = CGFloat(span(q, 0.55, 1.1))
        bigStars.phase = CGFloat(q)
        bigStars.evading = lostCops
        bigStars.caption = lostCops ? "已甩掉警察" : nil
        let scale: CGFloat = 2.4
        let origin = CGPoint(x: 900, y: 470)
        s.transform(pivot: origin, scale: scale) {
            s.view(bigStars, at: origin, alpha: CGFloat(1 - evade))
        }
        if evade > 0.6 {
            s.text("通缉解除", font: Typeset.heavy(72), color: Palette.gold, center: CGPoint(x: 1600, y: 600),
                   alpha: CGFloat(Ease.out((evade - 0.6) / 0.4)), outline: 3, shadow: 10)
        }
    }

    // MARK: 7 · Wasted (33.0–35.4)

    private func wastedScene(_ s: Stage, _ z: Double) {
        let zoom = CGFloat(1 + 0.05 * z / 2.4)
        s.transform(pivot: CGPoint(x: W / 2, y: H / 2), scale: zoom) {
            s.image(grayFrost, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        wasted.fullScreen = true
        wasted.configure(passed: false, title: "翻车也要有仪式感", detail: "（放心，原文件一根头发都不会少）")
        wasted.progress = CGFloat(span(z, 0.05, 0.3))
        s.view(wasted, at: .zero)
    }

    // MARK: 8 · End card (35.4–40.2)

    private func endCard(_ s: Stage, _ e: Double) {
        s.glow(Palette.gold, at: CGPoint(x: W / 2, y: 640), radius: 700, alpha: 0.18)
        s.vignette(strength: 0.7)
        let fade = 1 - Ease.inOut(span(e, 4.0, 0.8))
        s.group(alpha: CGFloat(fade)) {
            let pop = Ease.back(span(e, 0.1, 0.5))
            if pop > 0 {
                let side: CGFloat = 300 * CGFloat(pop)
                s.image(icon, in: CGRect(x: W / 2 - side / 2, y: 640 - side / 2, width: side, height: side))
            }
            s.reveal([("格式轮盘", .white)], font: Typeset.heavy(118), center: CGPoint(x: W / 2, y: 405), t: e, start: 0.45)
            s.reveal([("拖着文件，按 ", Palette.dim), ("Shift", .white), ("。", Palette.dim)], font: Typeset.bold(48),
                     center: CGPoint(x: W / 2, y: 300), t: e, start: 0.8)
            s.reveal([("macOS 菜单栏小工具 · 图片 / PDF / 视频 / 音频 / 文档", NSColor(white: 1, alpha: 0.42))], font: Typeset.medium(30),
                     center: CGPoint(x: W / 2, y: 225), t: e, start: 1.2)
        }
    }

    // MARK: - Sound cues

    private func buildCues() {
        var c: [Cue] = [Cue(time: 0.12, kind: .tick, gain: 0.8)]
        for i in 0..<9 where i % 2 == 1 || i == 0 { c.append(Cue(time: 0.75 + Double(i) * 0.13, kind: .tick, gain: 0.55)) }
        c.append(Cue(time: 2.35, kind: .page, gain: 0.9))
        c.append(Cue(time: 4.1, kind: .rackPump, gain: 1))
        c.append(Cue(time: 4.1, kind: .open, gain: 0.6))

        let base = 7.2
        c.append(Cue(time: base + 1.05, kind: .tick, gain: 0.8))
        c.append(Cue(time: base + 1.78, kind: .tick, gain: 1))
        c.append(Cue(time: base + 1.82, kind: .open, gain: 0.9))
        c.append(Cue(time: base + 2.1, kind: .wanted, gain: 0.8))
        for entry in hoverTrack where entry.slot != nil && entry.time > 1.9 {
            c.append(Cue(time: base + entry.time, kind: .tick, gain: 0.9))
        }
        c.append(Cue(time: base + 5.4, kind: Weapon.of("img.to.jpg").sound, gain: 1))
        c.append(Cue(time: base + 5.7, kind: .passed, gain: 1))
        c.append(Cue(time: base + 6.6, kind: .page, gain: 0.6))

        for (i, shot) in shots.enumerated() {
            let id = shotContexts[i].pages[shot.page].slots[shot.slot]?.id ?? ""
            c.append(Cue(time: 16.8 + Double(i) * 0.6, kind: Weapon.of(id).sound, gain: 0.7))
        }
        c.append(Cue(time: 24.7, kind: .tick, gain: 0.7))
        c.append(Cue(time: 28.15, kind: .wanted, gain: 1))
        c.append(Cue(time: 30.4, kind: .rackPistol, gain: 0.8))
        c.append(Cue(time: 30.6, kind: .evaded, gain: 1))
        c.append(Cue(time: 33.0, kind: .wasted, gain: 1))
        c.append(Cue(time: 35.5, kind: .passed, gain: 1))
        cues = c
    }
}
