import AppKit

/// Highlight colour, named after the GTA V crew whose HUD colour it borrows.
enum Crew: String, CaseIterable {
    case online, michael, franklin, trevor

    var title: String {
        switch self {
        case .online: return "线上模式 · 蓝"
        case .michael: return "麦克 · 天蓝"
        case .franklin: return "富兰克林 · 绿"
        case .trevor: return "崔佛 · 橙"
        }
    }

    var color: NSColor {
        switch self {
        case .online: return NSColor(srgbRed: 0.20, green: 0.50, blue: 0.90, alpha: 1)
        case .michael: return NSColor(srgbRed: 0.40, green: 0.71, blue: 0.83, alpha: 1)
        case .franklin: return NSColor(srgbRed: 0.42, green: 0.82, blue: 0.45, alpha: 1)
        case .trevor: return NSColor(srgbRed: 1.00, green: 0.60, blue: 0.28, alpha: 1)
        }
    }
}

enum WheelSize: String, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    var radius: CGFloat {
        switch self {
        case .small: return 235
        case .medium: return 285
        case .large: return 330
        }
    }
}

enum IconStyle: String, CaseIterable {
    case formats, weapons

    var title: String {
        switch self {
        case .formats: return "格式图标"
        case .weapons: return "GTA 武器"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var crew: Crew {
        get { Crew(rawValue: defaults.string(forKey: "crew") ?? "") ?? .online }
        set { defaults.set(newValue.rawValue, forKey: "crew") }
    }

    var wheelSize: WheelSize {
        get { WheelSize(rawValue: defaults.string(forKey: "wheelSize") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "wheelSize") }
    }

    var iconStyle: IconStyle {
        get { IconStyle(rawValue: defaults.string(forKey: "iconStyle") ?? "") ?? .formats }
        set { defaults.set(newValue.rawValue, forKey: "iconStyle") }
    }

    var sound: Bool {
        get { flag("sound", default: true) }
        set { defaults.set(newValue, forKey: "sound") }
    }

    var blur: Bool {
        get { flag("blur", default: true) }
        set { defaults.set(newValue, forKey: "blur") }
    }

    var banner: Bool {
        get { flag("banner", default: true) }
        set { defaults.set(newValue, forKey: "banner") }
    }

    var welcomed: Bool {
        get { flag("welcomed", default: false) }
        set { defaults.set(newValue, forKey: "welcomed") }
    }

    private func flag(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }
}

enum Theme {
    static var accent: NSColor { Settings.shared.crew.color }
    /// "Mission passed" gold.
    static let gold = NSColor(srgbRed: 0.96, green: 0.78, blue: 0.27, alpha: 1)
    /// "Wasted" red.
    static let wasted = NSColor(srgbRed: 0.80, green: 0.12, blue: 0.12, alpha: 1)
    /// Stat bar segment for an upgrade (GTA HUD blue).
    static let gain = NSColor(srgbRed: 0.36, green: 0.71, blue: 0.90, alpha: 1)
    /// Stat bar segment for a downgrade.
    static let loss = NSColor(srgbRed: 0.90, green: 0.24, blue: 0.22, alpha: 1)
}

enum HUDWeight: Int {
    case medium = 0, demi, bold, heavy
}

enum Fonts {
    private static let latin = ["AvenirNextCondensed-Medium", "AvenirNextCondensed-DemiBold", "AvenirNextCondensed-Bold", "AvenirNextCondensed-Heavy"]
    private static let cjk = ["PingFangSC-Regular", "PingFangSC-Medium", "PingFangSC-Semibold", "PingFangSC-Semibold"]

    /// Condensed HUD face (close to GTA's Chalet Comprimé) with PingFang for Chinese.
    static func hud(_ size: CGFloat, _ weight: HUDWeight = .demi) -> NSFont {
        let fallback = NSFontDescriptor(name: cjk[weight.rawValue], size: size)
        let descriptor = NSFontDescriptor(name: latin[weight.rawValue], size: size)
            .addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    /// Chunky face used for the big format labels inside the slots.
    static func badge(_ size: CGFloat) -> NSFont {
        let fallback = NSFontDescriptor(name: "PingFangSC-Semibold", size: size)
        let descriptor = NSFontDescriptor(name: "HelveticaNeue-CondensedBlack", size: size)
            .addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? hud(size, .heavy)
    }

    /// Face for the "MISSION PASSED" / "WASTED" splash.
    static func splash(_ size: CGFloat) -> NSFont {
        NSFont(name: "Impact", size: size) ?? hud(size, .heavy)
    }
}
