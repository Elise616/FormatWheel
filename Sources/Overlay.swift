import AppKit

final class OverlayPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

/// Full-screen root of the overlay. It is the drop target for the whole screen, so a drag can
/// never "miss" while the wheel is up; the slot is chosen by direction from the wheel centre.
final class OverlayRootView: NSView {
    weak var controller: Overlay?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragMoved(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragMoved(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.canDrop() ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDrop(sender) ?? false }
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.dragEnded() }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func mouseDown(with event: NSEvent) { controller?.clicked(at: NSEvent.mouseLocation) }
    override func rightMouseDown(with event: NSEvent) { controller?.close(animated: true) }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > 3 || abs(event.scrollingDeltaX) > 3 { controller?.flipPage() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.close(animated: true) // esc
        case 48, 12, 14: controller?.flipPage()     // tab, q, e
        case 36, 49: controller?.clicked(at: NSEvent.mouseLocation) // return, space
        default: super.keyDown(with: event)
        }
    }
}

final class Overlay {
    static let shared = Overlay()

    enum Mode {
        /// Opened by Shift during a Finder drag; dropping picks the slot.
        case drag
        /// Opened from the menu for chosen files; clicking picks the slot.
        case click
        /// Opened from the menu with a sample file; nothing is converted.
        case demo
    }

    private var panel: OverlayPanel?
    private var root: OverlayRootView?
    private var blur: NSVisualEffectView?
    private var content: OverlayContent?

    private(set) var isOpen = false
    private var mode: Mode = .drag
    private var context: WheelContext?
    private var page = 0
    private var hover: Int?
    private var center: CGPoint = .zero
    private var openPoint: CGPoint = .zero
    private var armed = false
    private var radius: CGFloat = 245
    private var screen: NSScreen?
    private var timer: Timer?
    private var lastTick = Date()
    private var lastShift = false
    private var closeWork: DispatchWorkItem?
    /// The system routed at least one drag event to the wheel during this open.
    private var dragSeen = false
    private var dropped = false
    private var wanted = Wanted()
    private var scanToken = UUID()

    private func reveal(_ found: Wanted) {
        wanted = found
        content?.wanted.show(found)
        if found.level > 0 {
            SFX.shared.play(.wanted)
            Log.write("wheel: wanted level \(found.level) (\(found.reasons.joined(separator: ", ")))")
        }
    }

    static func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Must stay below the system drag-image layer (CGWindowLevelForKey(.draggingWindow) = 500):
        // the drag manager only looks for drop targets underneath it. At .screenSaver (1000) the
        // wheel was skipped and every drop fell through to Finder. .popUpMenu still covers the
        // menu bar and Dock, and the dragged icon now floats on top of the wheel.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        return panel
    }

    // MARK: - Open / close

    func open(files: [URL], mode: Mode, at mouse: CGPoint, context override: WheelContext? = nil) {
        let context = override ?? Catalog.context(for: files)
        guard !context.pages.isEmpty else { return }
        closeWork?.cancel()
        self.context = context
        self.mode = mode
        page = 0
        hover = nil
        lastShift = NSEvent.modifierFlags.contains(.shift)

        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        self.screen = screen
        let frame = screen.frame
        let topInset = max(0, frame.maxY - screen.visibleFrame.maxY)
        radius = min(Settings.shared.wheelSize.radius, (frame.height - topInset - 72) / 2)
        let margin = radius + 30
        center = CGPoint(x: min(max(mouse.x, frame.minX + margin), frame.maxX - margin),
                         y: min(max(mouse.y, frame.minY + margin), frame.maxY - topInset - margin))
        openPoint = mouse
        // When the wheel had to shift away from the cursor, wait for a deliberate move before selecting.
        armed = hypot(center.x - mouse.x, center.y - mouse.y) < 4

        let (panel, root, blur, content) = ensureViews()
        panel.keyable = mode != .drag
        panel.setFrame(frame, display: false)
        root.frame = CGRect(origin: .zero, size: frame.size)
        blur.frame = root.bounds
        blur.isHidden = !Settings.shared.blur
        content.frame = root.bounds
        content.arrange(wheelCenter: CGPoint(x: center.x - frame.minX, y: center.y - frame.minY),
                        radius: radius, topInset: topInset, rows: context.statLabels.count)
        content.setAccent(Theme.accent)
        content.wheel.glow = Array(repeating: 0, count: 8)
        content.wheel.contentFade = 1
        content.wheel.pop = 0
        content.stats.shown = context.base
        content.apply(context: context, page: page, hover: nil)
        content.dim.needsDisplay = true
        wanted = Wanted()
        content.wanted.reset()
        if mode == .demo {
            reveal(Wanted(level: 3, reasons: ["GPS 定位", "iPhone 15 Pro", "拍摄时间"]))
        } else {
            let token = UUID()
            scanToken = token
            let files = context.files
            Task.detached(priority: .userInitiated) { [weak self] in
                let found = await Privacy.scan(files)
                await MainActor.run {
                    guard let self, self.isOpen, self.scanToken == token else { return }
                    self.reveal(found)
                }
            }
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if mode != .drag {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            panel.makeFirstResponder(root)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        isOpen = true
        dragSeen = false
        dropped = false
        Log.write("wheel: open \(mode) kind=\(context.kind) files=\(context.files.count) center=\(Int(center.x)),\(Int(center.y)) mouse=\(Int(mouse.x)),\(Int(mouse.y))")
        SFX.shared.play(.open)
        startTimer()
    }

    /// Builds the overlay window up front so its drop registration exists before any drag starts.
    func prepare() {
        _ = ensureViews()
    }

    private func ensureViews() -> (OverlayPanel, OverlayRootView, NSVisualEffectView, OverlayContent) {
        if let panel, let root, let blur, let content { return (panel, root, blur, content) }
        let panel = Overlay.makePanel()
        // Explicitly false: the whole window (not just its painted pixels) takes mouse and drag events.
        panel.ignoresMouseEvents = false
        let root = OverlayRootView(frame: .zero)
        root.controller = self
        // Registered once and kept; while the wheel is closed the window is off screen anyway.
        root.registerForDraggedTypes([.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        let blur = NSVisualEffectView(frame: .zero)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        let content = OverlayContent(frame: .zero)
        root.addSubview(blur)
        root.addSubview(content)
        panel.contentView = root
        self.panel = panel
        self.root = root
        self.blur = blur
        self.content = content
        return (panel, root, blur, content)
    }

    func close(animated: Bool) {
        guard isOpen, let panel else { return }
        isOpen = false
        Log.write("wheel: close")
        closeWork?.cancel()
        timer?.invalidate()
        timer = nil
        let wasActive = mode != .drag
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isOpen else { return }
                panel.orderOut(nil)
            })
        } else {
            panel.orderOut(nil)
        }
        if wasActive { NSApp.hide(nil) }
    }

    private func scheduleClose(after delay: Double) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close(animated: true) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Selection

    private var currentOption: WheelOption? {
        guard let context, let hover else { return nil }
        return context.pages[safe: page]?.slots[safe: hover] ?? nil
    }

    private func slot(at p: CGPoint) -> Int? {
        if !armed {
            guard hypot(p.x - openPoint.x, p.y - openPoint.y) > 12 else { return nil }
            armed = true
        }
        let dx = p.x - center.x, dy = p.y - center.y
        let deadZone = max(28, radius * 0.6 * 0.3)
        guard hypot(dx, dy) >= deadZone else { return nil }
        var theta = atan2(dx, dy)
        if theta < 0 { theta += 2 * .pi }
        var index = Int((theta + .pi / 8) / (.pi / 4)) % 8
        // A little hysteresis so the highlight doesn't flicker on a boundary.
        if let current = hover, current != index {
            var diff = abs(theta - CGFloat(current) * .pi / 4)
            if diff > .pi { diff = 2 * .pi - diff }
            if diff < .pi / 8 + 0.07 { index = current }
        }
        return index
    }

    private func updateHover(_ p: CGPoint) {
        guard let context, let content else { return }
        let next = slot(at: p)
        guard next != hover else { return }
        hover = next
        content.apply(context: context, page: page, hover: hover)
        if let next, context.pages[safe: page]?.slots[safe: next] ?? nil != nil { SFX.shared.play(.tick) }
    }

    func flipPage() {
        guard isOpen, let context, context.pages.count > 1, let content else { return }
        page = (page + 1) % context.pages.count
        content.wheel.contentFade = 0.1
        content.apply(context: context, page: page, hover: hover)
        SFX.shared.play(.page)
    }

    // MARK: - Animation tick

    private func startTimer() {
        timer?.invalidate()
        lastTick = Date()
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard isOpen, let content, let context else { return }
        let now = Date()
        let dt = CGFloat(min(0.05, now.timeIntervalSince(lastTick)))
        lastTick = now

        updateHover(NSEvent.mouseLocation)
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift && !lastShift { flipPage() }
        lastShift = shift

        let wheel = content.wheel
        var dirty = false
        let slots = context.pages[safe: page]?.slots ?? []
        for i in 0..<8 {
            var target: CGFloat = 0
            if i == hover, let option = slots[safe: i] ?? nil { target = option.enabled ? 1 : 0.35 }
            let g = wheel.glow[i]
            guard g != target else { continue }
            wheel.glow[i] = abs(target - g) < 0.004 ? target : g + (target - g) * min(1, dt * 24)
            dirty = true
        }
        if wheel.contentFade < 1 {
            wheel.contentFade = min(1, wheel.contentFade + dt * 7)
            dirty = true
        }
        if wheel.pop < 1 {
            wheel.pop = min(1, wheel.pop + dt / 0.16)
            dirty = true
        }
        if dirty { wheel.needsDisplay = true }

        let stats = content.stats
        var statsDirty = false
        for i in 0..<stats.target.count {
            let current = stats.shown[safe: i] ?? 0, target = stats.target[i]
            guard current != target else { continue }
            if i >= stats.shown.count { stats.shown.append(target) } else {
                stats.shown[i] = abs(target - current) < 0.002 ? target : current + (target - current) * Double(min(1, dt * 14))
            }
            statsDirty = true
        }
        if statsDirty { stats.needsDisplay = true }

        let stars = content.wanted
        if stars.level > 0 {
            stars.phase += dt
            if stars.appear < 1 { stars.appear = min(1, stars.appear + dt / 0.9) }
            // Pointing at 去隐私 previews losing the cops: the stars start to blink.
            let lyingLow = currentOption.map { $0.enabled && $0.id.hasSuffix(".strip") } ?? false
            stars.evading = lyingLow
            stars.caption = lyingLow ? "松手 = 甩掉警察" : nil
            stars.needsDisplay = true
        }
    }

    // MARK: - Drag destination

    func dragMoved(_ info: NSDraggingInfo) -> NSDragOperation {
        guard isOpen, let panel else { return [] }
        closeWork?.cancel()
        if !dragSeen {
            dragSeen = true
            Log.write("wheel: drag entered overlay")
        }
        updateHover(panel.convertPoint(toScreen: info.draggingLocation))
        return currentOption?.enabled == true ? .copy : []
    }

    func canDrop() -> Bool {
        isOpen && currentOption?.enabled == true
    }

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        guard isOpen, let panel, let context else { return false }
        updateHover(panel.convertPoint(toScreen: info.draggingLocation))
        Log.write("wheel: drop on slot \(hover.map(String.init) ?? "none") → \(currentOption?.id ?? "nothing")")
        guard let option = currentOption, option.enabled else {
            close(animated: true)
            return false
        }
        dropped = true
        let files = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let screen = self.screen
        close(animated: true)
        Runner.shared.run(option, files: files.isEmpty ? context.files : files, screen: screen, wanted: wanted)
        return true
    }

    func dragExited() {
        guard isOpen, mode == .drag else { return }
        Log.write("wheel: drag exited overlay")
        scheduleClose(after: 0.2)
    }

    func dragEnded() {
        guard isOpen, mode == .drag else { return }
        Log.write("wheel: drag ended")
        close(animated: true)
    }

    /// The physical button went up. Normally the drop callbacks handle everything; this covers the
    /// case where the system never routed the drag to the wheel, so the release still does what the
    /// highlighted slot promised.
    func mouseReleased() {
        guard isOpen, mode == .drag else { return }
        let option = currentOption
        let files = context?.files ?? []
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOpen else { return }
            let screen = self.screen
            let reached = self.dragSeen || self.dropped
            self.close(animated: true)
            guard !reached, let option, option.enabled else { return }
            // Finder took the drop instead; only act on files that are still where they were.
            let present = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            Log.write("wheel: drop never reached the wheel → fallback \(option.id) on \(present.count)/\(files.count) file(s)")
            if present.isEmpty {
                SFX.shared.play(.wasted)
                BannerController.shared.show(passed: false, title: option.title, detail: "文件被拖到别的地方了，这次没转换", on: screen)
            } else {
                Runner.shared.run(option, files: present, screen: screen, wanted: self.wanted)
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Click mode

    func clicked(at p: CGPoint) {
        guard isOpen, mode != .drag, let context else { return }
        updateHover(p)
        guard let option = currentOption else {
            close(animated: true)
            return
        }
        guard option.enabled else {
            SFX.shared.play(.denied)
            return
        }
        let screen = self.screen
        close(animated: true)
        if mode == .demo {
            Runner.shared.demo(option, context: context, screen: screen)
        } else {
            Runner.shared.run(option, files: context.files, screen: screen, wanted: wanted)
        }
    }
}
