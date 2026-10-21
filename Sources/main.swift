import AppKit

// Command-line modes exist for testing and for build.sh; with no flags this is the menu bar app.
let arguments = CommandLine.arguments

func flag(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
    return arguments[i + 1]
}

func paths(after name: String) -> [URL] {
    guard let i = arguments.firstIndex(of: name) else { return [] }
    return arguments[(i + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
}

func applyOverrides() {
    if let crew = flag("--crew").flatMap(Crew.init(rawValue:)) { Settings.shared.crew = crew }
    if let size = flag("--size").flatMap(WheelSize.init(rawValue:)) { Settings.shared.wheelSize = size }
}

/// Runs async work from the command line while still servicing the main queue (AppKit work hops there).
func runBlocking(_ work: @escaping () async -> Int32) -> Never {
    _ = NSApplication.shared
    var status: Int32?
    Task.detached {
        let code = await work()
        DispatchQueue.main.async { status = code }
    }
    while status == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    exit(status!)
}

if let out = flag("--snapshot") {
    _ = NSApplication.shared
    applyOverrides()
    let hover = flag("--hover").flatMap(Int.init)
    let page = flag("--page").flatMap(Int.init) ?? 0
    var center: CGPoint?
    if let x = flag("--x").flatMap(Double.init), let y = flag("--y").flatMap(Double.init) { center = CGPoint(x: x, y: y) }
    let files = paths(after: "--files")
    var wanted = files.first.map(Privacy.image) ?? Wanted()
    if let level = flag("--wanted").flatMap(Int.init) {
        wanted = Wanted(level: level, reasons: ["GPS 定位", "iPhone 15 Pro", "拍摄时间"])
    }
    do {
        try Snapshot.wheel(files: files, hover: hover, page: page, background: flag("--bg").map { URL(fileURLWithPath: $0) },
                           out: URL(fileURLWithPath: out), center: center, wanted: wanted)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if let out = flag("--banner") {
    _ = NSApplication.shared
    do {
        try Snapshot.banner(passed: !arguments.contains("--wasted"), title: flag("--title") ?? "IMG_2049.HEIC  →  JPG",
                            detail: flag("--detail") ?? "2.4 MB → 1.1 MB · 已保存在原文件旁边",
                            background: flag("--bg").map { URL(fileURLWithPath: $0) }, out: URL(fileURLWithPath: out))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("banner failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if let out = flag("--icon") {
    _ = NSApplication.shared
    let pixels = flag("--px").flatMap(Int.init) ?? 1024
    let image = Icons.app(pixels: pixels)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    exit(0)
}

if arguments.contains("--list") {
    let context = Catalog.context(for: paths(after: "--list"))
    print("kind: \(context.kind)  headline: \(context.headline)  summary: \(context.summary)")
    for page in context.pages {
        print("[\(page.name)]")
        for (i, slot) in page.slots.enumerated() {
            guard let slot else { print("  \(i): —"); continue }
            print("  \(i): \(slot.id)  \(slot.title)  \(slot.enabled ? "" : "(disabled: \(slot.note ?? ""))")")
        }
    }
    exit(0)
}

if let out = flag("--weapons") {
    // Contact sheet of every weapon silhouette, for checking the art.
    _ = NSApplication.shared
    let columns = 5, cell = CGSize(width: 300, height: 170)
    let rows = (Weapon.allCases.count + columns - 1) / columns
    let sheet = NSView(frame: CGRect(x: 0, y: 0, width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows)))
    final class Sheet: NSView {
        let cell: CGSize, columns: Int
        init(frame: CGRect, cell: CGSize, columns: Int) { self.cell = cell; self.columns = columns; super.init(frame: frame) }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.32, alpha: 1).setFill()
            bounds.fill()
            for (i, weapon) in Weapon.allCases.enumerated() {
                let col = i % columns, row = i / columns
                let origin = CGPoint(x: CGFloat(col) * cell.width, y: bounds.height - CGFloat(row + 1) * cell.height)
                weapon.draw(in: CGRect(x: origin.x + 30, y: origin.y + 50, width: cell.width - 60, height: 90), rim: 2.4)
                Draw.text("\(weapon.title) · \(weapon.rawValue)", TextStyle(font: Fonts.hud(18, .demi)), center: CGPoint(x: origin.x + cell.width / 2, y: origin.y + 24))
            }
        }
    }
    let view = Sheet(frame: sheet.frame, cell: cell, columns: columns)
    do { try Snapshot.write(view, to: URL(fileURLWithPath: out)); exit(0) } catch { exit(1) }
}

if let out = flag("--glyphs") {
    // Contact sheet of the format icons, for checking the art.
    _ = NSApplication.shared
    let sample: [(String, Glyph)] = [
        ("PNG", .png), ("JPG", .jpg), ("HEIC", .heic), ("WEBP", .webp), ("AVIF", .avif), ("GIF", .gif), ("TIFF", .tiff), ("PDF", .pdf),
        ("长图", .longImage), ("DOCX", .word("DOCX")), ("TXT", .text), ("MD", .markdown), ("RTF", .rtf), ("HTML", .html), ("ODT", .odt), ("MP4", .clapper),
        ("MOV", .film), ("HEVC", .filmBadge("H.265")), ("WEBM", .webVideo), ("视频GIF", .loop), ("MP3", .note("MP3", Ink.orange)), ("M4A", .note("M4A", Ink.blue)), ("WAV", .waves), ("FLAC", .wavesBadge("FLAC", Ink.gold)),
        ("OPUS", .voice), ("ALAC", .vinyl), ("铃声", .bell), ("压缩", .compress), ("缩小", .shrink), ("抠图", .cutout), ("识字", .scan), ("黑白", .mono),
        ("旋转", .rotate), ("去隐私", .unpin), ("加背景", .backdrop), ("拆页", .split), ("合并", .merge), ("静音", .mute), ("720P", .screen720), ("封面", .cover),
        ("加速", .fast), ("慢放", .slow), ("单声道", .speaker), ("响度", .meter), ("字数", .counter), ("复制全文", .clipboard), ("ZIP", .zip), ("路径", .link),
        ("文件名", .tag), ("SHA", .fingerprint),
    ]
    final class Sheet: NSView {
        let items: [(String, Glyph)]
        init(frame: CGRect, items: [(String, Glyph)]) { self.items = items; super.init(frame: frame) }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.3, alpha: 1).setFill()
            bounds.fill()
            for (i, item) in items.enumerated() {
                let col = i % 8, row = i / 8
                let origin = CGPoint(x: CGFloat(col) * 150, y: bounds.height - CGFloat(row + 1) * 150)
                item.1.draw(in: CGRect(x: origin.x + 30, y: origin.y + 40, width: 90, height: 90))
                Draw.text(item.0, TextStyle(font: Fonts.hud(17, .demi)), center: CGPoint(x: origin.x + 75, y: origin.y + 20))
            }
        }
    }
    let rows = (sample.count + 7) / 8
    let view = Sheet(frame: CGRect(x: 0, y: 0, width: 1200, height: CGFloat(rows) * 150), items: sample)
    do { try Snapshot.write(view, to: URL(fileURLWithPath: out)); exit(0) } catch { exit(1) }
}

if let folder = flag("--sounds") {
    do { try SFX.shared.export(to: URL(fileURLWithPath: folder)); exit(0) } catch { exit(1) }
}

if arguments.contains("--preview") {
    DistributedNotificationCenter.default().postNotificationName(AppDelegate.previewNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

if arguments.contains("--scan") {
    let files = paths(after: "--scan")
    runBlocking {
        for file in files {
            let found = await Privacy.scan(file)
            print("\(file.lastPathComponent): \(String(repeating: "★", count: found.level))\(String(repeating: "☆", count: 5 - found.level))  \(found.reasons.joined(separator: " · "))")
        }
        return 0
    }
}

if arguments.contains("--ids") {
    print(Catalog.allIDs.joined(separator: "\n"))
    exit(0)
}

if let id = flag("--run") {
    let files = Array(paths(after: "--run").dropFirst())
    runBlocking {
        do {
            let started = Date()
            let summary = try await Engine.run(id, label: id, files: files) { _ in }
            let seconds = String(format: "%.2fs", Date().timeIntervalSince(started))
            print("OK \(id) [\(seconds)] \(summary.detail)")
            for out in summary.outputs { print("   -> \(out.path)") }
            return 0
        } catch {
            print("FAIL \(id): \(error.localizedDescription)")
            return 1
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
