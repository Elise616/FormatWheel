import AppKit
import Darwin

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
///
/// Every operation runs inside `Out.staged`. Names are handed out in a private 0700 directory created
/// beside the destination; when the operation succeeds, each output is published with an exclusive
/// rename (`RENAME_EXCL`), so an existing file, folder or dangling symlink is never replaced, even by a
/// writer that races us. Filesystems without `RENAME_EXCL` fail closed instead of overwriting.
enum Out {
    @TaskLocal private static var stage: Stage?

    /// Runs `body` with every `Out.url/folder/named` redirected into a staging directory, then publishes
    /// the outputs it returns and always removes the staging directory.
    static func staged(near source: URL, _ body: () async throws -> OpResult) async throws -> OpResult {
        let stage = Stage(source: source)
        defer { stage.discard() }
        let result = try await Out.$stage.withValue(stage) { try await body() }
        return try stage.publish(result)
    }

    /// Same, for actions that produce exactly one file.
    static func stagedURL(near source: URL, _ body: () async throws -> URL) async throws -> URL {
        let result = try await staged(near: source) { OpResult(outputs: [try await body()]) }
        return result.outputs[0]
    }

    static func url(for source: URL, suffix: String? = nil, ext: String) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent + (suffix.map { " " + $0 } ?? "")
        return try current().claim(base: base, ext: ext, directory: false)
    }

    static func folder(for source: URL, suffix: String) throws -> URL {
        try current().claim(base: source.deletingPathExtension().lastPathComponent + " " + suffix, ext: "", directory: true)
    }

    static func named(_ base: String, ext: String) throws -> URL {
        try current().claim(base: base, ext: ext, directory: false)
    }

    /// Free name inside a private directory the caller already owns (never the user's folders).
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

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FormatWheel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func current() throws -> Stage {
        guard let stage else { throw FWError("输出操作缺少安全暂存上下文") }
        return stage
    }

    private static func reason(_ code: Int32) -> String { String(cString: strerror(code)) }

    private final class Stage: @unchecked Sendable {
        private struct Claim { let base: String; let ext: String }

        private let source: URL
        private let lock = NSLock()
        private var parentURL: URL?
        private var parentFD: Int32 = -1
        private var stageFD: Int32 = -1
        private var stageURL: URL?
        private var claims: [String: Claim] = [:]

        init(source: URL) { self.source = source }

        /// Reserves a name in the staging directory (created on first use, so read-only actions touch nothing).
        func claim(base: String, ext: String, directory: Bool) throws -> URL {
            lock.lock()
            defer { lock.unlock() }
            let dir = try create()
            let dot = ext.isEmpty ? "" : "." + ext
            var n = 1
            while true {
                let name = n == 1 ? base + dot : "\(base) \(n)\(dot)"
                n += 1
                var st = stat()
                if claims[name] != nil || fstatat(stageFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { continue }
                claims[name] = Claim(base: base, ext: ext)
                let url = dir.appendingPathComponent(name, isDirectory: directory)
                if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
                return url
            }
        }

        /// Moves each claimed output next to the source (or the fallback folder) without replacing anything.
        func publish(_ result: OpResult) throws -> OpResult {
            lock.lock()
            defer { lock.unlock() }
            guard let stageURL else { return result }
            var result = result
            // Check every declared output first, so a missing one fails before anything becomes visible.
            var pending: [(index: Int, name: String, claim: Claim, directory: Bool)] = []
            for (index, output) in result.outputs.enumerated() {
                let name = output.lastPathComponent
                guard output.deletingLastPathComponent().path == stageURL.path, let claim = claims[name] else { continue }
                var st = stat()
                guard fstatat(stageFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                    throw FWError("输出文件没有生成：\(name)")
                }
                pending.append((index, name, claim, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)))
            }
            var saved: [URL] = []
            for item in pending {
                do {
                    let final = try move(item.name, claim: item.claim, directory: item.directory)
                    result.outputs[item.index] = final
                    saved.append(final)
                } catch {
                    if saved.isEmpty { throw error }
                    throw FWError("\(error.localizedDescription)；已保存：\(saved.map(\.path).joined(separator: "、"))")
                }
            }
            return result
        }

        private func move(_ name: String, claim: Claim, directory: Bool) throws -> URL {
            let dot = claim.ext.isEmpty ? "" : "." + claim.ext
            var n = 1
            while true {
                let finalName = n == 1 ? claim.base + dot : "\(claim.base) \(n)\(dot)"
                if renameatx_np(stageFD, name, parentFD, finalName, UInt32(RENAME_EXCL)) == 0 {
                    return parentURL!.appendingPathComponent(finalName, isDirectory: directory)
                }
                switch errno {
                case EEXIST:
                    n += 1
                    if n > 10_000 { throw FWError("同名文件太多，没法保存") }
                case ENOTSUP, EINVAL:
                    throw FWError("目标磁盘不支持安全无覆盖保存；请将源文件移到本机磁盘后重试")
                default:
                    throw FWError("保存失败：\(Out.reason(errno))")
                }
            }
        }

        func discard() {
            lock.lock()
            defer { lock.unlock() }
            if let stageURL { try? FileManager.default.removeItem(at: stageURL) }
            if stageFD >= 0 { close(stageFD) }
            if parentFD >= 0 { close(parentFD) }
            stageFD = -1
            parentFD = -1
            stageURL = nil
        }

        private func create() throws -> URL {
            if let stageURL { return stageURL }
            let fm = FileManager.default
            var candidates = [source.deletingLastPathComponent()]
            if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first { candidates.append(downloads) }
            candidates.append(fm.temporaryDirectory)
            var failure = "没有可以保存的目录"
            var tried = Set<String>()
            for dir in candidates where tried.insert(dir.standardizedFileURL.path).inserted {
                let pfd = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard pfd >= 0 else { failure = "\(dir.path)：\(Out.reason(errno))"; continue }
                if let why = Self.exposure(of: pfd) {
                    failure = "\(dir.path)：\(why)"
                    close(pfd)
                    continue
                }
                for _ in 0..<5 {
                    let name = ".FormatWheel-" + UUID().uuidString
                    if mkdirat(pfd, name, 0o700) != 0 {
                        if errno == EEXIST { continue }
                        failure = "\(dir.path)：\(Out.reason(errno))"
                        break
                    }
                    let sfd = openat(pfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard sfd >= 0 else {
                        failure = "\(dir.path)：\(Out.reason(errno))"
                        unlinkat(pfd, name, AT_REMOVEDIR)
                        break
                    }
                    parentURL = dir
                    parentFD = pfd
                    stageFD = sfd
                    stageURL = dir.appendingPathComponent(name, isDirectory: true)
                    return stageURL!
                }
                close(pfd)
            }
            throw FWError("没法保存结果，\(failure)")
        }

        /// A folder others can write to (without the sticky bit) would let them move our staging directory away.
        /// Volumes mounted "ignore ownership" have no per-user permissions to judge by.
        private static func exposure(of fd: Int32) -> String? {
            var fs = statfs()
            if fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 { return nil }
            var st = stat()
            guard fstat(fd, &st) == 0 else { return Out.reason(errno) }
            let mode = st.st_mode
            if mode & mode_t(S_IWGRP | S_IWOTH) != 0, mode & mode_t(S_ISVTX) == 0 { return "目录允许其他用户写入" }
            return nil
        }
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
