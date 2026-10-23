import AVFoundation
import ImageIO
import PDFKit

/// GTA-style wanted level for a file: how much of it can be traced back to you.
struct Wanted: Equatable {
    var level = 0
    var reasons: [String] = []
}

enum Privacy {
    // MARK: - Scanning

    static func scan(_ files: [URL]) async -> Wanted {
        var worst = Wanted()
        var flagged = 0
        for url in files.prefix(24) {
            let found = await scan(url)
            if found.level > 0 { flagged += 1 }
            if found.level > worst.level { worst = found }
        }
        if flagged > 1 { worst.reasons.append("\(flagged) 个文件留有痕迹") }
        return worst
    }

    static func scan(_ url: URL) async -> Wanted {
        var found: Wanted
        switch FileKind.of(url) {
        case .image: found = image(url)
        case .video: found = await video(url)
        case .pdf: found = pdf(url)
        case .document: found = url.pathExtension.lowercased() == "docx" ? await docx(url) : Wanted()
        default: found = Wanted()
        }
        found.level = min(found.level, 5)
        return found
    }

    static func image(_ url: URL) -> Wanted {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any] else {
            return Wanted()
        }
        var found = Wanted()
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if gps[kCGImagePropertyGPSLatitude] != nil {
            found.level += 2
            found.reasons.append("GPS 定位")
        }
        if let model = nonEmpty(tiff[kCGImagePropertyTIFFModel]) ?? nonEmpty(exif[kCGImagePropertyExifLensModel]) {
            found.level += 1
            found.reasons.append(String(model.prefix(24)))
        }
        if exif[kCGImagePropertyExifDateTimeOriginal] != nil {
            found.level += 1
            found.reasons.append("拍摄时间")
        }
        if nonEmpty(exif[kCGImagePropertyExifBodySerialNumber]) != nil || nonEmpty(exif[kCGImagePropertyExifCameraOwnerName]) != nil
            || nonEmpty(tiff[kCGImagePropertyTIFFArtist]) != nil {
            found.level += 1
            found.reasons.append("机身序列号 / 作者")
        }
        return found
    }

    static func video(_ url: URL) async -> Wanted {
        let found = await videoNative(url)
        return found.level > 0 ? found : await videoProbe(url)
    }

    private static func videoNative(_ url: URL) async -> Wanted {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata), !items.isEmpty else { return Wanted() }
        func first(_ ids: [AVMetadataIdentifier], common: AVMetadataKey) -> AVMetadataItem? {
            items.first { item in
                if let id = item.identifier, ids.contains(id) { return true }
                return item.commonKey == common
            }
        }
        var found = Wanted()
        if first([.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709], common: .commonKeyLocation) != nil {
            found.level += 2
            found.reasons.append("GPS 定位")
        }
        if let model = first([.quickTimeMetadataModel], common: .commonKeyModel),
           let name = try? await model.load(.stringValue), !name.isEmpty {
            found.level += 1
            found.reasons.append(String(name.prefix(24)))
        }
        if first([.quickTimeMetadataCreationDate], common: .commonKeyCreationDate) != nil {
            found.level += 1
            found.reasons.append("拍摄时间")
        }
        return found
    }

    /// Tags as ffprobe sees them: covers files AVFoundation can't map (Android phones, MKV, ffmpeg output).
    private static func videoProbe(_ url: URL) async -> Wanted {
        guard let probe = Shell.find("ffprobe"),
              let out = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "default=nw=1", url.path]) else {
            return Wanted()
        }
        var found = Wanted()
        var tags: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard line.hasPrefix("TAG:"), let eq = line.firstIndex(of: "=") else { continue }
            tags[String(line[line.index(line.startIndex, offsetBy: 4)..<eq]).lowercased()] = String(line[line.index(after: eq)...])
        }
        if tags.keys.contains(where: { $0.contains("location") || $0 == "©xyz" }) {
            found.level += 2
            found.reasons.append("GPS 定位")
        }
        if let model = tags.first(where: { $0.key.hasSuffix("model") })?.value, !model.isEmpty {
            found.level += 1
            found.reasons.append(String(model.prefix(24)))
        }
        // creation_time exists in almost every file; only a camera capture date counts.
        if tags.keys.contains("com.apple.quicktime.creationdate") {
            found.level += 1
            found.reasons.append("拍摄时间")
        }
        return found
    }

    static func pdf(_ url: URL) -> Wanted {
        guard let attributes = PDFDocument(url: url)?.documentAttributes else { return Wanted() }
        var found = Wanted()
        if let author = nonEmpty(attributes[PDFDocumentAttribute.authorAttribute.rawValue]) {
            found.level += 2
            found.reasons.append("作者：\(author.prefix(16))")
        }
        if nonEmpty(attributes[PDFDocumentAttribute.creatorAttribute.rawValue]) != nil {
            found.level += 1
            found.reasons.append("制作软件")
        }
        if nonEmpty(attributes[PDFDocumentAttribute.keywordsAttribute.rawValue]) != nil
            || nonEmpty(attributes[PDFDocumentAttribute.subjectAttribute.rawValue]) != nil {
            found.level += 1
            found.reasons.append("主题 / 关键词")
        }
        // Dates are left out on purpose: saving any PDF stamps a fresh one, so they aren't a trail.
        return found
    }

    static func docx(_ url: URL) async -> Wanted {
        guard let core = try? await Shell.run("/usr/bin/unzip", ["-p", url.path, "docProps/core.xml"]) else { return Wanted() }
        var found = Wanted()
        let creator = tag("dc:creator", in: core)
        if let creator {
            found.level += 2
            found.reasons.append("作者：\(creator.prefix(16))")
        }
        if let editor = tag("cp:lastModifiedBy", in: core), editor != creator {
            found.level += 1
            found.reasons.append("修改人：\(editor.prefix(16))")
        }
        if tag("Company", in: (try? await Shell.run("/usr/bin/unzip", ["-p", url.path, "docProps/app.xml"])) ?? "") != nil {
            found.level += 1
            found.reasons.append("公司名")
        }
        // The creation date is left out: Word rejects a blanked date, so 去隐私 can't clear it.
        return found
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let range = xml.range(of: "<\(name)[^>]*>[^<]*</\(name)>", options: .regularExpression) else { return nil }
        let inner = String(xml[range]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return nonEmpty(inner)
    }

    // MARK: - Lying low (去隐私)

    static let evadedNote = "已甩掉警察：定位、设备和作者信息都抹掉了"

    /// Videos: re-wrap without re-encoding and without metadata (location, device, dates).
    static func stripVideo(_ url: URL, progress: @escaping ProgressFn) async throws -> OpResult {
        let ext = url.pathExtension.lowercased()
        if await MediaOps.avVideo(url) {
            let type: AVFileType = ["mp4", "m4v"].contains(ext) ? .mp4 : .mov
            let out = try Out.url(for: url, suffix: "去隐私", ext: type == .mp4 ? "mp4" : "mov")
            try await MediaOps.export(AVURLAsset(url: url), preset: AVAssetExportPresetPassthrough, type: type, out: out, progress: progress) { session in
                session.metadata = []
                session.metadataItemFilter = .forSharing()
            }
            return OpResult(outputs: [out], note: evadedNote)
        }
        let out = try Out.url(for: url, suffix: "去隐私", ext: ext.isEmpty ? "mp4" : ext)
        try await MediaOps.ff(url, ["-map", "0", "-map_metadata", "-1", "-c", "copy"], out: out, progress: progress)
        return OpResult(outputs: [out], note: evadedNote)
    }

    static func stripPDF(_ url: URL) throws -> OpResult {
        guard let doc = PDFDocument(url: url) else { throw FWError("打不开这个 PDF") }
        if doc.isLocked { throw FWError("这个 PDF 有密码保护") }
        var attributes = doc.documentAttributes ?? [:]
        let personal: [PDFDocumentAttribute] = [.authorAttribute, .creatorAttribute, .producerAttribute, .subjectAttribute,
                                                .keywordsAttribute, .creationDateAttribute, .modificationDateAttribute]
        for key in personal { attributes.removeValue(forKey: key.rawValue) }
        doc.documentAttributes = attributes
        let out = try Out.url(for: url, suffix: "去隐私", ext: "pdf")
        guard doc.write(to: out) else { throw FWError("保存失败") }
        return OpResult(outputs: [out], note: evadedNote)
    }

    /// Word: blanks the author fields in docProps/core.xml and app.xml inside a copy of the file.
    static func stripDocx(_ url: URL) async throws -> OpResult {
        let tmp = try Out.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let out = try Out.url(for: url, suffix: "去隐私", ext: "docx")
        try FileManager.default.copyItem(at: url, to: out)
        do {
            try FileManager.default.createDirectory(at: tmp.appendingPathComponent("docProps"), withIntermediateDirectories: true)
            var changed: [String] = []
            let fields = ["core.xml": ["dc:creator", "cp:lastModifiedBy", "cp:keywords", "dc:description", "dc:subject", "cp:category"],
                          "app.xml": ["Company", "Manager", "Template"]]
            for (file, names) in fields {
                guard let xml = try? await Shell.run("/usr/bin/unzip", ["-p", url.path, "docProps/\(file)"]), !xml.isEmpty else { continue }
                var cleaned = xml
                for name in names {
                    cleaned = cleaned.replacingOccurrences(of: "<\(name)([^>]*)>[^<]*</\(name)>", with: "<\(name)$1></\(name)>", options: .regularExpression)
                }
                try cleaned.write(to: tmp.appendingPathComponent("docProps/\(file)"), atomically: true, encoding: .utf8)
                changed.append("docProps/\(file)")
            }
            guard !changed.isEmpty else { throw FWError("这个文档里没有作者信息") }
            try await Shell.run("/usr/bin/zip", ["-q", out.path] + changed, cwd: tmp)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return OpResult(outputs: [out], note: evadedNote)
    }
}
