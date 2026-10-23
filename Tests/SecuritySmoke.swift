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

// MARK: - Tool trust

print("Shell.trustFailure")
func mode(_ path: String, _ value: mode_t) { chmod(path, value) }
func run(_ launch: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
}

do {
    let tools = try dir("tools")
    mode(tools.path, 0o755)
    func script(_ name: String, marker: String? = nil) throws -> String {
        let url = tools.appendingPathComponent(name)
        try "#!/bin/sh\n\(marker.map { "touch '\($0)'" } ?? "true")\n".write(to: url, atomically: true, encoding: .utf8)
        mode(url.path, 0o755)
        return url.path
    }
    let tool = try script("tool")
    check(Shell.trustFailure(at: URL(fileURLWithPath: tool)) == nil, "own 0755 tool rejected: \(Shell.trustFailure(at: URL(fileURLWithPath: tool)) ?? "")")
    check(Shell.trustFailure(at: URL(fileURLWithPath: "/usr/bin/ditto")) == nil, "system tool rejected")

    mode(tool, 0o777)
    check(Shell.trustFailure(at: URL(fileURLWithPath: tool)) != nil, "world-writable tool accepted")
    mode(tool, 0o755)

    // Group write is refused for ordinary groups, tolerated for admin (gid 80).
    var st = stat()
    stat(tool, &st)
    if st.st_gid != 0, st.st_gid != 80 {
        mode(tool, 0o775)
        check(Shell.trustFailure(at: URL(fileURLWithPath: tool)) != nil, "group-writable tool accepted")
        mode(tool, 0o755)
    }
    if chown(tool, uid_t.max, 80) == 0 {
        mode(tool, 0o775)
        check(Shell.trustFailure(at: URL(fileURLWithPath: tool)) == nil, "admin-group tool rejected")
        mode(tool, 0o755)
        chown(tool, uid_t.max, st.st_gid)
    }

    mode(tools.path, 0o777)
    check(Shell.trustFailure(at: URL(fileURLWithPath: tool)) != nil, "tool in world-writable folder accepted")
    mode(tools.path, 0o755)

    // Symlinks are judged by where they lead.
    let link = tools.appendingPathComponent("link")
    try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: tool))
    check(Shell.trustFailure(at: link) == nil, "link to safe tool rejected")
    let loose = try script("loose")
    mode(loose, 0o777)
    let badLink = tools.appendingPathComponent("bad-link")
    try fm.createSymbolicLink(at: badLink, withDestinationURL: URL(fileURLWithPath: loose))
    check(Shell.trustFailure(at: badLink) != nil, "link to unsafe tool accepted")
    let loop = tools.appendingPathComponent("loop")
    try fm.createSymbolicLink(at: loop, withDestinationURL: loop)
    check(Shell.trustFailure(at: loop) != nil, "symlink loop accepted")

    // ACLs: an allow entry that grants write is refused, a deny-only entry is not a grant.
    let aclTool = try script("acl-allow")
    run("/bin/chmod", ["+a", "everyone allow write", aclTool])
    check(Shell.trustFailure(at: URL(fileURLWithPath: aclTool)) != nil, "ACL write grant accepted")
    let denyTool = try script("acl-deny")
    run("/bin/chmod", ["+a", "everyone deny delete", denyTool])
    check(Shell.trustFailure(at: URL(fileURLWithPath: denyTool)) == nil, "deny-only ACL rejected")

    // A permission change after a successful check is caught when the tool is actually launched.
    let marker = tools.appendingPathComponent("ran")
    let runner = try script("runner", marker: marker.path)
    _ = try await Shell.run(runner, [])
    check(fm.fileExists(atPath: marker.path), "trusted tool did not run")
    try fm.removeItem(at: marker)
    mode(runner, 0o777)
    var refused = false
    do { _ = try await Shell.run(runner, []) } catch { refused = true }
    check(refused && !fm.fileExists(atPath: marker.path), "tool ran after becoming world-writable")
}


if failures.isEmpty {
    print("security smoke: all checks passed")
} else {
    print("security smoke: \(failures.count) failed")
    exit(1)
}
