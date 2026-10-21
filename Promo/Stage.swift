import AppKit
import CoreImage

// Drawing kit for the promo film. Canvas is 1920×1080, y up (AppKit convention).

let W: CGFloat = 1920
let H: CGFloat = 1080

enum Ease {
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func out(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    static func inOut(_ x: Double) -> Double {
        let t = clamp(x)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    static func back(_ x: Double) -> Double {
        let t = clamp(x), c1 = 1.9, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

/// 0...1 progress of `t` through the window starting at `start` lasting `duration`.
func span(_ t: Double, _ start: Double, _ duration: Double) -> Double {
    Ease.clamp((t - start) / duration)
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }
func lerp(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, k), y: lerp(a.y, b.y, k)) }

enum Palette {
    static let ink = NSColor(srgbRed: 0.035, green: 0.035, blue: 0.045, alpha: 1)
    static let gold = Theme.gold
    static let blue = NSColor(srgbRed: 0.20, green: 0.50, blue: 0.90, alpha: 1)
    static let red = NSColor(srgbRed: 0.92, green: 0.22, blue: 0.22, alpha: 1)
    static let dim = NSColor(white: 1, alpha: 0.55)
}

enum Typeset {
    static func heavy(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .heavy) }
    static func bold(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .bold) }
    static func medium(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .medium) }
}

final class Stage {
    let ctx: CGContext
    private(set) var ns: NSGraphicsContext

    init(context: CGContext) {
        ctx = context
        ns = NSGraphicsContext(cgContext: context, flipped: false)
    }

    /// Runs AppKit drawing (text, NSImage, views) against the canvas.
    func appKit(flipped: Bool = false, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped ? NSGraphicsContext(cgContext: ctx, flipped: true) : ns
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    func fill(_ color: NSColor, _ rect: CGRect = CGRect(x: 0, y: 0, width: W, height: H)) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    func image(_ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    /// Draws a group with one alpha (children may set their own alpha inside).
    func group(alpha: CGFloat, _ body: () -> Void) {
        guard alpha > 0.001 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Scales/rotates everything drawn in `body` around `pivot`.
    func transform(pivot: CGPoint, scale: CGFloat = 1, rotate: CGFloat = 0, offset: CGPoint = .zero, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: pivot.x + offset.x, y: pivot.y + offset.y)
        ctx.rotate(by: rotate)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        body()
        ctx.restoreGState()
    }

    /// Draws a view's own draw(_:) at `origin` (views here have no subviews of their own).
    func view(_ view: NSView, at origin: CGPoint, alpha: CGFloat = 1) {
        group(alpha: alpha) {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            if view.isFlipped {
                ctx.translateBy(x: 0, y: view.bounds.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            appKit(flipped: view.isFlipped) { view.draw(view.bounds) }
            ctx.restoreGState()
        }
    }

    // MARK: Text

    @discardableResult
    func text(_ s: String, font: NSFont, color: NSColor = .white, center: CGPoint, alpha: CGFloat = 1,
              outline: CGFloat = 0, shadow: CGFloat = 0, kern: CGFloat = 0, maxWidth: CGFloat? = nil) -> CGRect {
        var rect = CGRect.zero
        group(alpha: alpha) {
            appKit {
                rect = Draw.text(s, TextStyle(font: font, color: color, outline: outline, outlineColor: NSColor(white: 0, alpha: 0.9),
                                              shadow: shadow, kern: kern), center: center, maxWidth: maxWidth)
            }
        }
        return rect
    }

    func width(_ s: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        Draw.size(s, TextStyle(font: font, kern: kern)).width
    }

    /// Phrases sliding up into place one after another, centred as a line.
    func reveal(_ parts: [(String, NSColor)], font: NSFont, center: CGPoint, t: Double, start: Double,
                stagger: Double = 0.09, duration: Double = 0.42, rise: CGFloat = 26, alpha: CGFloat = 1) {
        let widths = parts.map { width($0.0, font: font) }
        let total = widths.reduce(0, +)
        var x = center.x - total / 2
        for (i, part) in parts.enumerated() {
            let k = span(t, start + Double(i) * stagger, duration)
            let e = Ease.out(k)
            text(part.0, font: font, color: part.1, center: CGPoint(x: x + widths[i] / 2, y: center.y - rise * CGFloat(1 - e)),
                 alpha: alpha * CGFloat(e))
            x += widths[i]
        }
    }

    // MARK: Props

    func vignette(strength: CGFloat = 0.55) {
        let g = CGGradient(colorsSpace: nil, colors: [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: strength).cgColor] as CFArray, locations: [0.35, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: W / 2, y: H / 2), startRadius: 0, endCenter: CGPoint(x: W / 2, y: H / 2),
                               endRadius: hypot(W, H) / 2, options: [.drawsAfterEndLocation])
    }

    func glow(_ color: NSColor, at p: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let g = CGGradient(colorsSpace: nil, colors: [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
    }

    /// macOS-style arrow pointer with its tip at `tip`.
    func cursor(at tip: CGPoint, scale: CGFloat = 1.4, pressed: Bool = false) {
        let s = scale * (pressed ? 0.92 : 1)
        let pts: [CGPoint] = [(0, 0), (0, -17), (4.2, -13.2), (7.2, -19.8), (10, -18.6), (7.1, -12.2), (12.4, -12.2)].map {
            CGPoint(x: tip.x + $0.0 * s, y: tip.y + $0.1 * s)
        }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.6 * scale)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// A Finder-style file icon: thumbnail card plus a name label.
    func fileIcon(_ thumb: CGImage, name: String, center: CGPoint, selected: Bool = false, alpha: CGFloat = 1, scale: CGFloat = 1, badge: Bool = false) {
        group(alpha: alpha) {
            transform(pivot: center, scale: scale) {
                let card = CGRect(x: center.x - 60, y: center.y - 30, width: 120, height: 90)
                if selected {
                    ctx.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
                    ctx.addPath(CGPath(roundedRect: card.insetBy(dx: -10, dy: -10), cornerWidth: 10, cornerHeight: 10, transform: nil))
                    ctx.fillPath()
                }
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: NSColor(white: 0, alpha: 0.4).cgColor)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.addPath(CGPath(roundedRect: card, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: card.insetBy(dx: 4, dy: 4), cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.clip()
                ctx.draw(thumb, in: card.insetBy(dx: 4, dy: 4))
                ctx.restoreGState()

                let font = Typeset.medium(19)
                let w = width(name, font: font) + 16
                let label = CGRect(x: center.x - w / 2, y: center.y - 66, width: w, height: 28)
                if selected {
                    ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.45, blue: 0.95, alpha: 1).cgColor)
                    ctx.addPath(CGPath(roundedRect: label, cornerWidth: 6, cornerHeight: 6, transform: nil))
                    ctx.fillPath()
                }
                text(name, font: font, color: .white, center: CGPoint(x: label.midX, y: label.midY), shadow: selected ? 0 : 3)
                if badge {
                    let b = CGPoint(x: card.maxX - 6, y: card.minY + 6)
                    ctx.setFillColor(NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1).cgColor)
                    ctx.fillEllipse(in: CGRect(x: b.x - 15, y: b.y - 15, width: 30, height: 30))
                    text("+", font: Typeset.heavy(26), center: CGPoint(x: b.x, y: b.y + 1))
                }
            }
        }
    }

    /// A light keyboard key with a press animation (0 = up, 1 = fully down).
    func keycap(_ label: String, center: CGPoint, press: CGFloat, alpha: CGFloat) {
        group(alpha: alpha) {
            let depth: CGFloat = 8 * (1 - press)
            let face = CGRect(x: center.x - 120, y: center.y - 46 + depth, width: 240, height: 92)
            ctx.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: face.offsetBy(dx: 0, dy: -depth - 2), cornerWidth: 18, cornerHeight: 18, transform: nil))
            ctx.fillPath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * (1 - press)), blur: 24, color: NSColor(white: 0, alpha: 0.5).cgColor)
            ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: face, cornerWidth: 18, cornerHeight: 18, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            text(label, font: Typeset.bold(40), color: NSColor(white: 0.1, alpha: 1), center: CGPoint(x: face.midX, y: face.midY))
        }
    }

    /// Lower-third step caption: "① 拖住文件".
    func caption(step: String, _ s: String, alpha: CGFloat) {
        group(alpha: alpha) {
            let font = Typeset.bold(34)
            let w = width(s, font: font) + 110
            let pill = CGRect(x: W / 2 - w / 2, y: 64, width: w, height: 70)
            ctx.setFillColor(NSColor(white: 0, alpha: 0.72).cgColor)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 35, cornerHeight: 35, transform: nil))
            ctx.fillPath()
            let dot = CGPoint(x: pill.minX + 42, y: pill.midY)
            ctx.setFillColor(Palette.gold.cgColor)
            ctx.fillEllipse(in: CGRect(x: dot.x - 21, y: dot.y - 21, width: 42, height: 42))
            text(step, font: Typeset.heavy(26), color: .black, center: dot)
            text(s, font: font, center: CGPoint(x: pill.minX + 72 + (w - 92) / 2, y: pill.midY))
        }
    }
}

enum Art {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func canvas(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    /// "Los Santos" sunset wallpaper: banded sun, hills, skyline and palm trees.
    static func wallpaper(_ w: Int = 1920, _ h: Int = 1080) -> CGImage {
        canvas(w, h) { ctx in
            let W = CGFloat(w), H = CGFloat(h)
            let sky = CGGradient(colorsSpace: srgb, colors: [
                NSColor(srgbRed: 0.10, green: 0.07, blue: 0.24, alpha: 1).cgColor,
                NSColor(srgbRed: 0.45, green: 0.13, blue: 0.45, alpha: 1).cgColor,
                NSColor(srgbRed: 0.93, green: 0.32, blue: 0.40, alpha: 1).cgColor,
                NSColor(srgbRed: 0.99, green: 0.62, blue: 0.33, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 0.42, 0.75, 1])!
            ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.3), options: [.drawsAfterEndLocation])

            let sun = CGPoint(x: W * 0.62, y: H * 0.42)
            let r = H * 0.24
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: sun.x - r, y: sun.y - r, width: r * 2, height: r * 2))
            ctx.clip()
            let disc = CGGradient(colorsSpace: srgb, colors: [
                NSColor(srgbRed: 1, green: 0.92, blue: 0.45, alpha: 1).cgColor,
                NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(disc, start: CGPoint(x: 0, y: sun.y + r), end: CGPoint(x: 0, y: sun.y - r), options: [])
            ctx.setBlendMode(.clear)
            for k in 0..<7 {
                let y = sun.y - r * 0.05 - CGFloat(k) * r * 0.14
                ctx.fill(CGRect(x: sun.x - r, y: y, width: r * 2, height: 3 + CGFloat(k) * 2.4))
            }
            ctx.restoreGState()

            func ridge(_ base: CGFloat, _ amp: CGFloat, _ seed: CGFloat, _ color: NSColor) {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                var x: CGFloat = 0
                while x <= W {
                    let y = base + amp * (sin(x / 210 + seed) * 0.6 + sin(x / 83 + seed * 2) * 0.25 + sin(x / 37 + seed) * 0.1)
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 12
                }
                path.addLine(to: CGPoint(x: W, y: 0))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            }
            ridge(H * 0.33, H * 0.06, 1.3, NSColor(srgbRed: 0.42, green: 0.14, blue: 0.36, alpha: 1))
            ridge(H * 0.24, H * 0.05, 4.1, NSColor(srgbRed: 0.24, green: 0.08, blue: 0.27, alpha: 1))

            // Skyline.
            var x: CGFloat = W * 0.08
            var seed: CGFloat = 0.37
            ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.04, blue: 0.16, alpha: 1).cgColor)
            while x < W * 0.92 {
                seed = (seed * 9301 + 0.4927).truncatingRemainder(dividingBy: 1)
                let bw = 26 + seed * 54
                let bh = H * (0.06 + seed * 0.16) * (abs(x - W * 0.45) < W * 0.15 ? 1.6 : 1)
                ctx.fill(CGRect(x: x, y: H * 0.18, width: bw, height: bh))
                x += bw + 4
            }
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H * 0.19))

            func palm(_ base: CGPoint, _ height: CGFloat, _ lean: CGFloat) {
                ctx.setStrokeColor(NSColor(srgbRed: 0.06, green: 0.02, blue: 0.08, alpha: 1).cgColor)
                ctx.setFillColor(NSColor(srgbRed: 0.06, green: 0.02, blue: 0.08, alpha: 1).cgColor)
                let top = CGPoint(x: base.x + lean, y: base.y + height)
                let trunk = CGMutablePath()
                trunk.move(to: base)
                trunk.addQuadCurve(to: top, control: CGPoint(x: base.x + lean * 0.2, y: base.y + height * 0.6))
                ctx.addPath(trunk)
                ctx.setLineWidth(height * 0.035)
                ctx.setLineCap(.round)
                ctx.strokePath()
                for k in 0..<7 {
                    let a = CGFloat(k) / 6 * .pi * 1.15 - .pi * 0.08
                    let tip = CGPoint(x: top.x + cos(a) * height * 0.42, y: top.y + sin(a) * height * 0.16 - height * 0.12)
                    let leaf = CGMutablePath()
                    leaf.move(to: top)
                    leaf.addQuadCurve(to: tip, control: CGPoint(x: (top.x + tip.x) / 2, y: top.y + height * 0.13))
                    leaf.addQuadCurve(to: top, control: CGPoint(x: (top.x + tip.x) / 2, y: top.y + height * 0.05))
                    ctx.addPath(leaf)
                    ctx.fillPath()
                }
            }
            palm(CGPoint(x: W * 0.12, y: 0), H * 0.62, 70)
            palm(CGPoint(x: W * 0.2, y: 0), H * 0.45, -40)
            palm(CGPoint(x: W * 0.9, y: 0), H * 0.55, -60)
        }
    }

    /// The live overlay's frosted backdrop: heavy blur, a little desaturated.
    static func frosted(_ image: CGImage) -> CGImage {
        let ci = CIImage(cgImage: image)
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: 34).cropped(to: ci.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.55, kCIInputBrightnessKey: -0.02])
        return CIContext().createCGImage(out, from: ci.extent)!
    }

    static func grayscale(_ image: CGImage) -> CGImage {
        let ci = CIImage(cgImage: image).applyingFilter("CIPhotoEffectNoir")
        return CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))!
    }

    static func crop(_ image: CGImage, _ rect: CGRect) -> CGImage { image.cropping(to: rect) ?? image }

    static func icon(_ pixels: Int) -> CGImage {
        let image = Icons.app(pixels: pixels)
        return canvas(pixels, pixels) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Fine film grain, tiled over every frame at a random offset.
    static func grain(_ size: Int = 512) -> CGImage {
        var seed: UInt32 = 12345
        return canvas(size, size) { ctx in
            guard let data = ctx.data else { return }
            let p = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
            for i in 0..<(size * size) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let v = UInt8(truncatingIfNeeded: seed >> 24)
                let a: UInt8 = 14
                let premul = UInt8(Int(v) * Int(a) / 255)
                p[i * 4] = premul; p[i * 4 + 1] = premul; p[i * 4 + 2] = premul; p[i * 4 + 3] = a
            }
        }
    }
}
