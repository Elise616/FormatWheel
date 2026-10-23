import AppKit

/// "MISSION PASSED" / "WASTED" splash shown after an action finishes.
final class BannerView: NSView {
    static let height: CGFloat = 200

    private var passed = true
    private var title = ""
    private var detail = ""
    /// WASTED covers the whole screen and darkens it, like GTA's death screen.
    var fullScreen = false
    /// Intro animation, 0...1.
    var progress: CGFloat = 1 { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    func configure(passed: Bool, title: String, detail: String) {
        self.passed = passed
        self.title = title
        self.detail = detail
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let ease = 1 - pow(1 - min(max(progress, 0), 1), 3)
        if fullScreen {
            let whole = bounds
            let shade = CGGradient(colorsSpace: nil, colors: [NSColor(white: 0.05, alpha: 0.35).cgColor, NSColor(white: 0, alpha: 0.72).cgColor] as CFArray, locations: [0, 1])!
            cg.saveGState()
            cg.setAlpha(ease)
            let mid = CGPoint(x: whole.midX, y: whole.midY)
            cg.drawRadialGradient(shade, startCenter: mid, startRadius: 0, endCenter: mid, endRadius: hypot(whole.width, whole.height) / 2, options: [.drawsAfterEndLocation])
            cg.restoreGState()
        }
        // The band and text sit in a 200pt strip, centred (a little high on the full-screen variant).
        let b = fullScreen ? CGRect(x: 0, y: bounds.midY + 40 - BannerView.height / 2, width: bounds.width, height: BannerView.height) : bounds

        // Dark band that fades out towards both screen edges and softly at the top and bottom.
        let band = CGRect(x: 0, y: b.midY - 84, width: b.width, height: 168)
        cg.saveGState()
        cg.setAlpha(ease)
        cg.clip(to: band)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        let across = CGGradient(colorsSpace: nil, colors: [
            NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.7).cgColor,
            NSColor(white: 0, alpha: 0.7).cgColor, NSColor(white: 0, alpha: 0).cgColor,
        ] as CFArray, locations: [0.06, 0.3, 0.7, 0.94])!
        cg.drawLinearGradient(across, start: CGPoint(x: 0, y: 0), end: CGPoint(x: b.width, y: 0), options: [])
        cg.setBlendMode(.destinationIn)
        let down = CGGradient(colorsSpace: nil, colors: [
            NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 1).cgColor,
            NSColor(white: 0, alpha: 1).cgColor, NSColor(white: 0, alpha: 0).cgColor,
        ] as CFArray, locations: [0, 0.22, 0.78, 1])!
        cg.drawLinearGradient(down, start: CGPoint(x: 0, y: band.minY), end: CGPoint(x: 0, y: band.maxY), options: [])
        cg.endTransparencyLayer()
        cg.restoreGState()

        // Big word, punching in from slightly larger.
        let word = passed ? "MISSION PASSED" : "WASTED"
        let color = passed ? Theme.gold : Theme.wasted
        let zoom = 1 + 0.22 * (1 - ease)
        cg.saveGState()
        cg.setAlpha(ease)
        cg.translateBy(x: b.midX, y: b.midY + 26)
        cg.scaleBy(x: zoom, y: zoom)
        Draw.text(word, TextStyle(font: Fonts.splash(passed ? 64 : 76), color: color, outline: 3,
                                  outlineColor: NSColor(white: 0, alpha: 0.9), shadow: 10, kern: passed ? 2 : 4),
                  center: .zero)
        cg.restoreGState()

        cg.saveGState()
        cg.setAlpha(ease)
        let line = CGRect(x: b.midX - 230, y: b.midY - 14, width: 460, height: 1)
        NSColor(white: 1, alpha: 0.55).setFill()
        line.fill()
        Draw.text(title, TextStyle(font: Fonts.hud(21, .demi), shadow: 4), center: CGPoint(x: b.midX, y: b.midY - 33), maxWidth: b.width * 0.7)
        Draw.text(detail, TextStyle(font: Fonts.hud(16, .medium), color: NSColor(white: 1, alpha: 0.78), shadow: 3),
                  center: CGPoint(x: b.midX, y: b.midY - 56), maxWidth: b.width * 0.7)
        cg.restoreGState()
    }
}

final class BannerController {
    static let shared = BannerController()

    private var panel: NSPanel?
    private let view = BannerView(frame: .zero)
    private var timer: Timer?
    private var startedAt = Date()
    private var hideWork: DispatchWorkItem?

    func show(passed: Bool, title: String, detail: String, on screen: NSScreen?) {
        // Failures always show; the success splash can be switched off in the menu.
        guard !passed || Settings.shared.banner, let screen = screen ?? NSScreen.main else { return }
        let frame = passed ? CGRect(x: screen.frame.minX, y: screen.frame.midY - BannerView.height / 2 + 40,
                                    width: screen.frame.width, height: BannerView.height) : screen.frame
        view.fullScreen = !passed
        let panel = self.panel ?? Overlay.makePanel()
        panel.ignoresMouseEvents = true
        panel.contentView = view
        panel.setFrame(frame, display: false)
        panel.alphaValue = 1
        self.panel = panel
        view.configure(passed: passed, title: title, detail: detail)
        view.progress = 0
        panel.orderFrontRegardless()

        startedAt = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = CGFloat(Date().timeIntervalSince(self.startedAt) / 0.28)
            self.view.progress = min(p, 1)
            if p >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (passed ? 2.2 : 3.2), execute: work)
    }
}

/// Bottom-right busy spinner, like GTA's "Saving" indicator.
final class BusyView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var angle: CGFloat = 0 { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let fade = CGGradient(colorsSpace: nil, colors: [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.6).cgColor] as CFArray, locations: [0, 0.45])!
        cg.drawLinearGradient(fade, start: CGPoint(x: b.minX, y: 0), end: CGPoint(x: b.maxX, y: 0), options: [])

        let c = CGPoint(x: b.maxX - 26, y: b.midY)
        cg.saveGState()
        cg.setLineWidth(3)
        cg.setLineCap(.round)
        cg.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor)
        cg.addArc(center: c, radius: 9, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        cg.strokePath()
        cg.setStrokeColor(NSColor.white.cgColor)
        cg.addArc(center: c, radius: 9, startAngle: -angle, endAngle: -angle + .pi * 1.2, clockwise: false)
        cg.strokePath()
        cg.restoreGState()

        let style = TextStyle(font: Fonts.hud(16, .demi), shadow: 2, alignment: .right)
        Draw.draw(text, style, in: CGRect(x: 12, y: b.midY - 11, width: b.width - 60, height: 22))
    }
}

final class BusyHUD {
    static let shared = BusyHUD()

    private var panel: NSPanel?
    private let view = BusyView(frame: .zero)
    private var spin: Timer?
    private var jobs: [UUID: (label: String, progress: Double)] = [:]
    private var order: [UUID] = []

    func begin(_ label: String) -> UUID {
        let id = UUID()
        jobs[id] = (label, 0)
        order.append(id)
        // Quick jobs never flash the spinner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.jobs[id] != nil else { return }
            self.present()
        }
        return id
    }

    func update(_ id: UUID, progress: Double) {
        guard jobs[id] != nil else { return }
        jobs[id]?.progress = progress
        refresh()
    }

    func end(_ id: UUID) {
        jobs[id] = nil
        order.removeAll { $0 == id }
        if jobs.isEmpty {
            spin?.invalidate()
            spin = nil
            panel?.orderOut(nil)
        } else {
            refresh()
        }
    }

    private func refresh() {
        guard let first = order.first, let job = jobs[first] else { return }
        let pct = job.progress > 0.01 ? "  \(Int(job.progress * 100))%" : ""
        let more = jobs.count > 1 ? "（还有 \(jobs.count - 1) 个）" : ""
        view.text = "正在处理 · \(job.label)\(pct)\(more)"
    }

    private func present() {
        guard let screen = NSScreen.main else { return }
        let size = CGSize(width: 520, height: 44)
        let frame = CGRect(x: screen.visibleFrame.maxX - size.width - 16, y: screen.visibleFrame.minY + 24, width: size.width, height: size.height)
        let panel = self.panel ?? Overlay.makePanel()
        panel.ignoresMouseEvents = true
        panel.contentView = view
        panel.setFrame(frame, display: false)
        self.panel = panel
        refresh()
        panel.orderFrontRegardless()
        if spin == nil {
            let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.view.angle += 0.14 }
            RunLoop.main.add(t, forMode: .common)
            spin = t
        }
    }
}

