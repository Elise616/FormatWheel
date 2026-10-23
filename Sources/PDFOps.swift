import AppKit
import PDFKit
import Quartz

enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw FWError("打不开这个 PDF") }
        if doc.isLocked { throw FWError("这个 PDF 有密码保护") }
        return doc
    }

    static func pages(_ url: URL) throws -> CGPDFDocument {
        guard let doc = CGPDFDocument(url as CFURL) else { throw FWError("打不开这个 PDF") }
        if doc.isEncrypted && !doc.isUnlocked { throw FWError("这个 PDF 有密码保护") }
        guard doc.numberOfPages > 0 else { throw FWError("PDF 里没有页面") }
        return doc
    }

    /// Size of a page as displayed, i.e. after its /Rotate.
    static func displaySize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    static func render(_ page: CGPDFPage, scale: CGFloat) -> CGImage? {
        let size = displaySize(page)
        var s = scale
        let maxPixels: CGFloat = 60_000_000
        if size.width * s * size.height * s > maxPixels { s = sqrt(maxPixels / (size.width * size.height)) }
        let w = max(1, Int(size.width * s)), h = max(1, Int(size.height * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    static func toImages(_ url: URL, fmt: String, progress: ProgressFn) async throws -> OpResult {
        let doc = try pages(url)
        let count = doc.numberOfPages
        let quality: Double? = fmt == "jpg" ? 0.9 : nil
        if count == 1 {
            guard let page = doc.page(at: 1), let image = render(page, scale: 2) else { throw FWError("页面渲染失败") }
            let out = try Out.url(for: url, ext: fmt)
            try await ImageOps.write(image, to: out, fmt: fmt, quality: quality)
            return OpResult(outputs: [out])
        }
        let folder = try Out.folder(for: url, suffix: fmt.uppercased())
        let base = url.deletingPathExtension().lastPathComponent
        let digits = max(2, String(count).count)
        for i in 1...count {
            guard let page = doc.page(at: i), let image = render(page, scale: 2) else { continue }
            let number = String(repeating: "0", count: max(0, digits - String(i).count)) + String(i)
            try await ImageOps.write(image, to: folder.appendingPathComponent("\(base)-\(number).\(fmt)"), fmt: fmt, quality: quality)
            progress(Double(i) / Double(count))
        }
        return OpResult(outputs: [folder], note: "\(count) 页 → 文件夹")
    }

    /// Every page stacked into one tall JPG (split into parts past JPEG's height limit).
    static func longImage(_ url: URL, progress: ProgressFn) async throws -> OpResult {
        let doc = try pages(url)
        let count = min(doc.numberOfPages, 120)
        let width = 1242
        let gap = 16
        var rendered: [CGImage] = []
        for i in 1...count {
            guard let page = doc.page(at: i) else { continue }
            let size = displaySize(page)
            if let image = render(page, scale: CGFloat(width) / size.width) { rendered.append(image) }
            progress(Double(i) / Double(count) * 0.8)
        }
        guard !rendered.isEmpty else { throw FWError("页面渲染失败") }

        var parts: [[CGImage]] = [[]]
        var height = 0
        for image in rendered {
            if height + image.height > 60_000, !parts[parts.count - 1].isEmpty {
                parts.append([])
                height = 0
            }
            parts[parts.count - 1].append(image)
            height += image.height + gap
        }

        var outputs: [URL] = []
        for (n, part) in parts.enumerated() {
            let total = part.reduce(0) { $0 + $1.height } + gap * (part.count - 1)
            guard let ctx = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw FWError("长图太大了")
            }
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: total))
            var y = total
            for image in part {
                y -= image.height
                ctx.draw(image, in: CGRect(x: 0, y: y, width: width, height: image.height))
                y -= gap
            }
            guard let stitched = ctx.makeImage() else { throw FWError("长图合成失败") }
            let suffix = parts.count > 1 ? "长图 \(n + 1)" : "长图"
            let out = try Out.url(for: url, suffix: suffix, ext: "jpg")
            try await ImageOps.write(stitched, to: out, fmt: "jpg", quality: 0.88)
            outputs.append(out)
        }
        progress(1)
        let skipped = doc.numberOfPages - count
        return OpResult(outputs: outputs, note: skipped > 0 ? "只拼了前 \(count) 页" : "\(count) 页拼成\(outputs.count > 1 ? " \(outputs.count) 张" : "一张")")
    }

    private struct Line {
        let text: NSAttributedString
        let plain: String
        let bounds: CGRect
        let size: CGFloat
    }

    /// Text with paragraphs rebuilt from the PDF's lines. PDFKit's own page text keeps every visual
    /// line break and sometimes glues list items onto headings, so lines are regrouped here:
    /// a new paragraph starts at a font-size change, a larger-than-usual gap, a list marker, or after
    /// a short line that ends a sentence.
    static func attributed(_ url: URL) throws -> NSAttributedString {
        let doc = try open(url)
        let out = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let selection = page.selection(for: page.bounds(for: .cropBox)) else { continue }
            var lines: [Line] = []
            for line in selection.selectionsByLine() {
                guard let raw = line.attributedString else { continue }
                let plain = raw.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plain.isEmpty else { continue }
                let piece = raw.attributedSubstring(from: (raw.string as NSString).range(of: plain))
                var size: CGFloat = 0
                piece.enumerateAttribute(.font, in: NSRange(location: 0, length: piece.length)) { value, _, _ in
                    if let font = value as? NSFont { size = max(size, font.pointSize) }
                }
                let bounds = line.bounds(for: page)
                lines.append(Line(text: piece, plain: plain, bounds: bounds, size: size > 0 ? size : bounds.height))
            }
            guard !lines.isEmpty else { continue }

            var gaps: [CGFloat] = []
            for (a, b) in zip(lines, lines.dropFirst()) where abs(a.size - b.size) < 0.6 {
                let gap = a.bounds.minY - b.bounds.maxY
                if gap > -1 { gaps.append(gap) }
            }
            let usualGap = gaps.sorted()[safe: gaps.count / 2] ?? 0
            let widest = lines.map(\.bounds.width).max() ?? 0

            if out.length > 0 { out.append(NSAttributedString(string: "\n\n")) }
            for (n, line) in lines.enumerated() {
                if n > 0 {
                    let previous = lines[n - 1]
                    let gap = previous.bounds.minY - line.bounds.maxY
                    let height = max(previous.bounds.height, line.bounds.height)
                    let paragraphBreak = abs(line.size - previous.size) > 0.6
                        || gap > usualGap + height * 0.35
                        || gap < -height * 1.5
                        || isListItem(line.plain)
                        || (previous.bounds.width < widest * 0.72 && endsSentence(previous.plain))
                    let separator = paragraphBreak ? "\n" : (joinsTight(previous.plain, line.plain) ? "" : " ")
                    out.append(NSAttributedString(string: separator, attributes: line.text.attributes(at: 0, effectiveRange: nil)))
                }
                out.append(line.text)
            }
        }
        TextFix.radicals(in: out)
        guard !out.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FWError("这个 PDF 没有文字层，试试「工具 → 识字」")
        }
        return out
    }

    private static func isListItem(_ text: String) -> Bool {
        if let first = text.first, "•◦▪●·‣-–—*".contains(first) { return true }
        return text.range(of: #"^(\d{1,3}|[a-zA-Z])[.)、]\s*\S"#, options: .regularExpression) != nil
            || text.range(of: #"^[（(]\d{1,3}[)）]"#, options: .regularExpression) != nil
            || text.range(of: #"^[一二三四五六七八九十]+、"#, options: .regularExpression) != nil
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？!?.:：;；」”)）".contains(last)
    }

    /// Chinese text joins across a line break without a space; Latin text needs one.
    private static func joinsTight(_ before: String, _ after: String) -> Bool {
        guard let a = before.unicodeScalars.last, let b = after.unicodeScalars.first else { return true }
        return TextFix.isCJK(a) || TextFix.isCJK(b)
    }

    static func toText(_ url: URL, fmt: String) async throws -> OpResult {
        let out = try Out.url(for: url, ext: fmt)
        let text = try attributed(url)
        if fmt == "txt" {
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        } else {
            try await DocOps.write(text, to: out, fmt: fmt)
        }
        return OpResult(outputs: [out])
    }

    static func compress(_ url: URL) throws -> OpResult {
        let doc = try open(url)
        let out = try Out.url(for: url, suffix: "压缩", ext: "pdf")
        guard doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else {
            throw FWError("压缩失败")
        }
        do {
            return try ImageOps.shrinkResult(source: url, output: out)
        } catch {
            throw FWError("这个 PDF 已经很精简了")
        }
    }

    static func split(_ url: URL) throws -> OpResult {
        let doc = try open(url)
        guard doc.pageCount > 1 else { throw FWError("只有 1 页，不用拆") }
        let folder = try Out.folder(for: url, suffix: "拆分")
        let base = url.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            guard single.write(to: folder.appendingPathComponent("\(base)-\(i + 1).pdf")) else { throw FWError("保存失败") }
        }
        return OpResult(outputs: [folder], note: "拆成 \(doc.pageCount) 个文件")
    }

    /// PDFs and images, in drag order, into one document.
    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        var keepAlive: [PDFDocument] = []
        let tmp = try Out.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (n, url) in urls.enumerated() {
            var source: PDFDocument?
            switch FileKind.of(url) {
            case .pdf:
                source = try open(url)
            case .image:
                let page = tmp.appendingPathComponent("\(n).pdf")
                try PDFMaker.write([ImageOps.load(url).cg], to: page)
                source = PDFDocument(url: page)
            default:
                continue
            }
            guard let source else { continue }
            keepAlive.append(source)
            for i in 0..<source.pageCount {
                if let page = source.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        guard merged.pageCount > 0, let first = urls.first else { throw FWError("没有可以合并的页面") }
        let out = try Out.url(for: first, suffix: "合并", ext: "pdf")
        guard merged.write(to: out) else { throw FWError("合并失败") }
        _ = keepAlive
        return out
    }

    static func rotate(_ url: URL) throws -> OpResult {
        let doc = try open(url)
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
        }
        let out = try Out.url(for: url, suffix: "旋转", ext: "pdf")
        guard doc.write(to: out) else { throw FWError("保存失败") }
        return OpResult(outputs: [out])
    }

    /// Re-draws every page through the system "Gray Tone" Quartz filter. Text stays vector.
    static func mono(_ url: URL) throws -> OpResult {
        let doc = try pages(url)
        guard let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Gray Tone.qfilter")) else {
            throw FWError("系统里找不到灰度滤镜")
        }
        let out = try Out.url(for: url, suffix: "黑白", ext: "pdf")
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, [kCGPDFContextCreator: "格式轮盘"] as CFDictionary) else {
            throw FWError("无法创建 PDF")
        }
        filter.apply(to: ctx)
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let size = displaySize(page)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            ctx.endPage()
        }
        filter.remove(from: ctx)
        ctx.closePDF()
        return OpResult(outputs: [out])
    }

    static func ocr(_ url: URL, progress: ProgressFn) async throws -> OpResult {
        let doc = try pages(url)
        let count = doc.numberOfPages
        var parts: [String] = []
        for i in 1...count {
            if let page = doc.page(at: i), let image = render(page, scale: 2) {
                parts.append(try ImageOps.recognizeText(image))
            }
            progress(Double(i) / Double(count))
        }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FWError("没认出文字") }
        let out = try Out.url(for: url, suffix: "文字", ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return OpResult(outputs: [out], note: "认出 \(Fmt.count(text.count)) 字，已复制", clip: text)
    }
}

enum TextFix {
    /// Chinese PDFs often extract as radical code points (⽂ ⻓ ⻔ …) because the font shares one glyph
    /// between a radical and the ordinary character. Kangxi radicals fold via NFKC; the simplified
    /// supplement radicals have no decomposition, so they are mapped by hand.
    private static let supplement: [UInt32: Character] = [
        0x2E9F: "母", 0x2EA0: "民", 0x2EC4: "西", 0x2EC5: "见", 0x2EC6: "角", 0x2EC8: "讠", 0x2EC9: "贝",
        0x2ECB: "车", 0x2ECE: "辶", 0x2ED0: "钅", 0x2ED3: "长", 0x2ED4: "门", 0x2ED7: "雨", 0x2ED8: "青",
        0x2EDA: "页", 0x2EDB: "风", 0x2EDC: "飞", 0x2EDD: "食", 0x2EE0: "饣", 0x2EE2: "马", 0x2EE4: "鬼",
        0x2EE5: "鱼", 0x2EE6: "鸟", 0x2EE7: "卤", 0x2EE8: "麦", 0x2EE9: "黄", 0x2EEA: "黾", 0x2EEC: "齐",
        0x2EEE: "齿", 0x2EF0: "龙", 0x2EF3: "龟",
    ]

    static func replacement(for unit: unichar) -> String? {
        switch unit {
        case 0x2F00...0x2FD5:
            guard let scalar = Unicode.Scalar(unit) else { return nil }
            return String(scalar).precomposedStringWithCompatibilityMapping
        case 0x2E80...0x2EF3:
            return supplement[UInt32(unit)].map(String.init)
        default:
            return nil
        }
    }

    static func radicals(in text: NSMutableAttributedString) {
        let units = text.string as NSString
        for i in 0..<units.length {
            // Every replacement is a single BMP character, so indices stay valid.
            if let fixed = replacement(for: units.character(at: i)), (fixed as NSString).length == 1 {
                text.replaceCharacters(in: NSRange(location: i, length: 1), with: fixed)
            }
        }
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FDF, 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
