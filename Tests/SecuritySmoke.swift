// Security smoke test. Run with Tests/run-security-smoke.sh: the script compiles Sources/ (minus main.swift)
// with this file as the entry point. Exits non-zero when any check fails.
import AppKit
import ImageIO
import UniformTypeIdentifiers

var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { failures.append(message()); print("  FAIL: \(message())") }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("fw-smoke-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func dir(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

// MARK: - Output publishing

print("Out.staged")
do {
    // Existing file is kept, the new result gets the next free name.
    let d = try dir("exist")
    let source = d.appendingPathComponent("a.png")
    try "orig".write(to: d.appendingPathComponent("a.jpg"), atomically: true, encoding: .utf8)
    let result = try await Out.staged(near: source) {
        let out = try Out.url(for: source, ext: "jpg")
        try "new".write(to: out, atomically: true, encoding: .utf8)
        return OpResult(outputs: [out])
    }
    check(result.outputs.map(\.lastPathComponent) == ["a 2.jpg"], "collision name: \(result.outputs.map(\.lastPathComponent))")
    check(text(d.appendingPathComponent("a.jpg")) == "orig", "existing file overwritten")
    check(text(result.outputs[0]) == "new", "published content")
    check(names(d) == ["a 2.jpg", "a.jpg"], "stray entries: \(names(d))")
}
do {
    // A dangling symlink at the predicted name must not be written through.
    let d = try dir("dangling")
    let source = d.appendingPathComponent("b.png")
    let sentinel = d.appendingPathComponent("sentinel-target")
    try fm.createSymbolicLink(at: d.appendingPathComponent("b.jpg"), withDestinationURL: sentinel)
    let result = try await Out.staged(near: source) {
        let out = try Out.url(for: source, ext: "jpg")
        try "new".write(to: out, atomically: true, encoding: .utf8)
        return OpResult(outputs: [out])
    }
    check(result.outputs.map(\.lastPathComponent) == ["b 2.jpg"], "dangling symlink name: \(result.outputs.map(\.lastPathComponent))")
    check(!fm.fileExists(atPath: sentinel.path), "symlink target was created")
    check((try? fm.destinationOfSymbolicLink(atPath: d.appendingPathComponent("b.jpg").path)) == sentinel.path, "symlink was replaced")
}
do {
    // Folder outputs collide the same way and move as a whole.
    let d = try dir("folder")
    let source = d.appendingPathComponent("c.pdf")
    try fm.createDirectory(at: d.appendingPathComponent("c PNG"), withIntermediateDirectories: false)
    let result = try await Out.staged(near: source) {
        let folder = try Out.folder(for: source, suffix: "PNG")
        try "page".write(to: folder.appendingPathComponent("c-1.png"), atomically: true, encoding: .utf8)
        return OpResult(outputs: [folder])
    }
    check(result.outputs.map(\.lastPathComponent) == ["c PNG 2"], "folder name: \(result.outputs.map(\.lastPathComponent))")
    check(text(d.appendingPathComponent("c PNG 2/c-1.png")) == "page", "folder content")
    check(names(d.appendingPathComponent("c PNG")).isEmpty, "existing folder modified")
}
do {
    // Parallel transactions for the same source never share a name.
    let d = try dir("parallel")
    let source = d.appendingPathComponent("p.png")
    let published = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
        for i in 0..<8 {
            group.addTask {
                let r = try await Out.staged(near: source) {
                    let out = try Out.url(for: source, ext: "jpg")
                    try "job\(i)".write(to: out, atomically: true, encoding: .utf8)
                    return OpResult(outputs: [out])
                }
                return (i, r.outputs[0])
            }
        }
        var all: [(Int, URL)] = []
        for try await item in group { all.append(item) }
        return all
    }
    check(Set(published.map(\.1.lastPathComponent)).count == 8, "parallel jobs shared names")
    check(published.allSatisfy { text($0.1) == "job\($0.0)" }, "parallel job content mixed up")
    check(names(d).count == 8, "parallel leftovers: \(names(d))")
}
do {
    // Read-only actions touch nothing; failures publish nothing and clean up.
    let d = try dir("quiet")
    let source = d.appendingPathComponent("q.txt")
    _ = try await Out.staged(near: source) { OpResult(note: "no output") }
    check(names(d).isEmpty, "stage created without a claim: \(names(d))")
    struct Boom: Error {}
    do {
        _ = try await Out.staged(near: source) {
            let out = try Out.url(for: source, ext: "jpg")
            try "half".write(to: out, atomically: true, encoding: .utf8)
            throw Boom()
        }
        check(false, "failure was swallowed")
    } catch is Boom {}
    check(names(d).isEmpty, "failed job left files: \(names(d))")
}
do {
    // A declared output that was never written is caught before anything is published.
    let d = try dir("missing")
    let source = d.appendingPathComponent("m.png")
    do {
        _ = try await Out.staged(near: source) {
            let first = try Out.url(for: source, suffix: "1", ext: "jpg")
            let second = try Out.url(for: source, suffix: "2", ext: "jpg")
            try "one".write(to: first, atomically: true, encoding: .utf8)
            return OpResult(outputs: [first, second])
        }
        check(false, "missing output accepted")
    } catch {}
    check(names(d).isEmpty, "partial publish: \(names(d))")
}
do {
    let source = root.appendingPathComponent("x.png")
    var threw = false
    do { _ = try Out.url(for: source, ext: "jpg") } catch { threw = true }
    check(threw, "Out.url worked outside a transaction")
}


if failures.isEmpty {
    print("security smoke: all checks passed")
} else {
    print("security smoke: \(failures.count) failed")
    exit(1)
}
