import AppKit

struct FWError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias ProgressFn = @Sendable (Double) -> Void

/// What one action produced for one input file.
struct OpResult {
    var outputs: [URL] = []
    var note: String?
    /// Text to put on the clipboard once the whole batch is done.
    var clip: String?
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let item = items?.nextObject() as? URL {
                total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }
        return Int64(values?.fileSize ?? 0)
    }

    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// Where results go: next to the source file, never overwriting anything.
enum Out {
    static func dir(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    static func url(for source: URL, suffix: String? = nil, ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent + (suffix.map { " " + $0 } ?? "")
        return unique(in: dir(for: source), base: base, ext: ext)
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        let dot = ext.isEmpty ? "" : "." + ext
        var candidate = dir.appendingPathComponent(base + dot)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)\(dot)")
            n += 1
        }
        return candidate
    }

    static func folder(for source: URL, suffix: String) throws -> URL {
        let url = unique(in: dir(for: source), base: source.deletingPathExtension().lastPathComponent + " " + suffix, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FormatWheel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Clipboard {
    static func set(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// External command-line tools (ffmpeg, cwebp) are optional "weapons": slots that need them
/// show as un-equipped when they are missing.
enum Shell {
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"]
    private static var found: [String: String?] = [:]
    private static let lock = NSLock()

    static func find(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = found[name] { return hit }
        let path = searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        found[name] = path
        return path
    }

    static func has(_ name: String) -> Bool { find(name) != nil }
    static var ffmpeg: String? { find("ffmpeg") }
    static var cwebp: String? { find("cwebp") }

    static func installHint(_ name: String) -> String {
        let formula = name == "cwebp" ? "webp" : name
        return "需要先装 \(name)：终端运行 brew install \(formula)"
    }

    /// Runs a tool to completion. `onLine` receives stdout line by line (used for ffmpeg progress).
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let buffer = OutputBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in buffer.appendOut(data) { onLine?(line) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.appendErr(data)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                buffer.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                for line in buffer.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile()) { onLine?(line) }
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: buffer.stdout)
                } else {
                    let tool = URL(fileURLWithPath: executable).lastPathComponent
                    let last = buffer.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "退出码 \(proc.terminationStatus)"
                    continuation.resume(throwing: FWError("\(tool) 出错：\(last.prefix(140))"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: FWError("无法运行 \(executable)：\(error.localizedDescription)"))
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var pending = ""

    var stdout: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var stderr: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }

    func appendOut(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        out.append(data)
        pending += String(decoding: data, as: UTF8.self)
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines
    }

    func appendErr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        err.append(data)
    }
}

/// A small rolling log at ~/Library/Logs/FormatWheel.log, for figuring out what a drag did.
enum Log {
    private static let queue = DispatchQueue(label: "formatwheel.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FormatWheel.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 512_000 {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
