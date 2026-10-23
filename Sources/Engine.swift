import AppKit
import CryptoKit

struct RunSummary {
    var outputs: [URL]
    var title: String
    var detail: String
    /// Display name of the folder the results went to ("桌面", "下载"…).
    var saved: String? {
        outputs.first.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path) }
    }
}

/// The last few results, for the menu's "最近转换" list.
final class Recents {
    static let shared = Recents()
    private let key = "recentOutputs"

    var items: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let merged = urls + items.filter { !urls.contains($0) }
        UserDefaults.standard.set(merged.prefix(8).map(\.path), forKey: key)
    }
}

enum Engine {
    /// Runs one wheel option over the dragged files.
    static func run(_ id: String, label: String, files: [URL], progress: @escaping ProgressFn) async throws -> RunSummary {
        guard !files.isEmpty else { throw FWError("没有文件") }
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) 个文件"
        let title = "\(name)  →  \(label)"

        // Actions that take the whole selection at once.
        switch id {
        case "pdf.merge", "img.to.pdf" where files.count > 1:
            let out = try await Out.stagedURL(near: files[0]) { try PDFOps.merge(files) }
            return RunSummary(outputs: [out], title: title, detail: "\(out.lastPathComponent) · \(Fmt.bytes(Fmt.size(of: out))) · 存到「\(FileManager.default.displayName(atPath: out.deletingLastPathComponent().path))」")
        case "gen.zip":
            let out = try await Out.stagedURL(near: files[0]) { try await GenericOps.zip(files) }
            return RunSummary(outputs: [out], title: title, detail: "\(out.lastPathComponent) · \(Fmt.bytes(Fmt.size(of: out))) · 存到「\(FileManager.default.displayName(atPath: out.deletingLastPathComponent().path))」")
        case "gen.path":
            await MainActor.run { Clipboard.set(files.map(\.path).joined(separator: "\n")) }
            return RunSummary(outputs: [], title: title, detail: files.count == 1 ? files[0].path : "\(files.count) 条路径已复制")
        case "gen.name":
            await MainActor.run { Clipboard.set(files.map(\.lastPathComponent).joined(separator: "\n")) }
            return RunSummary(outputs: [], title: title, detail: "已复制到剪贴板")
        default:
            break
        }

        let kind = Catalog.context(for: files).kind
        let targets = files.filter { FileKind.of($0) == kind || id.hasPrefix("gen.") }
        var outputs: [URL] = []
        var notes: [String] = []
        var clips: [String] = []
        var failures: [Error] = []
        var before: Int64 = 0, after: Int64 = 0
        for (n, file) in targets.enumerated() {
            let step: ProgressFn = { p in progress((Double(n) + p) / Double(targets.count)) }
            do {
                let result = try await runOne(id, file, progress: step)
                outputs += result.outputs
                if let note = result.note { notes.append(note) }
                if let clip = result.clip { clips.append(clip) }
                before += Fmt.size(of: file)
                after += result.outputs.reduce(Int64(0)) { $0 + Fmt.size(of: $1) }
            } catch {
                failures.append(error)
            }
        }
        if outputs.isEmpty, notes.isEmpty, clips.isEmpty {
            throw failures.first ?? FWError("没有可以处理的文件")
        }
        if !clips.isEmpty {
            let text = clips.joined(separator: "\n\n")
            await MainActor.run { Clipboard.set(text) }
        }

        var detail: [String] = []
        if !outputs.isEmpty, after > 0, !id.hasPrefix("gen.") {
            detail.append("\(Fmt.bytes(before)) → \(Fmt.bytes(after))")
        }
        if targets.count == 1, let note = notes.first {
            detail.append(note)
        } else if !notes.isEmpty, id.hasSuffix("compress") {
            let saved = Int((1 - Double(after) / Double(max(before, 1))) * 100)
            detail.append("体积 -\(saved)%")
        } else if !clips.isEmpty {
            detail.append("文字已复制到剪贴板")
        }
        if !failures.isEmpty { detail.append("\(failures.count) 个失败：\(failures[0].localizedDescription)") }
        var summary = RunSummary(outputs: outputs, title: title, detail: "")
        if let saved = summary.saved { detail.append("存到「\(saved)」") }
        summary.detail = detail.joined(separator: " · ")
        return summary
    }

    static func runOne(_ id: String, _ file: URL, progress: @escaping ProgressFn) async throws -> OpResult {
        try await Out.staged(near: file) { try await dispatch(id, file, progress: progress) }
    }

    private static func dispatch(_ id: String, _ file: URL, progress: @escaping ProgressFn) async throws -> OpResult {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { throw FWError("未知操作 \(id)") }
        let target = parts.count == 3 && parts[1] == "to" ? parts[2] : nil

        switch parts[0] {
        case "img":
            if let target { return try await ImageOps.convert(file, to: target) }
            switch id {
            case "img.compress": return try await ImageOps.compress(file)
            case "img.half": return try await ImageOps.half(file)
            case "img.cutout": return try await ImageOps.cutout(file)
            case "img.ocr": return try await ImageOps.ocr(file)
            case "img.mono": return try await ImageOps.mono(file)
            case "img.rotate": return try await ImageOps.rotate(file)
            case "img.strip": return try await ImageOps.strip(file)
            case "img.backdrop": return try await ImageOps.backdrop(file)
            default: break
            }
        case "pdf":
            switch id {
            case "pdf.to.png": return try await PDFOps.toImages(file, fmt: "png", progress: progress)
            case "pdf.to.jpg": return try await PDFOps.toImages(file, fmt: "jpg", progress: progress)
            case "pdf.to.long": return try await PDFOps.longImage(file, progress: progress)
            case "pdf.compress": return try PDFOps.compress(file)
            case "pdf.split": return try PDFOps.split(file)
            case "pdf.rotate": return try PDFOps.rotate(file)
            case "pdf.mono": return try PDFOps.mono(file)
            case "pdf.ocr": return try await PDFOps.ocr(file, progress: progress)
            case "pdf.strip": return try Privacy.stripPDF(file)
            default:
                if let target { return try await PDFOps.toText(file, fmt: target) }
            }
        case "vid":
            if id == "vid.strip" { return try await Privacy.stripVideo(file, progress: progress) }
            return try await MediaOps.video(id, file, progress: progress)
        case "aud":
            return try await MediaOps.audio(id, file, progress: progress)
        case "doc":
            if let target { return try await DocOps.convert(file, to: target) }
            switch id {
            case "doc.count": return try await DocOps.count(file)
            case "doc.copy": return try await DocOps.copy(file)
            case "doc.strip": return try await Privacy.stripDocx(file)
            default: break
            }
        case "gen":
            if id == "gen.sha" { return try await GenericOps.sha256(file) }
        default:
            break
        }
        throw FWError("未知操作 \(id)")
    }
}

enum GenericOps {
    static func zip(_ files: [URL]) async throws -> URL {
        guard let first = files.first else { throw FWError("没有文件") }
        if files.count == 1 {
            let out = try Out.url(for: first, ext: "zip")
            try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            return out
        }
        let tmp = try Out.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = tmp.appendingPathComponent("归档")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for file in files {
            let base = file.deletingPathExtension().lastPathComponent
            let target = Out.unique(in: bundle, base: base, ext: file.pathExtension)
            try FileManager.default.copyItem(at: file, to: target)
        }
        let out = try Out.named("归档 \(files.count) 项", ext: "zip")
        try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, out.path])
        return out
    }

    static func sha256(_ url: URL) async throws -> OpResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return OpResult(note: "SHA-256 \(hex.prefix(12))… 已复制", clip: hex)
    }
}

/// Runs a chosen slot in the background and reports back with the HUD and banner.
final class Runner {
    static let shared = Runner()

    func run(_ option: WheelOption, files: [URL], screen: NSScreen?, wanted: Wanted = Wanted()) {
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) 个文件"
        let job = BusyHUD.shared.begin("\(name) → \(option.title)")
        let id = option.id, label = option.title
        Log.write("run: \(id) on \(files.count) file(s)")
        Task.detached(priority: .userInitiated) {
            do {
                let summary = try await Engine.run(id, label: label, files: files) { p in
                    DispatchQueue.main.async { BusyHUD.shared.update(job, progress: p) }
                }
                Log.write("run: ok → \(summary.outputs.map(\.path).joined(separator: ", ")) \(summary.detail)")
                await MainActor.run {
                    BusyHUD.shared.end(job)
                    Recents.shared.add(summary.outputs)
                    var detail = summary.detail
                    let evaded = id.hasSuffix(".strip") && wanted.level > 0
                    // The chosen weapon is racked first, then the mission-passed sting.
                    SFX.shared.play(Weapon.of(id).sound)
                    SFX.shared.play(evaded ? .evaded : .passed, after: 0.3)
                    if evaded {
                        WantedHUD.shared.evade(wanted, on: screen)
                        detail = "通缉 " + String(repeating: "★", count: wanted.level) + " 已解除" + (summary.saved.map { " · 存到「\($0)」" } ?? "")
                    }
                    BannerController.shared.show(passed: true, title: summary.title, detail: detail, on: screen)
                }
            } catch {
                Log.write("run: failed \(id): \(error.localizedDescription)")
                await MainActor.run {
                    BusyHUD.shared.end(job)
                    SFX.shared.play(.wasted)
                    BannerController.shared.show(passed: false, title: "\(name)  →  \(label)", detail: error.localizedDescription, on: screen)
                }
            }
        }
    }

    /// Demo wheel: nothing is converted, it only plays the finish.
    func demo(_ option: WheelOption, context: WheelContext, screen: NSScreen?) {
        SFX.shared.play(Weapon.of(option.id).sound)
        SFX.shared.play(.passed, after: 0.3)
        BannerController.shared.show(passed: true, title: "\(context.headline)  →  \(option.title)",
                                     detail: "演示模式 · 拖一个真文件再按 ⇧ 试试", on: screen)
    }
}
