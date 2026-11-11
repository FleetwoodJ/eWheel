import AppKit

/// A modifier key that can open one of the wheels.
enum ModKey: String, CaseIterable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }
    var glyph: String { switch self { case .shift: "⇧"; case .command: "⌘"; case .control: "⌃"; case .option: "⌥" } }
    var name: String { switch self { case .shift: "Shift"; case .command: "Command"; case .control: "Control"; case .option: "Option" } }
    var flag: NSEvent.ModifierFlags { switch self { case .shift: .shift; case .command: .command; case .control: .control; case .option: .option } }
}

/// Where converted files are written.
enum SaveLocation: String, CaseIterable, Identifiable {
    case beside, downloads, desktop

    var id: String { rawValue }
    var title: String { switch self { case .beside: "Next to the original"; case .downloads: "Downloads folder"; case .desktop: "Desktop" } }
    var short: String { switch self { case .beside: "With original"; case .downloads: "Downloads"; case .desktop: "Desktop" } }
}

/// User settings, stored in UserDefaults. The Settings window edits the same
/// keys through @AppStorage, so both always agree.
enum Prefs {
    private static var d: UserDefaults { .standard }

    static func key(for mode: WheelMode) -> ModKey {
        ModKey(rawValue: d.string(forKey: mode.prefKey) ?? "") ?? mode.defaultKey
    }

    static var saveLocation: SaveLocation {
        SaveLocation(rawValue: d.string(forKey: "saveLocation") ?? "") ?? .beside
    }

    static var revealAfter: Bool { d.bool(forKey: "revealAfter") }

    /// Click sound when hovering wheel segments (on by default).
    static var hoverSound: Bool { d.object(forKey: "hoverSound") == nil ? true : d.bool(forKey: "hoverSound") }

    /// Settings → Tools → Image quality, for JPG, HEIC, WebP and AVIF saves (Compress keeps its own).
    /// High is what eWheel always used, so nothing changes until you pick another.
    static var imageQuality: Double {
        switch d.string(forKey: "imageQuality") {
        case "balanced": 0.80
        case "small": 0.65
        default: 0.92
        }
    }

    /// Settings → Tools: the "Compress to size" target in MB, and the "Resize width" in pixels.
    static var targetMB: Int { let v = d.integer(forKey: "targetMB"); return v > 0 ? v : 2 }
    static var resizeWidth: Int { let v = d.integer(forKey: "resizeWidth"); return v > 0 ? v : 1920 }

    /// Check GitHub for a newer eWheel about once a day (on by default).
    static var autoUpdateCheck: Bool { d.object(forKey: "autoUpdateCheck") == nil ? true : d.bool(forKey: "autoUpdateCheck") }

    /// "⇧: Convert · ⌘: Tools · ⌥: Actions"
    static var keySummary: String {
        WheelMode.allCases.map { "\(key(for: $0).glyph): \($0.title)" }.joined(separator: " · ")
    }
}
