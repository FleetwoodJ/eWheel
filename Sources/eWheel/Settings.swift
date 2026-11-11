import AppKit
import ServiceManagement
import SwiftUI

enum Credits {
    static let line = "Designed by Echoro · Built with Claude"
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "1.0.0")"
    }
}

/// The Settings window (⌘,).
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    static let size = CGSize(width: 820, height: 520)
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
            w.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Brand.hex(Brand.dBackground) : Brand.hex(Brand.lBackground) }
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

/// The window's own backdrop: the Echoro kit's Backdrop (deep green in dark mode, soft mint in light),
/// so the glass has something to refract.
struct SettingsBackground: View {
    var body: some View {
        Backdrop()
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
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @AppStorage(Appearance.key) private var appearance = "system"
    @AppStorage("targetMB") private var targetMB = 2
    @AppStorage("resizeWidth") private var resizeWidth = 1920
    @AppStorage("imageQuality") private var imageQuality = "high"
    private let login = LoginItem()

    var body: some View {
        ZStack(alignment: .top) {
            SettingsBackground()
            VStack(spacing: 14) {
                header
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 14) {
                        section("Wheel keys", footer: "Start dragging a file, then tap a key. Picking a key another wheel uses swaps them.") {
                            ForEach(Array(WheelMode.allCases.enumerated()), id: \.offset) { i, mode in
                                if i > 0 { divider }
                                keyRow(mode)
                            }
                            divider
                            row(icon: "slider.horizontal.3", title: "Segments", subtitle: "Hide some, star a favourite") {
                                Button { CustomiseWindow.shared.show() } label: {
                                    Text("Customise\u{2026}")
                                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 12).frame(height: 26)
                                        .echoGlass(Capsule(), tint: GlassTint.clear, interactive: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        section("Saving", footer: nil) {
                            row(icon: "folder.fill", title: "Save to") { locationPicker }
                            divider
                            row(icon: "magnifyingglass", title: "Reveal new files", subtitle: "Show them in Finder") { GlassSwitch(isOn: $revealAfter) }
                        }
                    }
                    VStack(spacing: 14) {
                        section("Tools", footer: "Quality is used for JPG, HEIC, WebP and AVIF.") {
                            row(icon: "camera.aperture", title: "Image quality") {
                                segmented([("High", "high"), ("Balanced", "balanced"), ("Small", "small")], selection: $imageQuality)
                            }
                            divider
                            row(icon: "scalemass.fill", title: "Compress to") {
                                segmented([1, 2, 5, 10].map { ("\($0) MB", "\($0)") },
                                          selection: Binding(get: { "\(targetMB)" }, set: { targetMB = Int($0) ?? 2 }))
                            }
                            divider
                            row(icon: "arrow.left.and.right", title: "Resize width") {
                                segmented([1280, 1920, 2560, 3840].map { ("\($0)", "\($0)") },
                                          selection: Binding(get: { "\(resizeWidth)" }, set: { resizeWidth = Int($0) ?? 1920 }))
                            }
                        }
                        section("General", footer: nil) {
                            row(icon: "circle.lefthalf.filled", title: "Appearance") {
                                segmented([("System", "system"), ("Light", "light"), ("Dark", "dark")], selection: $appearance) {
                                    Appearance.apply()
                                }
                            }
                            divider
                            row(icon: "speaker.wave.2.fill", title: "Click sound on hover") { GlassSwitch(isOn: $hoverSound) }
                            divider
                            row(icon: "power", title: "Launch at login") {
                                GlassSwitch(isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                            }
                            divider
                            row(icon: "arrow.down.circle.fill", title: "Check for updates", subtitle: "About once a day, on GitHub") {
                                GlassSwitch(isOn: $autoUpdateCheck)
                            }
                        }
                        if let error = login.error {
                            Text(error).font(.system(size: 11, design: .rounded)).foregroundStyle(Color.inkSecondary)
                        }
                    }
                }
                footerBar
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 18)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height, alignment: .top)
        .foregroundStyle(Color.ink)
    }

    // MARK: Header

    /// One compact line: icon, name and version.
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text("eWheel").font(.system(size: 20, weight: .bold, design: .rounded))
                Text(Credits.version).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Color.inkSecondary)
            }
            Spacer()
        }
        .padding(.leading, 60)   // clear of the window buttons
    }

    // MARK: Sections and rows

    private func section<C: View>(_ title: String, footer: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).tracking(0.8)
                .foregroundStyle(Color.inkSecondary)
                .padding(.leading, 14)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 4)
                .echoGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: GlassTint.clear)
            if let footer {
                Text(footer)
                    .font(.system(size: 10.5, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.horizontal, 14)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.divider).frame(height: 0.8).padding(.leading, 48)
    }

    private func row<C: View>(icon: String, title: String, subtitle: String? = nil,
                              @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 10) {
            IconChip(symbol: icon)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12.5, weight: .medium, design: .rounded)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Color.inkSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            control()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    // MARK: Wheel keys

    private func keyRow(_ mode: WheelMode) -> some View {
        let info: (String, String) = switch mode {
        case .convert: ("arrow.triangle.2.circlepath", "Change format")
        case .tools: ("wrench.and.screwdriver.fill", "Compress, resize, trim")
        case .actions: ("bolt.fill", "AirDrop, copy, move")
        }
        return row(icon: info.0, title: mode.title, subtitle: info.1) {
            HStack(spacing: 4) {
                ForEach(ModKey.allCases) { k in keycap(k, for: mode) }
            }
        }
    }

    private func keycap(_ k: ModKey, for mode: WheelMode) -> some View {
        let on = value(mode) == k.rawValue
        return Button { withAnimation(.snappy(duration: 0.2)) { choose(k.rawValue, for: mode) } } label: {
            Text(k.glyph)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? Color.onPick : Color.ink)
                .frame(width: 30, height: 26)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.pick)
                            .shadow(color: Color.pick.opacity(0.45), radius: 6)
                    }
                }
                .echoGlass(RoundedRectangle(cornerRadius: 9, style: .continuous),
                           tint: on ? GlassTint.picked : Color.ink.opacity(0.04), interactive: true)
        }
        .buttonStyle(.plain)
        .help("\(k.name) opens \(mode.title)")
    }

    // MARK: Save location

    private var locationPicker: some View {
        segmented(SaveLocation.allCases.map { ($0.short, $0.rawValue) }, selection: $saveLocation)
    }

    /// Capsule segmented control: glass track, picked option on a `pick` pill.
    private func segmented(_ options: [(String, String)], selection: Binding<String>, onPick: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { label, value in
                let on = selection.wrappedValue == value
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection.wrappedValue = value }
                    onPick()
                } label: {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(on ? Color.onPick : Color.ink)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background { if on { Capsule().fill(Color.pick) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .echoGlass(Capsule(), tint: Color.ink.opacity(0.04))
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
                .foregroundStyle(Color.inkSecondary)
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
