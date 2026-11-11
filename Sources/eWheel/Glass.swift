import SwiftUI

// One glass style for the whole app.
//
// Live: real Liquid Glass (`glassEffect`), lightly tinted Echoro Green so it
// reads as clear glass with a green cast, the way macOS 26/27 system glass
// takes a hint of the accent colour.
//
// Rendering presentation images (`--render`): Liquid Glass only exists on
// screen, so the same modifier recreates it from a blurred copy of whatever is
// behind (the "backdrop"), plus tint, top sheen and a specular rim.

private struct RenderBackdropKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
    /// Set only when rendering images: the scene behind the glass, in global coordinates.
    var renderBackdrop: AnyView? {
        get { self[RenderBackdropKey.self] }
        set { self[RenderBackdropKey.self] = newValue }
    }
}

struct EchoGlass<S: Shape>: ViewModifier {
    @Environment(\.renderBackdrop) private var backdrop
    let shape: S
    let tint: Color
    var interactive = false

    func body(content: Content) -> some View {
        if let backdrop {
            content.background {
                GeometryReader { g in
                    let f = g.frame(in: .global)
                    ZStack {
                        backdrop
                            .frame(width: Render.size.width, height: Render.size.height)
                            .offset(x: -f.minX, y: -f.minY)
                            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                            .blur(radius: 20)
                            .saturation(1.35)
                            .brightness(0.03)
                        shape.fill(tint)
                        shape.fill(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.02), .clear],
                                                  startPoint: .top, endPoint: .bottom))
                        shape.stroke(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.10), .white.opacity(0.10), .white.opacity(0.40)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1)
                    }
                    .clipShape(shape)
                    .shadow(color: Brand.dynamic(dark: NSColor(white: 0, alpha: 0.28), light: Brand.hex(Brand.echoroGreen, 0.10)), radius: 14, y: 7)
                }
            }
        } else {
            content.glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
        }
    }
}

extension View {
    func echoGlass<S: Shape>(_ shape: S, tint: Color = GlassTint.clear, interactive: Bool = false) -> some View {
        modifier(EchoGlass(shape: shape, tint: tint, interactive: interactive))
    }
}

// Tokens eWheel needs beyond the shared EchoroBrand kit ("Echoro brand colours"). All follow light/dark mode.
extension Color {
    /// "Picked" fill (selected segment, key, switch): mint #C5ECD2 on dark, Echoro Green on light,
    /// because mint all but disappears on pale glass.
    static let pick = Brand.dynamic(dark: Brand.hex(Brand.lPrimaryContainer), light: Brand.hex(Brand.echoroGreen))
    /// Text and icons on `pick`: #002112 on dark, white on light.
    static let onPick = Brand.dynamic(dark: Brand.hex(Brand.lOnPrimaryContainer), light: Brand.hex(0xFFFFFF))
    /// Error pop-up: container #93000A / #FFDAD6 with error #FFB4AB / #BA1A1A.
    static let errorFill = Brand.dynamic(dark: Brand.hex(0x93000A), light: Brand.hex(0xFFDAD6))
    static let errorInk = Brand.dynamic(dark: Brand.hex(Brand.dError), light: Brand.hex(Brand.lError))
    /// Soft shadow under labels on dark glass; none on light glass.
    static let labelShadow = Brand.dynamic(dark: NSColor(white: 0, alpha: 0.35), light: .clear)
    /// Secondary text: #C0C9C0 on dark, #404942 on light.
    static let inkSecondary = Brand.dynamic(dark: Brand.hex(0xC0C9C0), light: Brand.hex(0x404942))
    /// Divider: #404942 on dark, #C0C9C0 on light.
    static let divider = Brand.dynamic(dark: Brand.hex(0x404942), light: Brand.hex(0xC0C9C0))
}

extension GlassTint {
    /// Glass tint for a picked wheel segment, matching `Color.pick`.
    static let picked = Brand.dynamic(dark: Brand.hex(Brand.lPrimaryContainer, 0.88), light: Brand.hex(Brand.echoroGreen, 0.88))
}

extension Appearance {
    /// Applies Settings → Appearance (System / Light / Dark) to every eWheel window and panel.
    @MainActor static func apply() {
        switch UserDefaults.standard.string(forKey: key) ?? "system" {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
}

/// Liquid-Glass-style switch: glass track, white knob, mint when on.
/// Drawn in SwiftUI so it renders in presentation images too.
struct GlassSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.pick : Color.ink.opacity(0.14))
                    .overlay(Capsule().stroke(.white.opacity(isOn ? 0.5 : 0.18), lineWidth: 0.8))
                    .frame(width: 44, height: 26)
                Capsule()
                    .fill(.white)
                    .frame(width: 26, height: 22)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Small rounded-square icon, like the ones in System Settings, in greens.
struct IconChip: View {
    let symbol: String
    var shade: Color = Brand.color(Brand.forest)

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [shade.opacity(1), shade.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 0.6))
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
    }
}

/// Scrolls in the app; in presentation renders it draws everything instead, because the
/// off-screen renderer leaves scroll views empty.
struct RenderSafeScroll<Content: View>: View {
    @Environment(\.renderBackdrop) private var backdrop
    @ViewBuilder let content: () -> Content

    var body: some View {
        if backdrop != nil {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)   // as if scrolled to the top
                .clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) { content() }
        }
    }
}
