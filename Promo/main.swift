import AppKit

// Renders the launch film. `--frames 1.0,5.5 --out dir` writes stills for checking;
// otherwise every frame is piped to ffmpeg and two cuts are written next to `--out`.
let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
    return arguments[i + 1]
}

_ = NSApplication.shared
let film = Film()
let fps = 60.0
let width = Int(W), height = Int(H)
guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                             space: Art.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let stage = Stage(context: canvas)

func frame(at t: Double) {
    canvas.saveGState()
    film.draw(stage, at: t)
    canvas.restoreGState()
}

if let list = option("--frames") {
    let folder = URL(fileURLWithPath: option("--out") ?? ".")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for item in list.split(separator: ",") {
        guard let t = Double(item) else { continue }
        frame(at: t)
        guard let image = canvas.makeImage() else { continue }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("frame-\(item).png"))
    }
    exit(0)
}

guard let ffmpeg = Shell.ffmpeg else {
    FileHandle.standardError.write(Data("ffmpeg is needed to encode the film\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: option("--out") ?? "宣传片/格式轮盘-宣传片.mp4")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("formatwheel-promo")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let silent = work.appendingPathComponent("video.mp4")

// 1. Picture (skipped with --audio-only when the previous render's picture is still there).
let audioOnly = arguments.contains("--audio-only") && FileManager.default.fileExists(atPath: silent.path)
let started = Date()
if !audioOnly {
let encoder = Process()
encoder.executableURL = URL(fileURLWithPath: ffmpeg)
encoder.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)",
                     "-r", "\(Int(fps))", "-i", "-", "-c:v", "libx264", "-preset", "medium", "-tune", "animation", "-crf", "18", "-pix_fmt", "yuv420p",
                     "-movflags", "+faststart", silent.path]
let pipe = Pipe()
encoder.standardInput = pipe
try encoder.run()
let frames = Int(film.duration * fps)
for index in 0..<frames {
    frame(at: Double(index) / fps)
    if let data = canvas.data {
        pipe.fileHandleForWriting.write(Data(bytesNoCopy: data, count: width * height * 4, deallocator: .none))
    }
    if index % 300 == 0 {
        print(String(format: "frame %d/%d  (%.0fs)", index, frames, Date().timeIntervalSince(started)))
        fflush(stdout)
    }
}
try pipe.fileHandleForWriting.close()
encoder.waitUntilExit()
guard encoder.terminationStatus == 0 else { exit(2) }
}

// 2. Sound: effects only, so music can be laid under it in an editor; `--with-music` adds a cut with the synth beat.
var cuts: [(suffix: String, music: Bool)] = [("", false)]
if arguments.contains("--with-music") { cuts.append(("-合成配乐", true)) }
for cut in cuts {
    let wav = work.appendingPathComponent("audio\(cut.music ? "" : "-fx").wav")
    try Score.wav(Score.render(duration: film.duration, cues: film.cues, withMusic: cut.music)).write(to: wav)
    let base = out.deletingPathExtension().lastPathComponent + cut.suffix
    let target = out.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("mp4")
    let mux = Process()
    mux.executableURL = URL(fileURLWithPath: ffmpeg)
    mux.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", silent.path, "-i", wav.path, "-c:v", "copy",
                     "-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", target.path]
    try mux.run()
    mux.waitUntilExit()
    print("wrote \(target.path)")
}
print(String(format: "done in %.0fs", Date().timeIntervalSince(started)))
