import AppKit

struct TextStyle {
    var font: NSFont
    var color: NSColor = .white
    /// Width of the dark rim drawn outside the glyphs, in points.
    var outline: CGFloat = 0
    var outlineColor = NSColor(white: 0, alpha: 0.82)
    var shadow: CGFloat = 3
    var kern: CGFloat = 0
    var alignment: NSTextAlignment = .center
    var wraps = false
}

enum Draw {
    static func attributes(_ style: TextStyle, rim: Bool) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = style.alignment
        para.lineBreakMode = style.wraps ? .byWordWrapping : .byTruncatingMiddle
        para.lineSpacing = style.wraps ? 1 : 0
        var attrs: [NSAttributedString.Key: Any] = [.font: style.font, .paragraphStyle: para, .kern: style.kern]
        if rim {
            // A positive stroke width strokes without filling; the stroke straddles the glyph edge,
            // so twice the rim width leaves `outline` points visible outside the letters.
            attrs[.strokeColor] = style.outlineColor
            attrs[.strokeWidth] = style.outline * 2 / style.font.pointSize * 100
            attrs[.foregroundColor] = style.outlineColor
        } else {
            attrs[.foregroundColor] = style.color
        }
        return attrs
    }

    static func size(_ text: String, _ style: TextStyle, width: CGFloat? = nil) -> CGSize {
        let attrs = attributes(style, rim: false)
        if style.wraps, let width {
            let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin], attributes: attrs)
            return CGSize(width: ceil(rect.width), height: ceil(rect.height))
        }
        let s = (text as NSString).size(withAttributes: attrs)
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    /// Draws `text` centred on `point`, truncating (or wrapping) to `maxWidth`.
    @discardableResult
    static func text(_ text: String, _ style: TextStyle, center point: CGPoint, maxWidth: CGFloat? = nil) -> CGRect {
        var s = size(text, style, width: maxWidth)
        if let maxWidth { s.width = min(s.width + style.outline * 2, maxWidth) }
        let rect = CGRect(x: point.x - s.width / 2, y: point.y - s.height / 2, width: s.width, height: s.height)
        draw(text, style, in: rect)
        return rect
    }

    static func draw(_ text: String, _ style: TextStyle, in rect: CGRect) {
        let ns = text as NSString
        let options: NSString.DrawingOptions = style.wraps ? [.usesLineFragmentOrigin] : [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        NSGraphicsContext.saveGraphicsState()
        if style.shadow > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.65)
            shadow.shadowBlurRadius = style.shadow
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
        }
        if style.outline > 0 {
            // Round joins keep sharp letters (the W in "WASTED") from growing miter spikes.
            if let cg = NSGraphicsContext.current?.cgContext {
                cg.setLineJoin(.round)
                cg.setMiterLimit(1)
            }
            ns.draw(with: rect, options: options, attributes: attributes(style, rim: true))
            NSGraphicsContext.restoreGraphicsState()
            ns.draw(with: rect, options: options, attributes: attributes(style, rim: false))
        } else {
            ns.draw(with: rect, options: options, attributes: attributes(style, rim: false))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

enum Symbols {
    private static var cache: [String: NSImage] = [:]

    /// An SF Symbol rendered white with a dark rim, like GTA's weapon silhouettes.
    static func outlined(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .bold,
                         color: NSColor = .white, rim: CGFloat = 1.6) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(color.description)|\(rim)"
        if let hit = cache[key] { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) else { return nil }
        let fill = tinted(base, color)
        let edge = tinted(base, NSColor(white: 0, alpha: 0.85))
        let pad = rim + 2
        let size = NSSize(width: base.size.width + pad * 2, height: base.size.height + pad * 2)
        let image = NSImage(size: size, flipped: false) { _ in
            let inner = NSRect(x: pad, y: pad, width: base.size.width, height: base.size.height)
            if rim > 0 {
                for i in 0..<16 {
                    let a = CGFloat(i) / 16 * .pi * 2
                    edge.draw(in: inner.offsetBy(dx: cos(a) * rim, dy: sin(a) * rim))
                }
            }
            fill.draw(in: inner)
            return true
        }
        cache[key] = image
        return image
    }

    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    static func draw(_ image: NSImage, center: CGPoint, alpha: CGFloat = 1) {
        let rect = CGRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }
}

enum Geo {
    /// Unit vector for an angle measured clockwise from 12 o'clock (AppKit, y up).
    static func dir(_ theta: CGFloat) -> CGPoint {
        CGPoint(x: sin(theta), y: cos(theta))
    }

    static func point(_ center: CGPoint, _ radius: CGFloat, _ theta: CGFloat) -> CGPoint {
        let d = dir(theta)
        return CGPoint(x: center.x + d.x * radius, y: center.y + d.y * radius)
    }

    /// Ring slice between radii `r0`..`r1`, from `t0` to `t1` (clockwise from 12 o'clock).
    static func sector(center: CGPoint, r0: CGFloat, r1: CGFloat, from t0: CGFloat, to t1: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: r1, startAngle: .pi / 2 - t0, endAngle: .pi / 2 - t1, clockwise: true)
        path.addArc(center: center, radius: r0, startAngle: .pi / 2 - t1, endAngle: .pi / 2 - t0, clockwise: false)
        path.closeSubpath()
        return path
    }

    static func arc(center: CGPoint, radius: CGFloat, from t0: CGFloat, to t1: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: .pi / 2 - t0, endAngle: .pi / 2 - t1, clockwise: true)
        return path
    }
}

extension NSColor {
    func mixed(with other: NSColor, _ fraction: CGFloat) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }
}
