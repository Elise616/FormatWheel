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
    private static var rejected: [String: String] = [:]
    private static let lock = NSLock()

    /// First searched location of `name` that passes `trustFailure`.
    static func find(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = found[name] { return hit }
        var path: String?
        for dir in searchPaths {
            let candidate = "\(dir)/\(name)"
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let why = trustFailure(at: URL(fileURLWithPath: candidate)) {
                if rejected[name] == nil { rejected[name] = why }
                continue
            }
            path = candidate
            rejected[name] = nil
            break
        }
        found[name] = path
        return path
    }

    static func has(_ name: String) -> Bool { find(name) != nil }
    static var ffmpeg: String? { find("ffmpeg") }
    static var cwebp: String? { find("cwebp") }

    /// Why an installed `name` was refused (unsafe permissions), or nil if it is simply missing or fine.
    static func rejection(_ name: String) -> String? {
        if find(name) != nil { return nil }
        lock.lock()
        defer { lock.unlock() }
        return rejected[name]
    }

    static func installHint(_ name: String) -> String {
        if let why = rejection(name) { return "\(name) 位置权限不安全：\(why)" }
        let formula = name == "cwebp" ? "webp" : name
        return "需要先装 \(name)：终端运行 brew install \(formula)"
    }

    /// Why a tool path can't be trusted, or nil. Every directory on the way (following symlinks) and the
    /// final regular file must belong to root or this user, and nobody else may be able to write them:
    /// no other-write bit, group-write only for `admin`/`wheel` (administrators can become root anyway),
    /// and no ACL entry that grants write-like rights. This keeps another account from swapping the tool;
    /// it does not defend against the same account or root.
    static func trustFailure(at url: URL) -> String? {
        var current = "/"
        var rest = Array(url.path.split(separator: "/").map(String.init).reversed())
        var links = 0
        var st = stat()
        guard lstat("/", &st) == 0 else { return "无法读取 /" }
        if let why = unsafe(st, "/", file: false) { return why }
        while let component = rest.popLast() {
            if component == "." { continue }
            if component == ".." {
                current = (current as NSString).deletingLastPathComponent
                if current.isEmpty { current = "/" }
                continue
            }
            let path = current == "/" ? "/" + component : current + "/" + component
            guard lstat(path, &st) == 0 else { return "无法读取 \(path)" }
            if st.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                links += 1
                guard links <= 40 else { return "符号链接层数过多：\(url.path)" }
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = readlink(path, &buffer, Int(PATH_MAX))
                guard length > 0 else { return "无法读取符号链接 \(path)" }
                let target = String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if target.hasPrefix("/") { current = "/" }
                rest.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
                continue
            }
            if let why = unsafe(st, path, file: rest.isEmpty) { return why }
            current = path
        }
        return nil
    }

    private static func unsafe(_ st: stat, _ path: String, file: Bool) -> String? {
        let mode = st.st_mode
        if file {
            guard mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return "\(path) 不是普通文件" }
            guard access(path, X_OK) == 0 else { return "\(path) 不可执行" }
        } else {
            guard mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return "\(path) 不是目录" }
        }
        guard st.st_uid == 0 || st.st_uid == geteuid() else { return "\(path) 属于其他用户" }
        if mode & mode_t(S_IWOTH) != 0 { return "\(path) 允许任何用户写入" }
        if mode & mode_t(S_IWGRP) != 0, st.st_gid != 0, st.st_gid != 80 { return "\(path) 允许用户组 \(st.st_gid) 写入" }
        return aclWriteGrant(path)
    }

    private static func aclWriteGrant(_ path: String) -> String? {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT || errno == EOPNOTSUPP ? nil : "无法读取 \(path) 的访问控制列表"
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writing = [ACL_WRITE_DATA, ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                       ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        var entry: acl_entry_t?
        var which = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, which, &entry) == 0, let current = entry {
            which = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(current, &tag) == 0 else { return "无法读取 \(path) 的访问控制列表" }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            var permissions: acl_permset_t?
            guard acl_get_permset(current, &permissions) == 0, let permissions else { return "无法读取 \(path) 的访问控制列表" }
            if writing.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) { return "\(path) 的访问控制列表授予了写入权限" }
        }
        return nil
    }

    /// Runs a tool to completion. `onLine` receives stdout line by line (used for ffmpeg progress).
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        if let why = trustFailure(at: URL(fileURLWithPath: executable)) {
            throw FWError("\(URL(fileURLWithPath: executable).lastPathComponent) 位置权限不安全：\(why)")
        }
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
