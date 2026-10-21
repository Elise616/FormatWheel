import AppKit

enum DocOps {
    static let textutilFormats: Set<String> = ["txt", "html", "rtf", "rtfd", "doc", "docx", "wordml", "odt", "webarchive"]

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// Any supported document as an attributed string (textutil does the parsing out of process).
    static func load(_ url: URL) async throws -> NSAttributedString {
        if isMarkdown(url) {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let html = Markdown.toHTML(markdown)
            return try await MainActor.run {
                try NSAttributedString(data: Data(html.utf8), options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ], documentAttributes: nil)
            }
        }
        let tmp = try Out.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rtf = tmp.appendingPathComponent("doc.rtf")
        try await Shell.run("/usr/bin/textutil", ["-convert", "rtf", "-output", rtf.path, url.path])
        return try NSAttributedString(url: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }

    static func write(_ text: NSAttributedString, to url: URL, fmt: String) async throws {
        switch fmt {
        case "txt":
            try text.string.write(to: url, atomically: true, encoding: .utf8)
        case "md":
            try Markdown.from(text).write(to: url, atomically: true, encoding: .utf8)
        case "pdf":
            try await MainActor.run { try printPDF(text, to: url) }
        default:
            let types: [String: NSAttributedString.DocumentType] = [
                "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "html": .html, "odt": .openDocument,
            ]
            guard let type = types[fmt] else { throw FWError("不支持写入 \(fmt.uppercased())") }
            let data = try await MainActor.run {
                try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            }
            try data.write(to: url)
        }
    }

    static func convert(_ url: URL, to fmt: String) async throws -> OpResult {
        let out = Out.url(for: url, ext: fmt)
        if !isMarkdown(url), textutilFormats.contains(fmt) {
            do {
                try await Shell.run("/usr/bin/textutil", ["-convert", fmt, "-output", out.path, url.path])
                return OpResult(outputs: [out])
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
        }
        if isMarkdown(url), fmt == "txt" {
            try Markdown.plain(String(contentsOf: url, encoding: .utf8)).write(to: out, atomically: true, encoding: .utf8)
            return OpResult(outputs: [out])
        }
        try await write(load(url), to: out, fmt: fmt)
        return OpResult(outputs: [out])
    }

    /// Lays the text out on A4 pages and prints it straight to a PDF file.
    @MainActor
    static func printPDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 60
        info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        let body = NSMutableAttributedString(attributedString: text)
        body.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            if value == nil { body.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        view.textStorage?.setAttributedString(body)
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw FWError("生成 PDF 失败") }
    }

    static func plainText(_ url: URL) async throws -> String {
        if isMarkdown(url) { return Markdown.plain(try String(contentsOf: url, encoding: .utf8)) }
        if ["txt", "text"].contains(url.pathExtension.lowercased()) {
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
            let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            return try String(contentsOf: url, encoding: gb18030)
        }
        return try await load(url).string
    }

    static func count(_ url: URL) async throws -> OpResult {
        let text = try await plainText(url)
        var cjk = 0, other = 0
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
                cjk += 1
                inWord = false
            default:
                if CharacterSet.alphanumerics.contains(scalar) {
                    if !inWord { words += 1 }
                    inWord = true
                } else {
                    inWord = false
                }
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { other += 1 }
            }
        }
        let total = cjk + words
        var parts = ["共 \(Fmt.count(total)) 字"]
        if cjk > 0 && words > 0 { parts.append("中文 \(Fmt.count(cjk)) · 英文 \(Fmt.count(words)) 词") }
        parts.append("\(Fmt.count(cjk + other)) 个字符（不含空格）")
        return OpResult(note: parts.joined(separator: " · "))
    }

    static func copy(_ url: URL) async throws -> OpResult {
        let text = try await plainText(url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FWError("文档里没有文字") }
        return OpResult(note: "已复制 \(Fmt.count(text.count)) 字", clip: text)
    }
}

/// Just enough Markdown for documents: headings, emphasis, code, lists, quotes, links.
enum Markdown {
    static func toHTML(_ source: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var list: String?
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                html.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>")
                paragraph = []
            }
        }
        func closeList() {
            if let tag = list { html.append("</\(tag)>"); list = nil }
        }

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    html.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                    code = []
                } else {
                    flushParagraph(); closeList()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }

            if let level = headingLevel(line) {
                flushParagraph(); closeList()
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inline(text))</h\(level)>")
            } else if line == "---" || line == "***" || line == "___" {
                flushParagraph(); closeList()
                html.append("<hr>")
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote>\(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
            } else if let item = bullet(line) {
                flushParagraph()
                if list != "ul" { closeList(); html.append("<ul>"); list = "ul" }
                html.append("<li>\(inline(item))</li>")
            } else if let item = numbered(line) {
                flushParagraph()
                if list != "ol" { closeList(); html.append("<ol>"); list = "ol" }
                html.append("<li>\(inline(item))</li>")
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        if inCode { html.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>") }
        flushParagraph(); closeList()
        // Named public fonts: "-apple-system" would embed private ".SFNS" names that other apps can't resolve.
        let style = "body{font-family:'Helvetica Neue','PingFang SC',sans-serif;font-size:14px;line-height:1.6;color:#111}h1,h2,h3{margin:18px 0 8px}p{margin:0 0 10px}ul,ol{margin:0 0 14px}code,pre{font-family:Menlo,monospace;font-size:12px}blockquote{color:#555}"
        return "<html><head><meta charset=\"utf-8\"><style>\(style)</style></head><body>\(html.joined(separator: "\n"))</body></html>"
    }

    static func plain(_ source: String) -> String {
        source.components(separatedBy: .newlines).map { raw -> String in
            var line = raw
            if headingLevel(line.trimmingCharacters(in: .whitespaces)) != nil {
                line = String(line.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            }
            for token in ["**", "__", "`"] { line = line.replacingOccurrences(of: token, with: "") }
            return line
        }.joined(separator: "\n")
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\(([^)]+)\)"#, "$1"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"__([^_]+)__"#, "<b>$1</b>"),
            (#"(?<![*\w])\*([^*]+)\*(?!\*)"#, "<i>$1</i>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }

    /// Attributed text to Markdown, inferring headings from font size and weight.
    static func from(_ text: NSAttributedString) -> String {
        let full = NSRange(location: 0, length: text.length)
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize.rounded(), default: 0] += range.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12

        var lines: [String] = []
        (text.string as NSString).enumerateSubstrings(in: full, options: .byParagraphs) { _, range, _, _ in
            let paragraph = text.attributedSubstring(from: range)
            let plain = paragraph.string.trimmingCharacters(in: .whitespaces)
            if plain.isEmpty {
                if lines.last != "" { lines.append("") }
                return
            }
            var largest: CGFloat = 0
            var allBold = true
            paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, r, _ in
                guard let font = value as? NSFont else { return }
                let piece = (paragraph.string as NSString).substring(with: r).trimmingCharacters(in: .whitespaces)
                if piece.isEmpty { return }
                largest = max(largest, font.pointSize)
                if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
            }
            let line: String
            if largest >= body * 1.55 {
                line = "# " + plain
            } else if largest >= body * 1.28 {
                line = "## " + plain
            } else if largest >= body * 1.1 || (allBold && plain.count <= 40) {
                line = "### " + plain
            } else {
                var md = emphasised(paragraph).trimmingCharacters(in: .whitespaces)
                if let first = md.first, "•◦▪●·–".contains(first) {
                    md = "- " + md.dropFirst().trimmingCharacters(in: .whitespaces)
                }
                line = md
            }
            if line.hasPrefix("#"), lines.last.map({ !$0.isEmpty }) == true { lines.append("") }
            lines.append(line)
            if line.hasPrefix("#") { lines.append("") }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func emphasised(_ paragraph: NSAttributedString) -> String {
        var out = ""
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, r, _ in
            let piece = (paragraph.string as NSString).substring(with: r)
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold), !trimmed.isEmpty {
                let lead = piece.prefix(while: { $0 == " " }), tail = String(piece.reversed().prefix(while: { $0 == " " }))
                out += lead + "**" + trimmed + "**" + tail
            } else {
                out += piece
            }
        }
        return out
    }
}
