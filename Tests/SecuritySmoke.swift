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
    check(count(ImageOps.metadataWarning, in: converted.detail) == 1, "metadata warning count in: \(converted.detail)")


}

if failures.isEmpty {
    print("security smoke: all checks passed")
} else {
    print("security smoke: \(failures.count) failed")
    exit(1)
}
