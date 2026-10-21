import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FileKind: String {
    case image, pdf, video, audio, document, other

    var title: String {
        switch self {
        case .image: return "图片"
        case .pdf: return "PDF"
        case .video: return "视频"
        case .audio: return "音频"
        case .document: return "文档"
        case .other: return "文件"
        }
    }

    static let documentExts: Set<String> = ["txt", "text", "md", "markdown", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "wordml", "webarchive"]
    static let extraVideoExts: Set<String> = ["webm", "mkv", "flv", "avi", "wmv", "ts", "m2ts", "mts", "3gp", "ogv"]
    static let extraAudioExts: Set<String> = ["opus", "ogg", "oga", "wma", "ape", "amr", "flac"]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return ext == "rtfd" ? .document : .other
        }
        if ext == "pdf" { return .pdf }
        if documentExts.contains(ext) { return .document }
        if extraVideoExts.contains(ext) { return .video }
        if extraAudioExts.contains(ext) { return .audio }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image), ImageSupport.readable.contains(type.identifier) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }
}

enum ImageSupport {
    static let readable: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
}

/// One slot on the wheel.
struct WheelOption {
    let id: String
    /// Big label drawn in the slot (format name); `symbol` is used when this is nil.
    var big: String?
    var symbol: String?
    /// Small caption under the icon — the slot's "ammo count".
    var ammo: String
    var title: String
    var detail: String
    var enabled = true
    /// Why the slot is unavailable.
    var note: String?
    /// Stat bar values (0...1) after the action, compared with the source's.
    var stats: [Double]?
}

struct WheelPage {
    let name: String
    var slots: [WheelOption?]
}

struct WheelContext {
    let files: [URL]
    let kind: FileKind
    var pages: [WheelPage]
    var headline: String
    var summary: String
    let statLabels: [String]
    let base: [Double]
}

enum Catalog {
    static func context(for files: [URL]) -> WheelContext {
        let kinds = files.map(FileKind.of)
        // The wheel follows the most common kind among the dragged files.
        var tally: [FileKind: Int] = [:]
        for k in kinds { tally[k, default: 0] += 1 }
        let kind = files.count == 0 ? .other : (tally.max { $0.value < $1.value }?.key ?? .other)
        let sameKind = files.filter { FileKind.of($0) == kind }
        let exts = Set(sameKind.map { canonicalExt($0.pathExtension) })
        let currentExt: String? = exts.count == 1 ? exts.first : nil

        var pages: [WheelPage]
        var labels: [String] = []
        var base: [Double] = []
        switch kind {
        case .image:
            labels = ["画质", "压缩率", "兼容性", "透明"]
            base = imageTraits[currentExt ?? ""] ?? imageTraits["other"]!
            pages = [imageConvert(current: currentExt, count: sameKind.count), imageTools(base: base, count: sameKind.count)]
        case .pdf:
            labels = ["版式还原", "可编辑", "体积小", "兼容性"]
            base = pdfTraits["pdf"]!
            pages = [pdfConvert(), pdfTools(base: base, count: sameKind.count)]
        case .video:
            labels = ["画质", "压缩率", "兼容性"]
            base = videoTraits[currentExt ?? ""] ?? videoTraits["other"]!
            pages = [videoConvert(current: currentExt), videoTools(base: base)]
        case .audio:
            labels = ["音质", "压缩率", "兼容性"]
            base = audioTraits[currentExt ?? ""] ?? audioTraits["other"]!
            pages = [audioConvert(current: currentExt), audioTools(base: base)]
        case .document:
            labels = ["排版还原", "可编辑", "兼容性"]
            base = docTraits[currentExt ?? ""] ?? docTraits["other"]!
            pages = [docConvert(current: currentExt), docTools(word: exts == ["docx"])]
        case .other:
            pages = [genericPage(files: files)]
        }

        let headline: String
        let summary: String
        if files.count == 1, let f = files.first {
            headline = f.lastPathComponent
            summary = describe(f, kind: kind)
        } else {
            headline = "\(files.count) 个文件"
            let total = files.reduce(Int64(0)) { $0 + Fmt.size(of: $1) }
            let skipped = files.count - sameKind.count
            summary = Fmt.bytes(total) + " · " + kind.title + (skipped > 0 ? " · 另有 \(skipped) 个会跳过" : "")
        }
        return WheelContext(files: files, kind: kind, pages: pages, headline: headline, summary: summary, statLabels: labels, base: base)
    }

    /// Every option id the engine understands, for `--run` and tests.
    static var allIDs: [String] {
        let sample: [[WheelPage]] = [
            [imageConvert(current: nil, count: 1), imageTools(base: imageTraits["png"]!, count: 1)],
            [pdfConvert(), pdfTools(base: pdfTraits["pdf"]!, count: 2)],
            [videoConvert(current: nil), videoTools(base: videoTraits["mp4"]!)],
            [audioConvert(current: nil), audioTools(base: audioTraits["mp3"]!)],
            [docConvert(current: nil), docTools(word: true)],
            [genericPage(files: [])],
        ]
        var seen = Set<String>()
        return sample.flatMap { $0 }.flatMap { $0.slots }.compactMap { $0?.id }.filter { seen.insert($0).inserted }
    }

    static func canonicalExt(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "htm": return "html"
        case "markdown": return "md"
        case "aif", "aifc": return "aiff"
        case "oga", "ogg": return "opus"
        default: return ext.lowercased()
        }
    }

    private static func describe(_ url: URL, kind: FileKind) -> String {
        var parts = [Fmt.bytes(Fmt.size(of: url))]
        if kind == .image, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            parts.append("\(w)×\(h)")
        }
        let ext = url.pathExtension.uppercased()
        parts.append(ext.isEmpty ? kind.title : ext)
        return parts.joined(separator: " · ")
    }

    // MARK: - Stats tables

    static let imageTraits: [String: [Double]] = [
        "png": [1.00, 0.35, 1.00, 1.00],
        "jpg": [0.74, 0.78, 1.00, 0.00],
        "heic": [0.84, 0.90, 0.55, 1.00],
        "webp": [0.80, 0.86, 0.82, 1.00],
        "avif": [0.86, 0.95, 0.60, 0.00],
        "pdf": [1.00, 0.40, 0.95, 1.00],
        "gif": [0.30, 0.55, 1.00, 0.50],
        "tiff": [1.00, 0.20, 0.70, 1.00],
        "bmp": [1.00, 0.05, 0.85, 0.00],
        "other": [0.92, 0.30, 0.45, 0.50],
    ]

    static let pdfTraits: [String: [Double]] = [
        "pdf": [1.00, 0.15, 0.60, 0.95],
        "png": [0.95, 0.00, 0.40, 1.00],
        "jpg": [0.88, 0.00, 0.72, 1.00],
        "long": [0.90, 0.00, 0.62, 1.00],
        "docx": [0.55, 0.95, 0.70, 0.90],
        "txt": [0.08, 1.00, 1.00, 1.00],
        "md": [0.35, 1.00, 0.95, 0.80],
        "rtf": [0.50, 0.90, 0.60, 0.75],
        "html": [0.45, 0.80, 0.75, 0.95],
    ]

    static let videoTraits: [String: [Double]] = [
        "mp4": [0.85, 0.70, 1.00],
        "m4v": [0.85, 0.70, 0.90],
        "mov": [0.95, 0.45, 0.75],
        "hevc": [0.90, 0.88, 0.70],
        "webm": [0.82, 0.85, 0.70],
        "mkv": [0.90, 0.72, 0.50],
        "avi": [0.70, 0.40, 0.55],
        "gif": [0.20, 0.10, 1.00],
        "mp3": [0.00, 0.97, 1.00],
        "m4a": [0.00, 0.96, 0.92],
        "wav": [0.00, 0.80, 0.95],
        "other": [0.80, 0.60, 0.50],
    ]

    static let audioTraits: [String: [Double]] = [
        "mp3": [0.70, 0.80, 1.00],
        "m4a": [0.80, 0.82, 0.92],
        "aac": [0.78, 0.82, 0.85],
        "wav": [1.00, 0.00, 0.95],
        "aiff": [1.00, 0.00, 0.70],
        "flac": [1.00, 0.50, 0.65],
        "opus": [0.82, 0.92, 0.55],
        "alac": [1.00, 0.45, 0.70],
        "m4r": [0.80, 0.82, 0.40],
        "caf": [0.95, 0.30, 0.40],
        "other": [0.75, 0.60, 0.50],
    ]

    static let docTraits: [String: [Double]] = [
        "pdf": [1.00, 0.15, 1.00],
        "docx": [0.85, 1.00, 0.95],
        "doc": [0.75, 0.90, 0.85],
        "txt": [0.10, 1.00, 1.00],
        "md": [0.40, 1.00, 0.75],
        "html": [0.70, 0.80, 0.95],
        "rtf": [0.75, 0.90, 0.80],
        "rtfd": [0.80, 0.90, 0.60],
        "odt": [0.80, 0.95, 0.60],
        "other": [0.60, 0.80, 0.60],
    ]

    private static func adjusted(_ base: [Double], _ changes: [Int: (Double) -> Double]) -> [Double] {
        base.enumerated().map { i, v in min(1, max(0, changes[i]?(v) ?? v)) }
    }

    // MARK: - Pages

    private static func format(_ id: String, _ key: String, big: String, ammo: String, title: String, detail: String,
                               current: String?, traits: [String: [Double]], aliases: Set<String> = [],
                               requires tool: String? = nil) -> WheelOption {
        var o = WheelOption(id: id, big: big, ammo: ammo, title: title, detail: detail, stats: traits[key])
        if let current, current == key || aliases.contains(current) {
            o.enabled = false
            o.ammo = "当前"
            o.note = "已经是 \(big) 了"
        } else if let tool, !Shell.has(tool) {
            o.enabled = false
            o.ammo = "未装备"
            o.note = Shell.installHint(tool)
        }
        return o
    }

    private static func imageConvert(current: String?, count: Int) -> WheelPage {
        let t = imageTraits
        var pdf = format("img.to.pdf", "pdf", big: "PDF", ammo: "文档", title: "PDF", detail: "一张图一页，方便发送和打印", current: nil, traits: t)
        if count > 1 {
            pdf.title = "合并成 PDF"
            pdf.detail = "\(count) 张图按顺序合成一个 PDF"
            pdf.ammo = "合并"
        }
        return WheelPage(name: "格式转换", slots: [
            format("img.to.png", "png", big: "PNG", ammo: "无损", title: "PNG", detail: "无损画质，支持透明背景", current: current, traits: t),
            format("img.to.jpg", "jpg", big: "JPG", ammo: "通用", title: "JPG", detail: "到哪都能打开，体积适中", current: current, traits: t),
            format("img.to.heic", "heic", big: "HEIC", ammo: "苹果", title: "HEIC", detail: "苹果相册格式，小而清晰", current: current, traits: t),
            format("img.to.webp", "webp", big: "WEBP", ammo: "网页", title: "WebP", detail: "网页常用，小体积高画质", current: current, traits: t, requires: "cwebp"),
            pdf,
            format("img.to.avif", "avif", big: "AVIF", ammo: "极小", title: "AVIF", detail: "新一代格式，体积最小（不保留透明）", current: current, traits: t, requires: "ffmpeg"),
            format("img.to.gif", "gif", big: "GIF", ammo: "256色", title: "GIF", detail: "老牌格式，只有 256 种颜色", current: current, traits: t),
            format("img.to.tiff", "tiff", big: "TIFF", ammo: "印刷", title: "TIFF", detail: "无损大文件，适合印刷和存档", current: current, traits: t),
        ])
    }

    private static func imageTools(base: [Double], count: Int) -> WheelPage {
        WheelPage(name: "工具", slots: [
            WheelOption(id: "img.compress", symbol: "arrow.down.right.and.arrow.up.left", ammo: "压缩", title: "压缩",
                        detail: "肉眼几乎看不出差别，体积大幅缩小", stats: adjusted(base, [0: { $0 * 0.9 }, 1: { $0 + 0.35 }])),
            WheelOption(id: "img.half", symbol: "minus.magnifyingglass", ammo: "缩小一半", title: "缩小一半",
                        detail: "长宽各减半，体积约剩四分之一", stats: adjusted(base, [0: { $0 * 0.7 }, 1: { $0 + 0.3 }])),
            WheelOption(id: "img.cutout", symbol: "scissors", ammo: "抠图", title: "抠图",
                        detail: "自动识别主体，去掉背景，导出透明 PNG", stats: adjusted(base, [3: { _ in 1 }])),
            WheelOption(id: "img.ocr", symbol: "text.viewfinder", ammo: "识字", title: "识字",
                        detail: "认出图里的文字，直接复制到剪贴板"),
            WheelOption(id: "img.mono", symbol: "circle.lefthalf.filled", ammo: "黑白", title: "黑白",
                        detail: "一键变成黑白照片"),
            WheelOption(id: "img.rotate", symbol: "rotate.right", ammo: "旋转", title: "旋转",
                        detail: "顺时针转 90°"),
            WheelOption(id: "img.strip", symbol: "location.slash", ammo: "去隐私", title: "去隐私",
                        detail: "抹掉 GPS 位置和拍摄信息，发图更安心"),
            WheelOption(id: "img.backdrop", symbol: "photo.artframe", ammo: "加背景", title: "加背景",
                        detail: "加渐变背景、圆角和阴影，截图秒变精致"),
        ])
    }

    private static func pdfConvert() -> WheelPage {
        let t = pdfTraits
        func o(_ id: String, _ key: String, _ big: String, _ ammo: String, _ title: String, _ detail: String) -> WheelOption {
            WheelOption(id: id, big: big, ammo: ammo, title: title, detail: detail, stats: t[key])
        }
        return WheelPage(name: "格式转换", slots: [
            o("pdf.to.png", "png", "PNG", "每页一张", "PNG 图片", "每页导出一张清晰图片"),
            o("pdf.to.jpg", "jpg", "JPG", "每页一张", "JPG 图片", "每页一张，体积更小"),
            o("pdf.to.long", "long", "长图", "拼接", "长图", "所有页面拼成一张长图，方便发朋友圈"),
            o("pdf.to.docx", "docx", "DOCX", "Word", "Word 文档", "提取文字和格式，可以继续编辑"),
            o("pdf.to.txt", "txt", "TXT", "纯文字", "纯文本", "只要文字，最干净"),
            o("pdf.to.md", "md", "MD", "Markdown", "Markdown", "带标题层级的纯文本，适合喂给 AI"),
            o("pdf.to.rtf", "rtf", "RTF", "富文本", "RTF", "保留基本格式的文本"),
            o("pdf.to.html", "html", "HTML", "网页", "HTML 网页", "转成网页，浏览器直接打开"),
        ])
    }

    private static func pdfTools(base: [Double], count: Int) -> WheelPage {
        var merge = WheelOption(id: "pdf.merge", symbol: "square.stack.3d.down.right", ammo: "合并", title: "合并",
                                detail: "把拖进来的 \(count) 个 PDF 按顺序合成一个")
        if count < 2 {
            merge.enabled = false
            merge.note = "同时拖 2 个以上 PDF 才能合并"
        }
        return WheelPage(name: "工具", slots: [
            WheelOption(id: "pdf.compress", symbol: "arrow.down.right.and.arrow.up.left", ammo: "压缩", title: "压缩",
                        detail: "压缩里面的图片，体积变小", stats: adjusted(base, [0: { $0 * 0.92 }, 2: { $0 + 0.3 }])),
            WheelOption(id: "pdf.split", symbol: "scissors", ammo: "拆页", title: "拆页", detail: "每一页拆成单独的 PDF"),
            merge,
            WheelOption(id: "pdf.rotate", symbol: "rotate.right", ammo: "旋转", title: "旋转", detail: "所有页面顺时针转 90°"),
            WheelOption(id: "pdf.mono", symbol: "circle.lefthalf.filled", ammo: "黑白", title: "黑白", detail: "转成灰度，打印省彩墨"),
            WheelOption(id: "pdf.ocr", symbol: "text.viewfinder", ammo: "识字", title: "识字", detail: "扫描件也能认出文字，复制到剪贴板"),
            strip("pdf.strip", detail: "抹掉作者、制作软件和创建时间，甩掉警察"),
            zipOption,
        ])
    }

    /// 去隐私: clears the wanted level (location, device, author…).
    static func strip(_ id: String, detail: String) -> WheelOption {
        WheelOption(id: id, symbol: "location.slash", ammo: "去隐私", title: "去隐私", detail: detail)
    }

    private static func videoConvert(current: String?) -> WheelPage {
        let t = videoTraits
        return WheelPage(name: "格式转换", slots: [
            format("vid.to.mp4", "mp4", big: "MP4", ammo: "通用", title: "MP4", detail: "最通用的视频格式", current: current, traits: t, aliases: ["m4v"]),
            format("vid.to.mov", "mov", big: "MOV", ammo: "苹果", title: "MOV", detail: "苹果剪辑软件最爱", current: current, traits: t),
            format("vid.to.hevc", "hevc", big: "HEVC", ammo: "H.265", title: "HEVC / H.265", detail: "画质不变，体积约减半", current: nil, traits: t),
            format("vid.to.webm", "webm", big: "WEBM", ammo: "网页", title: "WebM", detail: "网页播放用的开源格式", current: current, traits: t, requires: "ffmpeg"),
            format("vid.to.gif", "gif", big: "GIF", ammo: "动图", title: "GIF 动图", detail: "转成动图（最多取前 30 秒）", current: current, traits: t),
            format("vid.to.mp3", "mp3", big: "MP3", ammo: "提取音频", title: "MP3 音频", detail: "只要声音，最通用", current: nil, traits: t, requires: "ffmpeg"),
            format("vid.to.m4a", "m4a", big: "M4A", ammo: "提取音频", title: "M4A 音频", detail: "只要声音，苹果设备友好", current: nil, traits: t),
            format("vid.to.wav", "wav", big: "WAV", ammo: "无损音频", title: "WAV 音频", detail: "只要声音，无损大文件", current: nil, traits: t, requires: "ffmpeg"),
        ])
    }

    private static func videoTools(base: [Double]) -> WheelPage {
        let hasFFmpeg = Shell.has("ffmpeg")
        var fast = WheelOption(id: "vid.fast", big: "2×", ammo: "加速", title: "2 倍速", detail: "整体加速一倍，声音同步变快")
        var slow = WheelOption(id: "vid.slow", symbol: "tortoise.fill", ammo: "慢放", title: "慢放", detail: "0.5 倍速，就像开了子弹时间")
        let compress = WheelOption(id: "vid.compress", symbol: "arrow.down.right.and.arrow.up.left", ammo: "压缩", title: "压缩",
                                   detail: hasFFmpeg ? "1080P 以内，体积通常小一半以上" : "缩到 720P，体积变小",
                                   stats: adjusted(base, [0: { $0 * 0.88 }, 1: { $0 + 0.3 }, 2: { _ in 1 }]))
        if !hasFFmpeg {
            fast.enabled = false; fast.ammo = "未装备"; fast.note = Shell.installHint("ffmpeg")
            slow.enabled = false; slow.ammo = "未装备"; slow.note = Shell.installHint("ffmpeg")
        }
        return WheelPage(name: "工具", slots: [
            compress,
            WheelOption(id: "vid.mute", symbol: "speaker.slash.fill", ammo: "静音", title: "静音", detail: "去掉声音，画面不动"),
            WheelOption(id: "vid.720p", big: "720P", ammo: "降分辨率", title: "720P", detail: "缩到 720P，发消息更快",
                        stats: adjusted(base, [0: { min($0, 0.6) }, 1: { $0 + 0.25 }])),
            WheelOption(id: "vid.cover", symbol: "photo", ammo: "封面", title: "截封面", detail: "截取一帧存成 JPG"),
            fast, slow,
            strip("vid.strip", detail: "抹掉拍摄地点、机型和时间，不重新压缩"),
            zipOption,
        ])
    }

    private static func audioConvert(current: String?) -> WheelPage {
        let t = audioTraits
        return WheelPage(name: "格式转换", slots: [
            format("aud.to.mp3", "mp3", big: "MP3", ammo: "通用", title: "MP3", detail: "最通用的音频格式", current: current, traits: t, requires: "ffmpeg"),
            format("aud.to.m4a", "m4a", big: "M4A", ammo: "AAC", title: "M4A", detail: "苹果默认，同体积音质更好", current: current, traits: t, aliases: ["aac"]),
            format("aud.to.wav", "wav", big: "WAV", ammo: "无损", title: "WAV", detail: "无损大文件，剪辑常用", current: current, traits: t),
            format("aud.to.flac", "flac", big: "FLAC", ammo: "无损压缩", title: "FLAC", detail: "无损，体积约为 WAV 的一半", current: current, traits: t),
            format("aud.to.aiff", "aiff", big: "AIFF", ammo: "苹果无损", title: "AIFF", detail: "苹果的无损格式", current: current, traits: t),
            format("aud.to.opus", "opus", big: "OPUS", ammo: "极小", title: "Opus", detail: "体积极小，人声特别清晰", current: current, traits: t, requires: "ffmpeg"),
            format("aud.to.alac", "alac", big: "ALAC", ammo: "苹果无损", title: "ALAC", detail: "苹果无损压缩，音乐 App 直接播", current: nil, traits: t),
            WheelOption(id: "aud.to.m4r", symbol: "bell.fill", ammo: "铃声", title: "iPhone 铃声", detail: "截取前 40 秒，做成 iPhone 铃声", stats: t["m4r"]),
        ])
    }

    private static func audioTools(base: [Double]) -> WheelPage {
        var slots: [WheelOption?] = [
            WheelOption(id: "aud.compress", symbol: "arrow.down.right.and.arrow.up.left", ammo: "压缩", title: "压缩",
                        detail: "转成 96 kbps AAC，体积极小", stats: adjusted(base, [0: { $0 * 0.8 }, 1: { _ in 0.95 }])),
            WheelOption(id: "aud.mono", symbol: "speaker.wave.1.fill", ammo: "单声道", title: "单声道", detail: "左右声道合成一个"),
            WheelOption(id: "aud.loud", symbol: "speaker.wave.3.fill", ammo: "响度统一", title: "响度统一", detail: "音量拉到标准响度，不再忽大忽小"),
            WheelOption(id: "aud.fast", big: "1.5×", ammo: "加速", title: "1.5 倍速", detail: "整体加速，听播客更快"),
            nil, nil, zipOption, pathOption,
        ]
        if !Shell.has("ffmpeg") {
            for i in 1...3 {
                slots[i]?.enabled = false
                slots[i]?.ammo = "未装备"
                slots[i]?.note = Shell.installHint("ffmpeg")
            }
        }
        return WheelPage(name: "工具", slots: slots)
    }

    private static func docConvert(current: String?) -> WheelPage {
        let t = docTraits
        return WheelPage(name: "格式转换", slots: [
            format("doc.to.pdf", "pdf", big: "PDF", ammo: "打印", title: "PDF", detail: "排版固定，发给谁看都一样", current: current, traits: t),
            format("doc.to.docx", "docx", big: "DOCX", ammo: "Word", title: "Word 文档", detail: "最常见的可编辑文档", current: current, traits: t),
            format("doc.to.txt", "txt", big: "TXT", ammo: "纯文字", title: "纯文本", detail: "只要文字，最干净", current: current, traits: t),
            format("doc.to.md", "md", big: "MD", ammo: "Markdown", title: "Markdown", detail: "带标题层级的纯文本，适合喂给 AI", current: current, traits: t),
            format("doc.to.html", "html", big: "HTML", ammo: "网页", title: "HTML 网页", detail: "浏览器直接打开", current: current, traits: t),
            format("doc.to.rtf", "rtf", big: "RTF", ammo: "富文本", title: "RTF", detail: "保留基本格式的文本", current: current, traits: t),
            format("doc.to.odt", "odt", big: "ODT", ammo: "开源", title: "ODT", detail: "LibreOffice / WPS 的开放格式", current: current, traits: t),
            format("doc.to.doc", "doc", big: "DOC", ammo: "旧版", title: "旧版 Word", detail: "兼容老版本 Office", current: current, traits: t),
        ])
    }

    private static func docTools(word: Bool) -> WheelPage {
        var lieLow = strip("doc.strip", detail: "抹掉作者、修改人和公司名")
        if !word {
            lieLow.enabled = false
            lieLow.note = "只有 Word（.docx）文档会带作者信息"
        }
        return WheelPage(name: "工具", slots: [
            WheelOption(id: "doc.count", symbol: "textformat.123", ammo: "字数", title: "字数统计", detail: "数一数一共多少字"),
            nil,
            WheelOption(id: "doc.copy", symbol: "doc.on.clipboard", ammo: "复制全文", title: "复制全文", detail: "把文字全部复制到剪贴板"),
            nil, lieLow, nil, zipOption, pathOption,
        ])
    }

    static let zipOption = WheelOption(id: "gen.zip", symbol: "doc.zipper", ammo: "压缩包", title: "打包 ZIP", detail: "打包成 .zip 压缩包")
    static let pathOption = WheelOption(id: "gen.path", symbol: "link", ammo: "复制路径", title: "复制路径", detail: "把文件路径复制到剪贴板")

    private static func genericPage(files: [URL]) -> WheelPage {
        var sha = WheelOption(id: "gen.sha", symbol: "number", ammo: "SHA-256", title: "SHA-256", detail: "算出校验值并复制")
        if files.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
            sha.enabled = false
            sha.note = "文件夹算不了校验值"
        }
        return WheelPage(name: "通用", slots: [
            zipOption, nil,
            pathOption, nil,
            WheelOption(id: "gen.name", symbol: "character.cursor.ibeam", ammo: "复制文件名", title: "复制文件名", detail: "把文件名复制到剪贴板"),
            nil,
            sha, nil,
        ])
    }
}
