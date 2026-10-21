import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Icons.menuBar()
        statusItem.button?.toolTip = "格式轮盘：拖着文件按 ⇧ Shift"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watcher.onShift = { files in
            Overlay.shared.open(files: files, mode: .drag, at: NSEvent.mouseLocation)
        }
        watcher.onRelease = { Overlay.shared.mouseReleased() }
        watcher.isWheelOpen = { Overlay.shared.isOpen }
        watcher.start()
        Overlay.shared.prepare()

        if !Settings.shared.welcomed {
            Settings.shared.welcomed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showDemo() }
        }

        // `FormatWheel --preview` (another process) asks this instance to flash the demo wheel.
        DistributedNotificationCenter.default().addObserver(forName: Self.previewNotification, object: nil, queue: .main) { [weak self] _ in
            self?.showDemo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if Overlay.shared.isOpen { Overlay.shared.close(animated: true) }
            }
        }
    }

    static let previewNotification = Notification.Name("com.formatwheel.preview")

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("格式轮盘"))
        menu.addItem(disabled("拖着文件按 ⇧ Shift 呼出轮盘"))
        menu.addItem(.separator())
        menu.addItem(item("看看效果（演示）", #selector(showDemo)))
        menu.addItem(item("选择文件打开轮盘…", #selector(chooseFiles)))
        menu.addItem(.separator())

        let recent = Recents.shared.items
        let recentMenu = NSMenu()
        for url in recent {
            let folder = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
            let entry = item("\(url.lastPathComponent)  —  \(folder)", #selector(revealRecent(_:)))
            entry.representedObject = url
            entry.isEnabled = FileManager.default.fileExists(atPath: url.path)
            entry.image = NSWorkspace.shared.icon(forFile: url.path)
            entry.image?.size = NSSize(width: 16, height: 16)
            recentMenu.addItem(entry)
        }
        if recent.isEmpty { recentMenu.addItem(disabled("还没有转换过文件")) }
        let recentItem = submenu("最近转换（点击在 Finder 中显示）", recentMenu)
        menu.addItem(recentItem)
        menu.addItem(.separator())

        let crewMenu = NSMenu()
        for crew in Crew.allCases {
            let entry = item(crew.title, #selector(pickCrew(_:)))
            entry.representedObject = crew.rawValue
            entry.state = Settings.shared.crew == crew ? .on : .off
            entry.image = swatch(crew.color)
            crewMenu.addItem(entry)
        }
        menu.addItem(submenu("角色配色", crewMenu))

        let iconMenu = NSMenu()
        for style in IconStyle.allCases {
            let entry = item(style.title, #selector(pickIconStyle(_:)))
            entry.representedObject = style.rawValue
            entry.state = Settings.shared.iconStyle == style ? .on : .off
            iconMenu.addItem(entry)
        }
        menu.addItem(submenu("格子图标", iconMenu))

        let sizeMenu = NSMenu()
        for size in WheelSize.allCases {
            let entry = item(size.title, #selector(pickSize(_:)))
            entry.representedObject = size.rawValue
            entry.state = Settings.shared.wheelSize == size ? .on : .off
            sizeMenu.addItem(entry)
        }
        menu.addItem(submenu("轮盘大小", sizeMenu))

        menu.addItem(toggle("音效", Settings.shared.sound, #selector(toggleSound)))
        menu.addItem(toggle("背景虚化", Settings.shared.blur, #selector(toggleBlur)))
        menu.addItem(toggle("完成横幅（MISSION PASSED）", Settings.shared.banner, #selector(toggleBanner)))
        menu.addItem(toggle("登录时自动启动", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(.separator())
        menu.addItem(disabled(toolStatus()))
        menu.addItem(.separator())
        menu.addItem(item("退出格式轮盘", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let entry = item(title, action)
        entry.state = on ? .on : .off
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func toolStatus() -> String {
        let missing = ["ffmpeg", "cwebp"].filter { !Shell.has($0) }
        if missing.isEmpty { return "弹药充足：ffmpeg ✓  cwebp ✓" }
        return "未装备：" + missing.joined(separator: "、") + "（brew install 后解锁更多格式）"
    }

    // MARK: - Actions

    @objc func showDemo() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let sample = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/IMG_2049.HEIC")
        var context = Catalog.context(for: [sample])
        context.headline = "IMG_2049.HEIC"
        context.summary = "2.4 MB · 4032×3024 · HEIC"
        let center = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        Overlay.shared.open(files: [sample], mode: .demo, at: center, context: context)
    }

    @objc func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "打开轮盘"
        panel.message = "选好文件后，用鼠标点轮盘上的格子"
        guard panel.runModal() == .OK, !panel.urls.isEmpty, let screen = NSScreen.main else { return }
        Overlay.shared.open(files: panel.urls, mode: .click, at: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
    }

    @objc func pickCrew(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let crew = Crew(rawValue: raw) else { return }
        Settings.shared.crew = crew
        showDemo()
    }

    @objc func pickIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = IconStyle(rawValue: raw) else { return }
        Settings.shared.iconStyle = style
        showDemo()
    }

    @objc func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = WheelSize(rawValue: raw) else { return }
        Settings.shared.wheelSize = size
        showDemo()
    }

    @objc func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func toggleSound() { Settings.shared.sound.toggle() }
    @objc func toggleBlur() { Settings.shared.blur.toggle() }
    @objc func toggleBanner() { Settings.shared.banner.toggle() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "没能设置自动启动"
            alert.informativeText = "\(error.localizedDescription)\n\n可以在「系统设置 → 通用 → 登录项」里手动添加格式轮盘。"
            alert.runModal()
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

enum Icons {
    /// Menu bar glyph: a little eight-slot wheel with the top slot lit.
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: 9, y: 9)
            let step = CGFloat.pi / 4
            for i in 0..<8 {
                let t = CGFloat(i) * step
                cg.addPath(Geo.sector(center: c, r0: 4.3, r1: 8.3, from: t - step / 2 + 0.1, to: t + step / 2 - 0.1))
                cg.setFillColor(NSColor.black.withAlphaComponent(i == 0 ? 1 : 0.5).cgColor)
                cg.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// App icon artwork (rendered by `--icon`, packed into AppIcon.icns by build.sh).
    static func app(pixels: Int) -> NSImage {
        let side = CGFloat(pixels)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let s = side / 1024
            let tile = rect.insetBy(dx: 100 * s, dy: 100 * s)
            let shape = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor(white: 0, alpha: 0.45).cgColor)
            cg.addPath(shape)
            cg.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
            cg.fillPath()
            cg.restoreGState()

            cg.saveGState()
            cg.addPath(shape)
            cg.clip()
            let bg = CGGradient(colorsSpace: nil, colors: [
                NSColor(srgbRed: 0.97, green: 0.52, blue: 0.30, alpha: 1).cgColor,
                NSColor(srgbRed: 0.62, green: 0.22, blue: 0.45, alpha: 1).cgColor,
                NSColor(srgbRed: 0.12, green: 0.10, blue: 0.22, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 0.5, 1])!
            cg.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
            cg.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
            cg.fill(tile)

            let c = CGPoint(x: rect.midX, y: rect.midY)
            let R = 330 * s, r = 198 * s
            let step = CGFloat.pi / 4
            for i in 0..<8 {
                let t = CGFloat(i) * step
                let sector = Geo.sector(center: c, r0: r, r1: R, from: t - step / 2, to: t + step / 2)
                cg.saveGState()
                cg.addPath(sector)
                cg.clip()
                if i == 0 {
                    let lit = CGGradient(colorsSpace: nil, colors: [
                        NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 0.85).cgColor,
                        NSColor(srgbRed: 0.20, green: 0.50, blue: 0.90, alpha: 1).cgColor,
                    ] as CFArray, locations: [0, 1])!
                    cg.drawRadialGradient(lit, startCenter: c, startRadius: r, endCenter: c, endRadius: R, options: [])
                } else {
                    cg.setFillColor(NSColor(white: 0.16, alpha: 0.82).cgColor)
                    cg.fill(rect)
                }
                cg.restoreGState()
            }
            cg.addPath(Geo.arc(center: c, radius: R - 11 * s, from: -step / 2 + 0.01, to: step / 2 - 0.01))
            cg.setStrokeColor(NSColor(srgbRed: 0.20, green: 0.50, blue: 0.90, alpha: 1).cgColor)
            cg.setLineWidth(22 * s)
            cg.strokePath()
            cg.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
            cg.setLineWidth(7 * s)
            for i in 0..<8 {
                let t = CGFloat(i) * step + step / 2
                cg.move(to: Geo.point(c, r, t))
                cg.addLine(to: Geo.point(c, R, t))
            }
            cg.strokePath()
            cg.restoreGState()

            let label = TextStyle(font: Fonts.badge(150 * s), outline: 9 * s, shadow: 0)
            Draw.text("⇧", label, center: CGPoint(x: c.x, y: c.y - 6 * s))
            for (i, name) in ["PNG", "JPG", "MP4", "PDF"].enumerated() {
                let t = CGFloat(i * 2) * step
                Draw.text(name, TextStyle(font: Fonts.badge(64 * s), outline: 7 * s, shadow: 0), center: Geo.point(c, (r + R) / 2, t))
            }
            return true
        }
    }
}
