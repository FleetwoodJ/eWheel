import AppKit
import Observation
import SwiftUI

// MARK: - Saved choices: hidden segments and one favourite per wheel

/// Each wheel (Convert, Tools, Actions) × file type has its own segments. You can hide any of them
/// and star one as the favourite, which always takes the top position (the easiest flick).
enum Customisation {
    private static var d: UserDefaults { .standard }

    /// "convert/image", "tools/video", "actions" (Actions is the same for every file type).
    static func group(_ mode: WheelMode, _ kind: FileKind) -> String {
        mode == .actions ? "actions" : "\(mode)/\(kind == .folder ? FileKind.other : kind)"
    }

    private static func id(_ group: String, _ key: String) -> String { "\(group)#\(key)" }

    static var hidden: Set<String> {
        get { Set(d.stringArray(forKey: "hiddenSegments") ?? []) }
        set { d.set(newValue.sorted(), forKey: "hiddenSegments") }
    }

    static var favourites: [String: String] {
        get { d.dictionary(forKey: "favouriteSegments") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "favouriteSegments") }
    }

    static func isHidden(_ group: String, _ key: String) -> Bool { hidden.contains(id(group, key)) }

    static func setHidden(_ group: String, _ key: String, _ on: Bool) {
        var h = hidden
        if on { h.insert(id(group, key)) } else { h.remove(id(group, key)) }
        hidden = h
    }

    static func favourite(_ group: String) -> String? { favourites[group] }

    /// Starring the current favourite again clears it.
    static func toggleFavourite(_ group: String, _ key: String) {
        var f = favourites
        f[group] = f[group] == key ? nil : key
        favourites = f
        if f[group] == key { setHidden(group, key, false) }   // a favourite is always shown
    }

    static func reset(_ group: String) {
        hidden = hidden.filter { !$0.hasPrefix(group + "#") }
        var f = favourites
        f[group] = nil
        favourites = f
    }

    static func isCustomised(_ group: String) -> Bool {
        favourite(group) != nil || hidden.contains { $0.hasPrefix(group + "#") }
    }

    /// What the wheel shows: hidden segments removed (never all of them), favourite moved to the top.
    static func apply(_ items: [WheelItem], mode: WheelMode, kind: FileKind) -> [WheelItem] {
        let g = group(mode, kind)
        let fav = favourite(g)
        var shown = items.filter { $0.key == fav || !isHidden(g, $0.key) }
        if shown.isEmpty { shown = items }
        if let fav, let i = shown.firstIndex(where: { $0.key == fav }) {
            shown.insert(shown.remove(at: i), at: 0)
        }
        return shown
    }
}

// MARK: - The Customise window

@MainActor @Observable
final class CustomiseModel {
    var mode: WheelMode = .convert
    var kind: FileKind = .image
    /// Bumped after every change, so the list and preview re-read the saved choices.
    var version = 0

    var group: String { Customisation.group(mode, kind) }
    var all: [WheelItem] { _ = version; return Catalog.allItems(mode: mode, kind: kind) }
    var shown: [WheelItem] { _ = version; return Customisation.apply(all, mode: mode, kind: kind) }
    var favourite: String? { _ = version; return Customisation.favourite(group) }
    var customised: Bool { _ = version; return Customisation.isCustomised(group) }

    func isShown(_ item: WheelItem) -> Bool { _ = version; return !Customisation.isHidden(group, item.key) || favourite == item.key }

    func setShown(_ item: WheelItem, _ on: Bool) {
        // Never hide the last visible segment.
        if !on, shown.count <= 1 { return }
        Customisation.setHidden(group, item.key, !on)
        version += 1
    }

    func toggleFavourite(_ item: WheelItem) { Customisation.toggleFavourite(group, item.key); version += 1 }
    func reset() { Customisation.reset(group); version += 1 }

    static let kinds: [(String, FileKind)] = [
        ("Images", .image), ("Video", .video), ("Audio", .audio), ("PDF", .pdf), ("Documents", .document),
        ("Data", .data), ("Subtitles", .subtitle), ("Archives", .archive), ("Mixed", .mixed), ("Other", .other),
    ]
}

@MainActor
final class CustomiseWindow {
    static let shared = CustomiseWindow()
    static let size = CGSize(width: 540, height: 720)
    private var window: NSWindow?
    let model = CustomiseModel()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Customise the wheel"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]
            w.contentViewController = NSHostingController(rootView: CustomiseView(model: model))
            w.center()
            window = w
        }
        guard let w = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }
}

struct CustomiseView: View {
    let model: CustomiseModel

    var body: some View {
        ZStack(alignment: .top) {
            Backdrop()
            VStack(spacing: 14) {
                VStack(spacing: 3) {
                    Text("Customise the wheel").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Hide segments you don't use. Star a favourite to keep it at the top.")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(Color.inkSecondary)
                }
                .padding(.top, 34)

                chips(WheelMode.allCases.map { ("\($0.key)  \($0.title)", $0) }, selected: model.mode) { model.mode = $0 }
                if model.mode != .actions {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(CustomiseModel.kinds, id: \.0) { label, kind in
                            chip(label, on: model.kind == kind) { model.kind = kind }
                        }
                    }
                } else {
                    Text("Actions are the same for every kind of file.")
                        .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Color.inkSecondary)
                        .frame(height: 64)
                }

                HStack(alignment: .top, spacing: 14) {
                    MiniWheel(items: model.shown, favourite: model.favourite)
                        .frame(width: 150, height: 150)
                        .padding(10)
                        .echoGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: GlassTint.clear)
                    list
                }

                HStack {
                    Button { withAnimation(.snappy(duration: 0.2)) { model.reset() } } label: {
                        Label("Reset this wheel", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 14).frame(height: 30)
                            .echoGlass(Capsule(), tint: GlassTint.clear, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.customised)
                    .opacity(model.customised ? 1 : 0.45)
                    Spacer()
                    Text("\(model.shown.count) of \(model.all.count) shown")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .frame(width: CustomiseWindow.size.width, height: CustomiseWindow.size.height)
        .foregroundStyle(Color.ink)
        .animation(.snappy(duration: 0.2), value: model.version)
    }

    private var list: some View {
        RenderSafeScroll {
            VStack(spacing: 0) {
                ForEach(Array(model.all.enumerated()), id: \.element.key) { i, item in
                    if i > 0 { Rectangle().fill(Color.divider).frame(height: 0.8).padding(.leading, 44) }
                    row(item)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .echoGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: GlassTint.clear)
    }

    private func row(_ item: WheelItem) -> some View {
        let fav = model.favourite == item.key
        let shown = model.isShown(item)
        return HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 22)
                .foregroundStyle(shown ? Color.ink : Color.inkSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text(item.detail).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
            }
            .opacity(shown ? 1 : 0.55)
            Spacer(minLength: 6)
            Button { withAnimation(.snappy(duration: 0.2)) { model.toggleFavourite(item) } } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(fav ? Color.pick : Color.inkSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(fav ? "Favourite: always at the top. Click to clear." : "Make this the favourite (top of the wheel)")
            GlassSwitch(isOn: Binding(get: { shown }, set: { model.setShown(item, $0) }))
                .opacity(fav ? 0.5 : 1)
                .disabled(fav)
                .help(fav ? "The favourite is always shown" : (shown ? "Shown" : "Hidden"))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
    }

    private func chips<T: Equatable>(_ options: [(String, T)], selected: T, pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                chip(option.0, on: option.1 == selected) { pick(option.1) }
            }
        }
        .padding(3)
        .echoGlass(Capsule(), tint: Color.ink.opacity(0.04))
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { action() } } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? Color.onPick : Color.ink)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background { if on { Capsule().fill(Color.pick) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A small, flat picture of the wheel as it will open: favourite at the top, filled.
struct MiniWheel: View {
    let items: [WheelItem]
    let favourite: String?

    var body: some View {
        GeometryReader { g in
            let outer = min(g.size.width, g.size.height) / 2, inner = outer * 0.38
            let n = items.count
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.key) { i, item in
                    let top = i == 0 && favourite != nil
                    let shape = Sector(index: i, count: n, inner: inner, outer: outer, gap: 2)
                    shape.fill(top ? Color.pick : Color.ink.opacity(0.13))
                    shape.stroke(Color.ink.opacity(0.18), lineWidth: 0.6)
                    let a = -Double.pi / 2 + 2 * .pi / Double(max(n, 1)) * Double(i)
                    let r = (inner + outer) / 2
                    Text(item.title)
                        .font(.system(size: n > 8 ? 7.5 : 8.5, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: (outer - inner) * 0.95)
                        .foregroundStyle(top ? Color.onPick : Color.ink)
                        .offset(x: n == 1 ? 0 : cos(a) * r, y: n == 1 ? -r : sin(a) * r)
                }
                Circle().fill(Color.ink.opacity(0.08)).frame(width: inner * 2 - 8, height: inner * 2 - 8)
                Text("\(n)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Color.inkSecondary)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}
