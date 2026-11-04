import AppKit
import ServiceManagement
import SwiftUI

enum Credits {
    static let line = "Designed by JF · Built with Claude"
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "1.0.0")"
    }
}

/// The Settings window (⌘,).
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    static let size = CGSize(width: 540, height: 760)
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "eWheel Settings"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(red: 0x0A / 255, green: 0x21 / 255, blue: 0x17 / 255, alpha: 1)
            w.contentViewController = NSHostingController(rootView: SettingsView())
            // Come to whichever desktop (Space) you're on, instead of staying on the old one.
            w.collectionBehavior = [.moveToActiveSpace]
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible || !w.isOnActiveSpace { place(w) }
        // A menu-bar app is never frontmost when its icon is clicked, and since macOS 14
        // `activate()` is only a request the system may decline. Ask firmly, and order the
        // window in front regardless, so it can never open hidden behind another app.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        Log.wheel.notice("settings opened (eWheel active: \(NSApp.isActive), key: \(w.isKeyWindow))")
    }

    /// Centres the window on the display the pointer is on (where you clicked the
    /// menu-bar icon), rather than always on the main display, and keeps it on screen.
    private func place(_ w: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = w.frame.size
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        w.setFrameOrigin(origin)
    }
}

/// The window's own backdrop: deep Echoro Green with soft mint light, so the glass has something to refract.
struct SettingsBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0x1A / 255, green: 0x4A / 255, blue: 0x33 / 255), Echoro.green,
                                    Color(red: 0x06 / 255, green: 0x1A / 255, blue: 0x10 / 255)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Echoro.mint.opacity(0.22)).frame(width: 360).blur(radius: 80).offset(x: 200, y: -300)
            Circle().fill(Echoro.sage.opacity(0.40)).frame(width: 320).blur(radius: 80).offset(x: -210, y: 60)
            Circle().fill(Echoro.mint.opacity(0.12)).frame(width: 300).blur(radius: 70).offset(x: 160, y: 330)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .clipped()
    }
}

struct SettingsView: View {
    @AppStorage("key.convert") private var convertKey = ModKey.shift.rawValue
    @AppStorage("key.tools") private var toolsKey = ModKey.command.rawValue
    @AppStorage("key.actions") private var actionsKey = ModKey.option.rawValue
    @AppStorage("saveLocation") private var saveLocation = SaveLocation.beside.rawValue
    @AppStorage("revealAfter") private var revealAfter = false
    @AppStorage("hoverSound") private var hoverSound = true
    private let login = LoginItem()

    var body: some View {
        ZStack(alignment: .top) {
            SettingsBackground()
            VStack(spacing: 18) {
                header
                section("Wheel keys", footer: "Start dragging a file, then tap a key. Choosing a key another wheel uses swaps them.") {
                    ForEach(Array(WheelMode.allCases.enumerated()), id: \.offset) { i, mode in
                        if i > 0 { divider }
                        keyRow(mode)
                    }
                }
                section("Saving", footer: nil) {
                    row(icon: "folder.fill", shade: Echoro.sage, title: "Save converted files") { locationPicker }
                    divider
                    row(icon: "magnifyingglass", shade: Color(red: 0.26, green: 0.50, blue: 0.37), title: "Show in Finder after converting") {
                        GlassSwitch(isOn: $revealAfter)
                    }
                }
                section("General", footer: nil) {
                    row(icon: "speaker.wave.2.fill", shade: Color(red: 0.20, green: 0.44, blue: 0.31), title: "Click sound on hover") {
                        GlassSwitch(isOn: $hoverSound)
                    }
                    divider
                    row(icon: "power", shade: Echoro.green, title: "Launch at login") {
                        GlassSwitch(isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                    }
                }
                if let error = login.error {
                    Text(error).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
                footerBar
            }
            .padding(.horizontal, 26)
            .padding(.top, 40)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            Text("eWheel").font(.system(size: 26, weight: .bold, design: .rounded))
            Text(Credits.version).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Sections and rows

    private func section<C: View>(_ title: String, footer: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 14)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 4)
                .echoGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: GlassTint.clear)
            if let footer {
                Text(footer)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 14)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.09)).frame(height: 0.8).padding(.leading, 58)
    }

    private func row<C: View>(icon: String, shade: Color, title: String, subtitle: String? = nil,
                              @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 12) {
            IconChip(symbol: icon, shade: shade)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .medium, design: .rounded))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }

    // MARK: Wheel keys

    private func keyRow(_ mode: WheelMode) -> some View {
        let info: (String, Color, String) = switch mode {
        case .convert: ("arrow.triangle.2.circlepath", Echoro.sage, "Change a file's format")
        case .tools: ("wrench.and.screwdriver.fill", Color(red: 0.24, green: 0.48, blue: 0.35), "Compress, resize, rotate, merge")
        case .actions: ("bolt.fill", Color(red: 0.16, green: 0.38, blue: 0.27), "AirDrop, copy, move, Terminal")
        }
        return row(icon: info.0, shade: info.1, title: mode.title, subtitle: info.2) {
            HStack(spacing: 6) {
                ForEach(ModKey.allCases) { k in keycap(k, for: mode) }
            }
        }
    }

    private func keycap(_ k: ModKey, for mode: WheelMode) -> some View {
        let on = value(mode) == k.rawValue
        return Button { withAnimation(.snappy(duration: 0.2)) { choose(k.rawValue, for: mode) } } label: {
            Text(k.glyph)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? Echoro.deep : .white.opacity(0.85))
                .frame(width: 34, height: 30)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Echoro.mint)
                            .shadow(color: Echoro.mint.opacity(0.45), radius: 6)
                    }
                }
                .echoGlass(RoundedRectangle(cornerRadius: 9, style: .continuous),
                           tint: on ? GlassTint.selected : .white.opacity(0.04), interactive: true)
        }
        .buttonStyle(.plain)
        .help("\(k.name) opens \(mode.title)")
    }

    // MARK: Save location

    private var locationPicker: some View {
        HStack(spacing: 2) {
            ForEach(SaveLocation.allCases) { loc in
                let on = saveLocation == loc.rawValue
                Button { withAnimation(.snappy(duration: 0.2)) { saveLocation = loc.rawValue } } label: {
                    Text(loc.short)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(on ? Echoro.deep : .white.opacity(0.85))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background { if on { Capsule().fill(Echoro.mint) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .echoGlass(Capsule(), tint: .white.opacity(0.04))
    }

    // MARK: Footer

    private var footerBar: some View {
        let isDefault = WheelMode.allCases.allSatisfy { value($0) == $0.defaultKey.rawValue }
        return HStack {
            Button {
                withAnimation(.snappy(duration: 0.2)) { for m in WheelMode.allCases { set(m, m.defaultKey.rawValue) } }
            } label: {
                Label("Restore Default Keys", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .echoGlass(Capsule(), tint: GlassTint.clear, interactive: true)
            }
            .buttonStyle(.plain)
            .disabled(isDefault)
            .opacity(isDefault ? 0.45 : 1)
            Spacer()
            Text(Credits.line)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 4)
    }

    // Each key opens one wheel; picking a key that's already used swaps the two.
    private func value(_ m: WheelMode) -> String {
        switch m { case .convert: convertKey; case .tools: toolsKey; case .actions: actionsKey }
    }

    private func set(_ m: WheelMode, _ v: String) {
        switch m { case .convert: convertKey = v; case .tools: toolsKey = v; case .actions: actionsKey = v }
    }

    private func choose(_ new: String, for mode: WheelMode) {
        let old = value(mode)
        if let other = WheelMode.allCases.first(where: { $0 != mode && value($0) == new }) { set(other, old) }
        set(mode, new)
    }
}

@MainActor @Observable
final class LoginItem {
    var enabled = SMAppService.mainApp.status == .enabled
    var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
