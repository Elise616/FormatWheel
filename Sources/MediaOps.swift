import AVFoundation
import Foundation

/// Video and audio. AVFoundation handles what it can natively (fast, hardware encoders);
/// ffmpeg covers the rest when it is installed.
enum MediaOps {
    // MARK: - Plumbing

    static func ffmpeg() throws -> String {
        guard let path = Shell.ffmpeg else { throw FWError(Shell.installHint("ffmpeg")) }
        return path
    }

    static func duration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 { return d.seconds }
        if let probe = Shell.find("ffprobe"),
           let s = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", url.path]),
           let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return d
        }
        return 0
    }

    /// Video stream bitrate in bits per second (0 when unknown).
    static func videoBitrate(_ url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            return Int(rate)
        }
        if let probe = Shell.find("ffprobe"),
           let s = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format=bit_rate", "-of", "default=nw=1:nk=1", url.path]),
           let rate = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return rate
        }
        return 0
    }

    static func sampleRate(_ url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = try? await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format), basic.pointee.mSampleRate > 0 {
            return Int(basic.pointee.mSampleRate)
        }
        return 48_000
    }

    /// True when AVFoundation can decode the file's video.
    static func avVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { return false }
        return !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
    }

    static func avAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { return false }
        return !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
    }

    static func ff(_ input: URL, _ args: [String], out: URL, limit: Double? = nil, progress: @escaping ProgressFn) async throws {
        let exe = try ffmpeg()
        var total = await duration(input)
        if let limit, total > 0 { total = min(total, limit) }
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats", "-i", input.path] + args + [out.path]
        do {
            try await Shell.run(exe, full) { line in
                guard total > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                progress(min(1, max(0, us / 1_000_000 / total)))
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    static func export(_ asset: AVAsset, preset: String, type: AVFileType, out: URL,
                       timeRange: CMTimeRange? = nil, progress: @escaping ProgressFn,
                       configure: ((AVAssetExportSession) -> Void)? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FWError("系统编码器处理不了这个文件")
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        configure?(session)
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        poll.cancel()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw FWError(session.error?.localizedDescription ?? "导出失败")
        }
    }

    /// Re-wraps without re-encoding when the codecs fit the container, otherwise re-encodes.
    static func exportBest(_ url: URL, type: AVFileType, out: URL, progress: @escaping ProgressFn) async throws {
        let asset = AVURLAsset(url: url)
        let canPass = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: type)
        try await export(asset, preset: canPass ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality,
                         type: type, out: out, progress: progress)
    }

    static func scaleFilter(maxSide: Int) -> String {
        "scale='if(gt(iw,ih),min(\(maxSide),iw),-2)':'if(gt(iw,ih),-2,min(\(maxSide),ih))':flags=lanczos"
    }

    // MARK: - Video

    static func video(_ id: String, _ url: URL, progress: @escaping ProgressFn) async throws -> OpResult {
        let native = await avVideo(url)
        let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        switch id {
        case "vid.to.mp4":
            let out = Out.url(for: url, ext: "mp4")
            if native { try await exportBest(url, type: .mp4, out: out, progress: progress) }
            else { try await ff(url, h264, out: out, progress: progress) }
            return OpResult(outputs: [out])

        case "vid.to.mov":
            let out = Out.url(for: url, ext: "mov")
            if native { try await exportBest(url, type: .mov, out: out, progress: progress) }
            else { try await ff(url, h264.filter { $0 != "-movflags" && $0 != "+faststart" }, out: out, progress: progress) }
            return OpResult(outputs: [out])

        case "vid.to.hevc":
            let out = Out.url(for: url, suffix: "HEVC", ext: "mp4")
            if Shell.ffmpeg != nil {
                // HEVC holds the same quality at roughly half the H.264 bitrate, so aim there
                // (the system "highest quality" preset often comes out *bigger* than the source).
                let source = await videoBitrate(url)
                let target = max(1_200_000, min(25_000_000, (source > 0 ? source : 8_000_000) / 2))
                try await ff(url, ["-c:v", "hevc_videotoolbox", "-b:v", String(target), "-tag:v", "hvc1",
                                   "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"], out: out, progress: progress)
            } else if native {
                try await export(AVURLAsset(url: url), preset: AVAssetExportPresetHEVCHighestQuality, type: .mp4, out: out, progress: progress)
            } else {
                throw FWError(Shell.installHint("ffmpeg"))
            }
            return OpResult(outputs: [out])

        case "vid.to.webm":
            let out = Out.url(for: url, ext: "webm")
            try await ff(url, ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                               "-c:a", "libopus", "-b:a", "128k"], out: out, progress: progress)
            return OpResult(outputs: [out])

        case "vid.to.gif":
            let out = Out.url(for: url, ext: "gif")
            let length = await duration(url)
            if Shell.ffmpeg != nil {
                let graph = "fps=12,\(scaleFilter(maxSide: 540)),split[a][b];[a]palettegen=max_colors=200:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
                try await ff(url, ["-t", "30", "-filter_complex", graph, "-loop", "0"], out: out, limit: 30, progress: progress)
            } else {
                try await nativeGIF(url, out: out, progress: progress)
            }
            return OpResult(outputs: [out], note: length > 30 ? "只取了前 30 秒" : nil)

        case "vid.to.mp3":
            let out = Out.url(for: url, ext: "mp3")
            try await ff(url, ["-vn", "-c:a", "libmp3lame", "-q:a", "2"], out: out, progress: progress)
            return OpResult(outputs: [out])

        case "vid.to.m4a":
            let out = Out.url(for: url, ext: "m4a")
            if await avAudio(url) {
                try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, type: .m4a, out: out, progress: progress)
            } else {
                try await ff(url, ["-vn", "-c:a", "aac", "-b:a", "192k"], out: out, progress: progress)
            }
            return OpResult(outputs: [out])

        case "vid.to.wav":
            let out = Out.url(for: url, ext: "wav")
            try await ff(url, ["-vn", "-c:a", "pcm_s16le"], out: out, progress: progress)
            return OpResult(outputs: [out])

        case "vid.compress":
            let out = Out.url(for: url, suffix: "压缩", ext: "mp4")
            if Shell.ffmpeg != nil {
                try await ff(url, ["-c:v", "libx264", "-preset", "faster", "-crf", "27", "-vf", scaleFilter(maxSide: 1920), "-pix_fmt", "yuv420p",
                                   "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"], out: out, progress: progress)
            } else {
                try await export(AVURLAsset(url: url), preset: AVAssetExportPreset1280x720, type: .mp4, out: out, progress: progress)
            }
            return try ImageOps.shrinkResult(source: url, output: out)

        case "vid.mute":
            if Shell.ffmpeg != nil {
                let ext = ["mp4", "mov", "m4v", "mkv", "webm"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "mp4"
                let out = Out.url(for: url, suffix: "静音", ext: ext)
                try await ff(url, ["-map", "0:v", "-c", "copy", "-an"], out: out, progress: progress)
                return OpResult(outputs: [out])
            }
            let out = Out.url(for: url, suffix: "静音", ext: "mov")
            try await muteNative(url, out: out, progress: progress)
            return OpResult(outputs: [out])

        case "vid.720p":
            let out = Out.url(for: url, suffix: "720P", ext: "mp4")
            if native {
                try await export(AVURLAsset(url: url), preset: AVAssetExportPreset1280x720, type: .mp4, out: out, progress: progress)
            } else {
                try await ff(url, ["-vf", scaleFilter(maxSide: 1280)] + h264, out: out, progress: progress)
            }
            return OpResult(outputs: [out])

        case "vid.cover":
            let out = Out.url(for: url, suffix: "封面", ext: "jpg")
            let length = await duration(url)
            let at = length > 2 ? min(1.0, length * 0.1) : 0
            if native {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                let frame = try await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
                try await ImageOps.write(frame, to: out, fmt: "jpg", quality: 0.92)
            } else {
                try await ff(url, ["-ss", String(at), "-frames:v", "1", "-q:v", "2"], out: out, progress: progress)
            }
            return OpResult(outputs: [out])

        case "vid.fast", "vid.slow":
            let fast = id == "vid.fast"
            let out = Out.url(for: url, suffix: fast ? "2倍速" : "慢放", ext: "mp4")
            try await ff(url, ["-filter:v", fast ? "setpts=0.5*PTS" : "setpts=2.0*PTS", "-filter:a", fast ? "atempo=2.0" : "atempo=0.5",
                               "-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
                               "-movflags", "+faststart"], out: out, progress: { p in progress(fast ? min(1, p * 2) : p / 2) })
            return OpResult(outputs: [out])

        default:
            throw FWError("未知操作 \(id)")
        }
    }

    /// GIF without ffmpeg: sample frames with AVFoundation and encode with ImageIO.
    static func nativeGIF(_ url: URL, out: URL, progress: ProgressFn) async throws {
        let asset = AVURLAsset(url: url)
        let length = min(await duration(url), 30)
        guard length > 0 else { throw FWError("读不出视频长度") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 540, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let fps = 10.0
        let count = max(1, Int(length * fps))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw FWError("无法创建 GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let frame = try await generator.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)).image
            CGImageDestinationAddImage(dest, frame, frameProps)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw FWError("GIF 写入失败") }
    }

    static func muteNative(_ url: URL, out: URL, progress: @escaping ProgressFn) async throws {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            target.preferredTransform = try await track.load(.preferredTransform)
        }
        try await export(composition, preset: AVAssetExportPresetPassthrough, type: .mov, out: out, progress: progress)
    }

    // MARK: - Audio

    /// Codec arguments that keep an audio file in its own format.
    static func sameFormatAudio(_ url: URL) -> (ext: String, args: [String]) {
        switch Catalog.canonicalExt(url.pathExtension) {
        case "mp3": return ("mp3", ["-c:a", "libmp3lame", "-q:a", "2"])
        case "wav": return ("wav", ["-c:a", "pcm_s16le"])
        case "aiff": return ("aiff", ["-c:a", "pcm_s16be"])
        case "flac": return ("flac", ["-c:a", "flac"])
        case "opus": return ("opus", ["-c:a", "libopus", "-b:a", "128k"])
        default: return ("m4a", ["-c:a", "aac", "-b:a", "192k"])
        }
    }

    static func afconvert(_ input: URL, _ args: [String], out: URL) async throws {
        do {
            try await Shell.run("/usr/bin/afconvert", args + [input.path, out.path])
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// Tries Core Audio's afconvert first, then ffmpeg for formats it can't read.
    static func audioVia(_ input: URL, out: URL, af: [String], ff ffArgs: [String], progress: @escaping ProgressFn) async throws {
        do {
            try await afconvert(input, af, out: out)
        } catch {
            guard Shell.ffmpeg != nil else { throw error }
            try await ff(input, ["-vn"] + ffArgs, out: out, progress: progress)
        }
    }

    static func audio(_ id: String, _ url: URL, progress: @escaping ProgressFn) async throws -> OpResult {
        switch id {
        case "aud.to.mp3":
            let out = Out.url(for: url, ext: "mp3")
            try await ff(url, ["-vn", "-c:a", "libmp3lame", "-q:a", "2"], out: out, progress: progress)
            return OpResult(outputs: [out])
        case "aud.to.m4a":
            let out = Out.url(for: url, ext: "m4a")
            try await audioVia(url, out: out, af: ["-f", "m4af", "-d", "aac", "-b", "256000"], ff: ["-c:a", "aac", "-b:a", "256k"], progress: progress)
            return OpResult(outputs: [out])
        case "aud.to.wav":
            let out = Out.url(for: url, ext: "wav")
            try await audioVia(url, out: out, af: ["-f", "WAVE", "-d", "LEI16"], ff: ["-c:a", "pcm_s16le"], progress: progress)
            return OpResult(outputs: [out])
        case "aud.to.aiff":
            let out = Out.url(for: url, ext: "aiff")
            try await audioVia(url, out: out, af: ["-f", "AIFF", "-d", "BEI16"], ff: ["-c:a", "pcm_s16be"], progress: progress)
            return OpResult(outputs: [out])
        case "aud.to.flac":
            let out = Out.url(for: url, ext: "flac")
            try await audioVia(url, out: out, af: ["-f", "flac", "-d", "flac"], ff: ["-c:a", "flac"], progress: progress)
            return OpResult(outputs: [out])
        case "aud.to.opus":
            let out = Out.url(for: url, ext: "opus")
            try await ff(url, ["-vn", "-c:a", "libopus", "-b:a", "128k"], out: out, progress: progress)
            return OpResult(outputs: [out])
        case "aud.to.alac":
            let out = Out.url(for: url, suffix: "无损", ext: "m4a")
            try await audioVia(url, out: out, af: ["-f", "m4af", "-d", "alac"], ff: ["-c:a", "alac"], progress: progress)
            return OpResult(outputs: [out])
        case "aud.to.m4r":
            let out = Out.url(for: url, suffix: "铃声", ext: "m4r")
            let length = await duration(url)
            if await avAudio(url) {
                let range = CMTimeRange(start: .zero, duration: CMTime(seconds: min(40, max(length, 1)), preferredTimescale: 600))
                let tmp = try Out.tempDir().appendingPathComponent("tone.m4a")
                try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, type: .m4a, out: tmp, timeRange: range, progress: progress)
                try FileManager.default.moveItem(at: tmp, to: out)
            } else {
                try await ff(url, ["-vn", "-t", "40", "-c:a", "aac", "-b:a", "256k", "-f", "ipod"], out: out, limit: 40, progress: progress)
            }
            return OpResult(outputs: [out], note: length > 40 ? "截取了前 40 秒" : nil)
        case "aud.compress":
            let out = Out.url(for: url, suffix: "压缩", ext: "m4a")
            try await audioVia(url, out: out, af: ["-f", "m4af", "-d", "aac", "-b", "96000"], ff: ["-c:a", "aac", "-b:a", "96k"], progress: progress)
            return try ImageOps.shrinkResult(source: url, output: out)
        case "aud.mono", "aud.loud", "aud.fast":
            let same = sameFormatAudio(url)
            let rate = await sampleRate(url)
            let (suffix, filter): (String, [String]) = {
                switch id {
                case "aud.mono": return ("单声道", ["-ac", "1"])
                // loudnorm upsamples to 192 kHz internally; write back at the source rate.
                case "aud.loud": return ("响度统一", ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", String(rate)])
                default: return ("1.5倍速", ["-af", "atempo=1.5"])
                }
            }()
            let out = Out.url(for: url, suffix: suffix, ext: same.ext)
            try await ff(url, ["-vn"] + filter + same.args, out: out, progress: { p in progress(id == "aud.fast" ? min(1, p * 1.5) : p) })
            return OpResult(outputs: [out])
        default:
            throw FWError("未知操作 \(id)")
        }
    }
}
