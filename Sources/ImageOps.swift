import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

struct LoadedImage {
    let cg: CGImage
    let props: [CFString: Any]
}

enum ImageOps {
    static let writers: [String: UTType] = ["png": .png, "jpg": .jpeg, "heic": .heic, "tiff": .tiff, "gif": .gif, "bmp": .bmp]

    // MARK: - Reading and writing

    /// Decodes the primary image with its EXIF orientation already applied.
    static func load(_ url: URL) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw FWError("打不开这张图片")
        }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(src, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            image = CGImageSourceCreateThumbnailAtIndex(src, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image else { throw FWError("图片解码失败") }
        return LoadedImage(cg: image, props: props)
    }

    /// Metadata worth keeping across a conversion; orientation is reset because pixels are already upright.
    static func carryOver(_ props: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            out[kCGImagePropertyExifDictionary] = exif
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let v = props[key] { out[key] = v }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        return out
    }

    static func lossyQuality(_ fmt: String) -> Double? {
        switch fmt {
        case "jpg": return 0.9
        case "heic": return 0.82
        case "webp": return 0.84
        case "avif": return 0.62
        default: return nil
        }
    }

    /// The format to write when a tool keeps "the same" format as the source.
    static func sameFormat(_ url: URL) -> String {
        let ext = Catalog.canonicalExt(url.pathExtension)
        switch ext {
        case "jpg", "png", "heic", "tiff", "gif", "bmp": return ext
        case "webp": return Shell.cwebp != nil ? "webp" : "png"
        case "avif": return Shell.ffmpeg != nil ? "avif" : "png"
        default: return "png"
        }
    }

    static func write(_ image: CGImage, to url: URL, fmt: String, quality: Double? = nil, props: [CFString: Any] = [:]) async throws {
        switch fmt {
        case "webp": try await writeWebP(image, to: url, quality: quality ?? 0.84)
        case "avif": try await writeAVIF(image, to: url, quality: quality ?? 0.62)
        case "pdf": try PDFMaker.write([image], to: url)
        default:
            guard let type = writers[fmt] else { throw FWError("不支持写入 \(fmt.uppercased())") }
            let pixels = (fmt == "jpg" || fmt == "bmp") ? flatten(image) : image
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw FWError("无法创建 \(fmt.uppercased()) 文件")
            }
            var p = props
            if let quality { p[kCGImageDestinationLossyCompressionQuality] = quality }
            if type == .tiff {
                var tiff = (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
                tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
                p[kCGImagePropertyTIFFDictionary] = tiff
            }
            CGImageDestinationAddImage(dest, pixels, p as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw FWError("写入 \(fmt.uppercased()) 失败") }
        }
    }

    private static func writeWebP(_ image: CGImage, to url: URL, quality: Double) async throws {
        guard let cwebp = Shell.cwebp else { throw FWError(Shell.installHint("cwebp")) }
        let tmp = try Out.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let input = tmp.appendingPathComponent("in.png")
        try await write(image, to: input, fmt: "png")
        try await Shell.run(cwebp, ["-quiet", "-mt", "-q", String(Int(quality * 100)), "-metadata", "icc", input.path, "-o", url.path])
    }

    private static func writeAVIF(_ image: CGImage, to url: URL, quality: Double) async throws {
        guard let ffmpeg = Shell.ffmpeg else { throw FWError(Shell.installHint("ffmpeg")) }
        let tmp = try Out.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let input = tmp.appendingPathComponent("in.png")
        // AV1 here is 4:2:0 without alpha, so flatten transparent images onto white first.
        try await write(hasAlpha(image) ? flatten(image) : image, to: input, fmt: "png")
        let crf = Int((52 - quality * 34).rounded())
        do {
            try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", input.path,
                                         "-frames:v", "1", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p",
                                         "-c:v", "libsvtav1", "-crf", String(crf), "-preset", "6", "-f", "avif", url.path])
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Pixel helpers

    static func space(for image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb, cs.supportsOutput { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return true }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 3, to: w * h * 4, by: 4) where bytes[i] < 250 { return true }
        return false
    }

    static func flatten(_ image: CGImage) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space(for: image), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func resized(_ image: CGImage, scale: Double) -> CGImage {
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space(for: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Rotates 90° clockwise.
    static func rotated(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space(for: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: - Actions

    static func convert(_ url: URL, to fmt: String) async throws -> OpResult {
        let image = try load(url)
        let out = try Out.url(for: url, ext: fmt)
        try await write(image.cg, to: out, fmt: fmt, quality: lossyQuality(fmt), props: carryOver(image.props))
        return OpResult(outputs: [out])
    }

    static func compress(_ url: URL) async throws -> OpResult {
        var image = try load(url).cg
        let longSide = max(image.width, image.height)
        if longSide > 4096 { image = resized(image, scale: 4096 / Double(longSide)) }
        let source = sameFormat(url)
        let fmt: String
        let quality: Double?
        switch source {
        case "jpg": fmt = "jpg"; quality = 0.7
        case "heic": fmt = "heic"; quality = 0.55
        case "webp": fmt = "webp"; quality = 0.7
        case "avif": fmt = "avif"; quality = 0.45
        default:
            if !hasAlpha(image) {
                fmt = "jpg"; quality = 0.78
            } else if Shell.cwebp != nil {
                fmt = "webp"; quality = 0.78
            } else {
                fmt = "png"; quality = nil
                if longSide > 1600 { image = resized(image, scale: 1600 / Double(longSide)) }
            }
        }
        let out = try Out.url(for: url, suffix: "压缩", ext: fmt)
        try await write(image, to: out, fmt: fmt, quality: quality)
        return try shrinkResult(source: url, output: out)
    }

    static func shrinkResult(source: URL, output: URL) throws -> OpResult {
        let before = Fmt.size(of: source), after = Fmt.size(of: output)
        guard after < before else {
            try? FileManager.default.removeItem(at: output)
            throw FWError("已经很小了，压不动了")
        }
        let saved = Int((1 - Double(after) / Double(max(before, 1))) * 100)
        return OpResult(outputs: [output], note: "体积 -\(saved)%")
    }

    static func half(_ url: URL) async throws -> OpResult {
        let image = try load(url)
        let fmt = sameFormat(url)
        let out = try Out.url(for: url, suffix: "缩小", ext: fmt)
        let small = resized(image.cg, scale: 0.5)
        try await write(small, to: out, fmt: fmt, quality: lossyQuality(fmt), props: carryOver(image.props))
        return OpResult(outputs: [out], note: "\(small.width)×\(small.height)")
    }

    static func cutout(_ url: URL) async throws -> OpResult {
        let image = try load(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image.cg, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw FWError("没找到能抠出来的主体")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let masked = CIContext().createCGImage(ci, from: ci.extent) else { throw FWError("抠图失败") }
        let out = try Out.url(for: url, suffix: "抠图", ext: "png")
        try await write(masked, to: out, fmt: "png")
        return OpResult(outputs: [out], note: "背景已去掉")
    }

    static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let wanted = ["zh-Hans", "zh-Hant", "en-US"]
        let supported = (try? request.supportedRecognitionLanguages()) ?? wanted
        request.recognitionLanguages = wanted.filter(supported.contains)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func ocr(_ url: URL) async throws -> OpResult {
        let text = try recognizeText(load(url).cg).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FWError("图里没认出文字") }
        let out = try Out.url(for: url, suffix: "文字", ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return OpResult(outputs: [out], note: "认出 \(Fmt.count(text.count)) 字，已复制", clip: text)
    }

    static func mono(_ url: URL) async throws -> OpResult {
        let image = try load(url)
        let ci = CIImage(cgImage: image.cg)
        guard let filtered = CIFilter(name: "CIPhotoEffectMono", parameters: [kCIInputImageKey: ci])?.outputImage,
              let gray = CIContext().createCGImage(filtered, from: ci.extent) else { throw FWError("处理失败") }
        let fmt = sameFormat(url)
        let out = try Out.url(for: url, suffix: "黑白", ext: fmt)
        try await write(gray, to: out, fmt: fmt, quality: lossyQuality(fmt), props: carryOver(image.props))
        return OpResult(outputs: [out])
    }

    static func rotate(_ url: URL) async throws -> OpResult {
        let image = try load(url)
        let fmt = sameFormat(url)
        let out = try Out.url(for: url, suffix: "旋转", ext: fmt)
        try await write(rotated(image.cg), to: out, fmt: fmt, quality: fmt == "jpg" ? 0.95 : lossyQuality(fmt), props: carryOver(image.props))
        return OpResult(outputs: [out])
    }

    /// Removes EXIF/GPS/XMP. JPEG, PNG and TIFF are rewritten without re-encoding the pixels.
    static func strip(_ url: URL) async throws -> OpResult {
        let note = Privacy.evadedNote
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
           [UTType.jpeg.identifier, UTType.png.identifier, UTType.tiff.identifier].contains(type as String) {
            let out = try Out.url(for: url, suffix: "去隐私", ext: url.pathExtension.lowercased())
            let index = CGImageSourceGetPrimaryImageIndex(src)
            let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
            let metadata = CGImageMetadataCreateMutable()
            if let orientation = props[kCGImagePropertyOrientation] {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFTypeRef)
            }
            if let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
                let options: [CFString: Any] = [
                    kCGImageDestinationMetadata: metadata,
                    kCGImageDestinationMergeMetadata: false,
                    kCGImageMetadataShouldExcludeGPS: true,
                    kCGImageMetadataShouldExcludeXMP: true,
                ]
                if CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) {
                    return OpResult(outputs: [out], note: note)
                }
                try? FileManager.default.removeItem(at: out)
            }
        }
        let image = try load(url)
        let fmt = sameFormat(url)
        let out = try Out.url(for: url, suffix: "去隐私", ext: fmt)
        try await write(image.cg, to: out, fmt: fmt, quality: fmt == "jpg" ? 0.95 : lossyQuality(fmt), props: [kCGImagePropertyOrientation: 1])
        return OpResult(outputs: [out], note: note)
    }

    /// Gradient backdrop with padding, rounded corners and a soft shadow.
    static func backdrop(_ url: URL) async throws -> OpResult {
        var image = try load(url).cg
        let longSide = max(image.width, image.height)
        if longSide > 4000 { image = resized(image, scale: 4000 / Double(longSide)) }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = (max(w, h) * 0.09).rounded()
        let width = Int(w + pad * 2), height = Int(h + pad * 2)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FWError("画布创建失败") }
        let colors = [
            CGColor(srgbRed: 0.98, green: 0.35, blue: 0.50, alpha: 1),
            CGColor(srgbRed: 0.99, green: 0.55, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.99, green: 0.79, blue: 0.40, alpha: 1),
        ]
        let gradient = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])

        let rect = CGRect(x: pad, y: pad, width: w, height: h)
        let corner = min(w, h) * 0.035
        let shape = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.12), blur: pad * 0.45, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()

        guard let framed = ctx.makeImage() else { throw FWError("合成失败") }
        let out = try Out.url(for: url, suffix: "加背景", ext: "png")
        try await write(framed, to: out, fmt: "png")
        return OpResult(outputs: [out])
    }
}

/// Builds PDFs from images. Opaque images are embedded as JPEG so the PDF stays small.
enum PDFMaker {
    static func write(_ images: [CGImage], to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextCreator: "格式轮盘"] as CFDictionary) else {
            throw FWError("无法创建 PDF")
        }
        for image in images {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            // Keep full resolution but give the page a sensible physical size (long edge ≈ A4).
            let k = 842 / max(w, h)
            var box = CGRect(x: 0, y: 0, width: w * k, height: h * k)
            let page = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(page)
            ctx.interpolationQuality = .high
            ctx.draw(jpegBacked(image), in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func jpegBacked(_ image: CGImage) -> CGImage {
        if ImageOps.hasAlpha(image) { return image }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return image }
        CGImageDestinationAddImage(dest, ImageOps.flatten(image), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return image }
        return jpeg
    }
}
