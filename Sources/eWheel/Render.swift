import AppKit
import AVFoundation
import SwiftUI

/// `eWheel --render <folder>` draws presentation images of the three wheels,
/// the Settings window and the menu-bar menu.
///
/// The wheels and Settings are the app's real views. Their glass is drawn by
/// `echoGlass`, which recreates Liquid Glass from the scene behind it when
/// `renderBackdrop` is set (the live material only exists on screen).
@MainActor
enum Render {
    static let size = CGSize(width: 1440, height: 900)

    /// Presentation images use the dark look; `light: true` renders the light look for review.
    static var scheme: ColorScheme = .dark

    static func start(dir: String, light: Bool = false) {
        _ = NSApplication.shared
        scheme = light ? .light : .dark
        NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        Task { @MainActor in
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let file = URL(fileURLWithPath: "/tmp/Holiday.jpg")
            let picks: [(WheelMode, String)] = [(.convert, "PNG"), (.tools, "COMPRESS"), (.actions, "AIRDROP")]
            for (i, (mode, pick)) in picks.enumerated() {
                let model = WheelModel()
                model.configure(urls: [file], mode: mode)
                model.selected = model.items.firstIndex { $0.title == pick } ?? 0
                model.shown = true
                save(WheelScene(model: model), to: out.appendingPathComponent("\(i + 1) eWheel – \(mode.title).png"))
            }
            save(SettingsScene(), to: out.appendingPathComponent("4 eWheel – Settings.png"))
            save(MenuScene(), to: out.appendingPathComponent("5 eWheel – Menu bar.png"))
            print("Rendered to \(out.path)")
            exit(0)
        }
        RunLoop.main.run()
    }

    static func save<V: View>(_ view: V, to url: URL) {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
        r.scale = 2
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("FAILED \(url.lastPathComponent)"); return
        }
        try? png.write(to: url)
        print("  \(url.lastPathComponent)")
    }
}

// MARK: - Scenery

private func hex(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
}

/// Desktop wallpaper: Echoro Green with soft mint light and a few brighter
/// shapes, so the glass has detail to refract.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            if Render.scheme == .light {
                LinearGradient(colors: [hex(0xF8FAF5), hex(0xD0E8D7), hex(0xC5ECD2)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                LinearGradient(colors: [hex(0x111412), hex(0x123524), hex(0x2B4E3B)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Circle().fill(hex(0xC5ECD2, 0.34)).frame(width: 640).blur(radius: 150).offset(x: -420, y: -230)
            Circle().fill(hex(0x2F6B57, 0.60)).frame(width: 560).blur(radius: 120).offset(x: 440, y: 260)
            Circle().fill(hex(0xA9CFB7, 0.26)).frame(width: 420).blur(radius: 90).offset(x: 180, y: -260)
            Ellipse().fill(hex(0x2B4E3B, 0.7)).frame(width: 900, height: 240).blur(radius: 80).rotationEffect(.degrees(-18)).offset(x: -60, y: 250)
            Ellipse().fill(hex(0xC5ECD2, 0.16)).frame(width: 520, height: 90).blur(radius: 30).rotationEffect(.degrees(-24)).offset(x: 120, y: -40)
        }
        .frame(width: Render.size.width, height: Render.size.height)
        .clipped()
    }
}

private struct MenuBar: View {
    var body: some View {
        HStack(spacing: 20) {
            Text("Finder").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(nsImage: AppDelegate.statusIcon()).renderingMode(.template)
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Text("Wed 4 Nov  22:40").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(width: Render.size.width, height: 30)
        .background(.black.opacity(0.2))
    }
}

private struct Caption: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 17, weight: .medium, design: .rounded)).foregroundStyle(Echoro.mint.opacity(0.8))
        }
        .fixedSize()
        .padding(.leading, 72).padding(.top, 752)
    }
}

private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("eWheel").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(Credits.line).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Echoro.mint.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 48).padding(.bottom, 40)
    }
}

// MARK: - Wheels

private struct WheelScene: View {
    let model: WheelModel
    let c = CGPoint(x: 820, y: 400)

    var body: some View {
        let n = max(model.items.count, 1)
        let sel = model.selected ?? 0
        let a = -Double.pi / 2 + 2 * .pi / Double(n) * Double(sel)
        let cursor = CGPoint(x: c.x + cos(a) * (Geo.outer - 10), y: c.y + sin(a) * (Geo.outer - 10))
        let key = Prefs.key(for: model.mode)
        let subtitle: String = switch model.mode {
        case .convert: "Drag a file, tap \(key.glyph) \(key.name), drop it on a new format."
        case .tools: "Tap \(key.glyph) \(key.name) to compress, resize, rotate, crop and more."
        case .actions: "Tap \(key.glyph) \(key.name) to AirDrop, copy, move or open in Terminal."
        }

        return ZStack(alignment: .topLeading) {
            Wallpaper()
            MenuBar()
            WheelView(model: model)
                .frame(width: Geo.panelSize.width, height: Geo.panelSize.height)
                .position(x: c.x, y: c.y + Geo.hintHeight / 2)
                .environment(\.renderBackdrop, AnyView(Wallpaper()))
            DragGhost().position(x: cursor.x + 26, y: cursor.y - 36)
            Cursor().position(x: cursor.x + 9, y: cursor.y + 12)
            Caption(title: "\(key.glyph)  \(model.mode.title)", subtitle: subtitle)
            BrandMark()
        }
    }
}

/// The file being dragged: a photo thumbnail with Finder's green "copy" badge.
private struct DragGhost: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                LinearGradient(colors: [hex(0xBFE3F2), hex(0xE9F6EE)], startPoint: .top, endPoint: .bottom)
                Circle().fill(hex(0xFFE9A8)).frame(width: 14).offset(x: 14, y: -10)
                Ellipse().fill(hex(0x2F6B57)).frame(width: 90, height: 40).offset(x: -16, y: 20)
                Ellipse().fill(hex(0x2B4E3B)).frame(width: 80, height: 36).offset(x: 22, y: 24)
            }
            .frame(width: 64, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .opacity(0.92)
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, hex(0x34C759))
                .offset(x: 8, y: -8)
        }
    }
}

private struct Cursor: View {
    var body: some View {
        ZStack {
            Image(systemName: "cursorarrow").font(.system(size: 24, weight: .black)).foregroundStyle(.white)
            Image(systemName: "cursorarrow").font(.system(size: 22, weight: .regular)).foregroundStyle(.black)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

// MARK: - Settings

private struct SettingsScene: View {
    let origin = CGPoint(x: 560, y: 120)

    var body: some View {
        let size = SettingsWindow.size
        ZStack(alignment: .topLeading) {
            Wallpaper()
            MenuBar()
            ZStack(alignment: .topLeading) {
                SettingsView()
                HStack(spacing: 8) {
                    Circle().fill(hex(0xFF5F57)); Circle().fill(hex(0xFEBC2E)); Circle().fill(hex(0x28C840))
                }
                .frame(width: 52, height: 12)
                .padding(.leading, 18).padding(.top, 18)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .padding(.leading, origin.x).padding(.top, origin.y)
            .environment(\.renderBackdrop, AnyView(
                ZStack(alignment: .topLeading) {
                    Wallpaper()
                    SettingsBackground().padding(.leading, origin.x).padding(.top, origin.y)
                }
                .frame(width: Render.size.width, height: Render.size.height, alignment: .topLeading)
            ))
            Caption(title: "Settings", subtitle: "Pick your keys, where files go, and how it sounds.")
        }
    }
}

// MARK: - Menu-bar menu

private struct MenuScene: View {
    let menu = CGRect(x: 1080, y: 36, width: 330, height: 216)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            MenuBar()
            VStack(alignment: .leading, spacing: 0) {
                item("eWheel is ready", dim: true)
                item(Prefs.keySummary, dim: true, indent: true)
                item("Saving to: \(Prefs.saveLocation.title.lowercased())", dim: true, indent: true)
                separator
                item("Settings…", shortcut: "⌘ ,", highlighted: true)
                item("Check for Updates…")
                item("About eWheel")
                separator
                item("Quit eWheel", shortcut: "⌘ Q")
            }
            .padding(6)
            .frame(width: menu.width, height: menu.height, alignment: .topLeading)
            .echoGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: hex(0x111412, 0.55))
            .padding(.leading, menu.minX).padding(.top, menu.minY)
            .environment(\.renderBackdrop, AnyView(Wallpaper()))
            Caption(title: "Menu bar", subtitle: "Always one click away: your keys, where files go, and Settings.")
            BrandMark()
        }
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func item(_ title: String, shortcut: String? = nil, dim: Bool = false, indent: Bool = false, highlighted: Bool = false) -> some View {
        HStack {
            Text(title).font(.system(size: 13.5))
            Spacer()
            if let shortcut { Text(shortcut).font(.system(size: 13)).opacity(0.6) }
        }
        .foregroundStyle(highlighted ? Echoro.deep : .white.opacity(dim ? 0.5 : 0.95))
        .padding(.leading, indent ? 26 : 10).padding(.trailing, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Echoro.mint.opacity(0.92) : .clear))
    }
}

// MARK: - Trim window (review image)

extension Render {
    /// `eWheel --render-trim <video> <out.png>`: draws the Trim window for a file, to review its design.
    static func trimPreview(file: String, out: String) {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            let url = URL(fileURLWithPath: file)
            let model = TrimModel(url: url, isVideo: true)
            model.count = 3   // review the several-files header
            model.duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 10
            model.start = model.duration * 0.15
            model.end = model.duration * 0.8
            if let (cg, _) = try? await AVAssetImageGenerator(asset: AVURLAsset(url: url)).image(at: CMTime(seconds: model.start, preferredTimescale: 600)) {
                model.preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            let size = CGSize(width: 480, height: 470)
            let view = TrimView(model: model, onCancel: {}, onTrim: {})
                .frame(width: size.width, height: size.height)
                .environment(\.renderBackdrop, AnyView(Backdrop().frame(width: size.width, height: size.height)))
                .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
                print("Wrote \(out)")
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}

// MARK: - Customise window (review image)

extension Render {
    /// `eWheel --render-customise <out.png>`: the Customise window with an example setup, to review its design.
    static func customisePreview(out: String) {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            // Example: Convert for images, PNG starred, BMP and GIF hidden. Restored afterwards.
            let savedHidden = Customisation.hidden, savedFav = Customisation.favourites
            let model = CustomiseModel()
            model.mode = .convert
            model.kind = .image
            Customisation.reset(model.group)
            Customisation.toggleFavourite(model.group, "PNG")
            Customisation.setHidden(model.group, "BMP", true)
            Customisation.setHidden(model.group, "GIF", true)
            model.version += 1
            let size = CustomiseWindow.size
            let view = CustomiseView(model: model)
                .environment(\.renderBackdrop, AnyView(Backdrop().frame(width: size.width, height: size.height)))
                .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
                print("Wrote \(out)")
            }
            Customisation.hidden = savedHidden
            Customisation.favourites = savedFav
            exit(0)
        }
        RunLoop.main.run()
    }
}
