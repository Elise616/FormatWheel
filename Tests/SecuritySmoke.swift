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

// MARK: - End to end through Engine.run

print("Engine.run")
func makeImage(_ url: URL, type: UTType) throws {
    let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 22.3, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 114.2, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "TestCam"],
    ]
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
}
func leaks(_ url: URL) -> (gps: Bool, model: Bool) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (false, false) }
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    return (props[kCGImagePropertyGPSDictionary] != nil, tiff?[kCGImagePropertyTIFFModel] != nil)
}
func count(_ needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }

do {
    let d = try dir("engine")
    let png = d.appendingPathComponent("p.png"), jpg = d.appendingPathComponent("j.jpg")
    try makeImage(png, type: .png)
    try makeImage(jpg, type: .jpeg)
    check(leaks(png).gps && leaks(jpg).gps, "fixture lacks GPS")

    // Conversions keep the metadata and say so exactly once, even for a batch.
    let converted = try await Engine.run("img.to.tiff", label: "TIFF", files: [png, jpg]) { _ in }
    check(converted.outputs.count == 2 && converted.outputs.allSatisfy { leaks($0).gps }, "conversion dropped metadata")
    // 去隐私 must really remove GPS and camera tags in every format it accepts, and only claim its scope.
    let tiff = converted.outputs.first { $0.pathExtension == "tiff" }!
    let stripped = try await Engine.run("img.strip", label: "去隐私", files: [png, jpg, tiff]) { _ in }
    check(stripped.outputs.count == 3, "strip outputs: \(stripped.outputs.count)")
    for out in stripped.outputs {
        let found = leaks(out)
        check(!found.gps && !found.model, "\(out.lastPathComponent) still has GPS=\(found.gps) model=\(found.model)")
    }
    check(count(Privacy.imageNote, in: stripped.detail) == 1, "strip note count in: \(stripped.detail)")
    check(!stripped.detail.contains("已解除") && !stripped.detail.contains("抹掉"), "strip over-promises: \(stripped.detail)")
}
do {
    // Word: author fields are cleared, comment authors are not, and the result says so.
    let d = try dir("docx")
    let pack = try dir("docx-pack")
    for sub in ["_rels", "word", "docProps"] { try fm.createDirectory(at: pack.appendingPathComponent(sub), withIntermediateDirectories: true) }
    let files = [
        "[Content_Types].xml": "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/></Types>",
        "_rels/.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>",
        "word/document.xml": "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body/></w:document>",
        "word/comments.xml": "<w:comments xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:comment w:id=\"0\" w:author=\"CommentAuthor\"/></w:comments>",
        "docProps/core.xml": "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator>Alice</dc:creator><cp:lastModifiedBy>Bob</cp:lastModifiedBy></cp:coreProperties>",
        "docProps/app.xml": "<Properties><Company>ACME</Company></Properties>",
    ]
    for (name, body) in files { try body.write(to: pack.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    let docx = d.appendingPathComponent("t.docx")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-qr", docx.path] + files.keys.map { $0 }
    zip.currentDirectoryURL = pack
    try zip.run()
    zip.waitUntilExit()

    let summary = try await Engine.run("doc.strip", label: "去隐私", files: [docx, docx]) { _ in }
    check(summary.outputs.count == 2, "docx outputs: \(summary.outputs.count)")
    func part(_ name: String, of url: URL) async -> String { (try? await Shell.run("/usr/bin/unzip", ["-p", url.path, name])) ?? "" }
    let core = await part("docProps/core.xml", of: summary.outputs[0])
    let comments = await part("word/comments.xml", of: summary.outputs[0])
    let app = await part("docProps/app.xml", of: summary.outputs[0])
    check(!core.contains("Alice") && !core.contains("Bob") && !app.contains("ACME"), "docx author fields remain")
    check(comments.contains("CommentAuthor"), "comments unexpectedly changed")
    check(count(Privacy.docxNote, in: summary.detail) == 1 && summary.detail.contains("不含批注"), "docx note in: \(summary.detail)")
}


if failures.isEmpty {
    print("security smoke: all checks passed")
} else {
    print("security smoke: \(failures.count) failed")
    exit(1)
}
