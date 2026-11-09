import AppKit
import SwiftUI

/// Echoro brand palette, from "Echoro brand colours" (Theme.kt, SubscriptionColours.kt, colors.xml).
enum Brand {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    // Brand
    static let echoroGreen = 0x123524 as UInt32, deleteRed = 0xFF3B30 as UInt32
    // Light scheme
    static let lPrimary = 0x123524 as UInt32, lOnPrimary = 0xFFFFFF as UInt32, lPrimaryContainer = 0xC5ECD2 as UInt32
    static let lOnPrimaryContainer = 0x002112 as UInt32, lSecondary = 0x4E6355 as UInt32, lSecondaryContainer = 0xD0E8D7 as UInt32
    static let lBackground = 0xF8FAF5 as UInt32, lText = 0x191C1A as UInt32, lTextSecondary = 0x404942 as UInt32, lError = 0xBA1A1A as UInt32
    // Dark scheme
    static let dPrimary = 0xA9CFB7 as UInt32, dPrimaryContainer = 0x2B4E3B as UInt32, dOnPrimaryContainer = 0xC5ECD2 as UInt32
    static let dSecondary = 0xB5CCBB as UInt32, dBackground = 0x111412 as UInt32, dText = 0xE1E3DE as UInt32, dError = 0xFFB4AB as UInt32
    // Custom swatches (charts)
    static let forest = 0x2F6B57 as UInt32, rose = 0xC2416B as UInt32, ocean = 0x2A6FB0 as UInt32
    static let terracotta = 0xB5452B as UInt32, indigo = 0x4F55B8 as UInt32, amber = 0xB7791F as UInt32

    static func color(_ v: UInt32, _ a: CGFloat = 1) -> Color { Color(nsColor: hex(v, a)) }
    /// A colour that follows dark and light mode.
    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

/// Short names used across the app (all from the brand palette).
enum Echoro {
    /// Echoro Green — the canonical brand colour (#123524).
    static let green = Brand.color(Brand.echoroGreen)
    /// Primary container (#C5ECD2).
    static let mint = Brand.color(Brand.lPrimaryContainer)
    /// On primary container (#002112).
    static let deep = Brand.color(Brand.lOnPrimaryContainer)
    /// Secondary (#4E6355 light / #B5CCBB dark). Part of the shared Echoro palette (used by eWheel).
    static let sage = Brand.dynamic(dark: Brand.hex(Brand.dSecondary), light: Brand.hex(Brand.lSecondary))
    /// Amber swatch (#B7791F), for warnings and charts.
    static let amber = Brand.color(Brand.amber)
}

/// Liquid Glass tints: primary-container green in dark mode, secondary/primary container in light mode.
enum GlassTint {
    static let clear = Brand.dynamic(dark: Brand.hex(Brand.dPrimaryContainer, 0.34), light: Brand.hex(Brand.lSecondaryContainer, 0.50))
    static let dense = Brand.dynamic(dark: Brand.hex(Brand.echoroGreen, 0.58), light: Brand.hex(Brand.lPrimaryContainer, 0.82))
    static let selected = Brand.dynamic(dark: Brand.hex(Brand.dOnPrimaryContainer, 0.85), light: Brand.hex(Brand.lPrimaryContainer, 0.95))
}

extension Color {
    /// Text: #E1E3DE on dark, #191C1A on light.
    static let ink = Brand.dynamic(dark: Brand.hex(Brand.dText), light: Brand.hex(Brand.lText))
    /// Accent text and icons: primary (#A9CFB7 dark / #123524 light).
    static let accentInk = Brand.dynamic(dark: Brand.hex(Brand.dPrimary), light: Brand.hex(Brand.lPrimary))
    /// "Check first" and other cautions: the amber swatch, lifted for dark mode.
    static let warnInk = Brand.dynamic(dark: NSColor(srgbRed: 0xE3 / 255, green: 0xB0 / 255, blue: 0x5C / 255, alpha: 1), light: Brand.hex(Brand.amber))
    /// Errors and missing things: error (#FFB4AB dark / #BA1A1A light).
    static let dangerInk = Brand.dynamic(dark: Brand.hex(Brand.dError), light: Brand.hex(Brand.lError))
    /// Main buttons and selection: primary fill with its on-colour.
    static let primaryFill = Brand.dynamic(dark: Brand.hex(Brand.dPrimary), light: Brand.hex(Brand.lPrimary))
    static let onPrimaryFill = Brand.dynamic(dark: Brand.hex(Brand.lOnPrimaryContainer), light: Brand.hex(Brand.lOnPrimary))
    /// Delete red (#FF3B30).
    static let deleteRed = Brand.color(Brand.deleteRed)
}

/// "system", "dark" or "light", from Settings.
enum Appearance {
    static let key = "appearance"
    static func scheme(_ v: String) -> ColorScheme? { v == "dark" ? .dark : v == "light" ? .light : nil }
}

/// Echoro Green backdrop for the Liquid Glass: deep green in dark mode, soft mint in light mode.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if scheme == .light { light } else { dark }
    }

    private var light: some View {
        ZStack {
            LinearGradient(colors: [Brand.color(Brand.lBackground), Brand.color(Brand.lSecondaryContainer),
                                    Brand.color(Brand.lPrimaryContainer)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                Circle().fill(.white.opacity(0.75)).frame(width: 460).blur(radius: 110)
                    .position(x: g.size.width * 0.85, y: g.size.height * 0.08)
                Circle().fill(Brand.color(Brand.dPrimary, 0.45)).frame(width: 420).blur(radius: 110)
                    .position(x: g.size.width * 0.12, y: g.size.height * 0.62)
                Circle().fill(Brand.color(Brand.lSecondary, 0.12)).frame(width: 380).blur(radius: 90)
                    .position(x: g.size.width * 0.7, y: g.size.height * 0.95)
            }
        }
        .ignoresSafeArea()
    }

    private var dark: some View {
        ZStack {
            LinearGradient(colors: [Brand.color(Brand.dPrimaryContainer), Echoro.green, Brand.color(Brand.dBackground)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                Circle().fill(Brand.color(Brand.dOnPrimaryContainer, 0.18)).frame(width: 460).blur(radius: 110)
                    .position(x: g.size.width * 0.85, y: g.size.height * 0.08)
                Circle().fill(Brand.color(Brand.dPrimary, 0.28)).frame(width: 420).blur(radius: 110)
                    .position(x: g.size.width * 0.12, y: g.size.height * 0.62)
                Circle().fill(Brand.color(Brand.dOnPrimaryContainer, 0.08)).frame(width: 380).blur(radius: 90)
                    .position(x: g.size.width * 0.7, y: g.size.height * 0.95)
            }
        }
        .ignoresSafeArea()
    }
}
