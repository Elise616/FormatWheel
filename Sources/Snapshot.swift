import AppKit
import CoreImage

/// Offscreen renders of the overlay and banners, for checking the look without a real drag.
enum Snapshot {
    static func wheel(files: [URL], hover: Int?, page: Int, background: URL?, out: URL,
                      size: CGSize = CGSize(width: 1512, height: 982), center: CGPoint? = nil, wanted: Wanted = Wanted()) throws {
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        let backdrop = ImageFillView(frame: root.bounds)
        backdrop.image = blurredDesktop(background, size: size)
        root.addSubview(backdrop)

        let content = OverlayContent(frame: root.bounds)
        root.addSubview(content)
        let context = Catalog.context(for: files)
        let page = min(page, context.pages.count - 1)
        content.arrange(wheelCenter: center ?? CGPoint(x: size.width / 2, y: size.height / 2),
                        radius: Settings.shared.wheelSize.radius, topInset: 37, rows: context.statLabels.count)
        content.setAccent(Theme.accent)
        content.apply(context: context, page: page, hover: hover)
        if let hover, let option = context.pages[page].slots[safe: hover] ?? nil {
            content.wheel.glow[hover] = option.enabled ? 1 : 0.35
        }
        content.stats.shown = content.stats.target
        content.wanted.show(wanted)
        content.wanted.appear = 1
        content.wanted.phase = 0.1
        if let hover, let option = context.pages[page].slots[safe: hover] ?? nil, option.id.hasSuffix(".strip") {
            content.wanted.evading = true
            content.wanted.caption = "松手 = 甩掉警察"
        }
        try write(root, to: out)
    }

    static func banner(passed: Bool, title: String, detail: String, background: URL?, out: URL,
                       size: CGSize = CGSize(width: 1512, height: 982)) throws {
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        let backdrop = ImageFillView(frame: root.bounds)
        backdrop.image = desktop(background, size: size)
        root.addSubview(backdrop)
        let band = CGRect(x: 0, y: size.height / 2 - BannerView.height / 2 + 40, width: size.width, height: BannerView.height)
        let banner = BannerView(frame: passed ? band : root.bounds)
        banner.fullScreen = !passed
        banner.configure(passed: passed, title: title, detail: detail)
        banner.progress = 1
        root.addSubview(banner)
        try write(root, to: out)
    }

    static func write(_ view: NSView, to url: URL) throws {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw FWError("无法创建画布")
        }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw FWError("PNG 编码失败") }
        try png.write(to: url)
    }

    static func desktop(_ url: URL?, size: CGSize) -> CGImage? {
        guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let ci = CIImage(cgImage: image)
        let scale = max(size.width * 2 / ci.extent.width, size.height * 2 / ci.extent.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: (scaled.extent.width - size.width * 2) / 2, y: (scaled.extent.height - size.height * 2) / 2,
                          width: size.width * 2, height: size.height * 2)
        return CIContext().createCGImage(scaled, from: crop)
    }

    /// Approximates the live NSVisualEffectView backdrop: blurred and a little desaturated.
    static func blurredDesktop(_ url: URL?, size: CGSize) -> CGImage? {
        guard let sharp = desktop(url, size: size) else { return nil }
        let ci = CIImage(cgImage: sharp)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 30).cropped(to: ci.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.75, kCIInputBrightnessKey: -0.06])
        return CIContext().createCGImage(blurred, from: ci.extent)
    }
}

final class ImageFillView: NSView {
    var image: CGImage?

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        if let image {
            cg.draw(image, in: bounds)
        } else {
            let g = CGGradient(colorsSpace: nil, colors: [NSColor.systemOrange.cgColor, NSColor.systemPink.cgColor, NSColor.systemPurple.cgColor] as CFArray, locations: [0, 0.5, 1])!
            cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
        }
    }
}
