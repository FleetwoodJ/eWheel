import AppKit
import Observation
import SwiftUI

enum WheelMode: CaseIterable {
    case convert, tools, actions

    init?(flags: NSEvent.ModifierFlags) {
        guard let mode = WheelMode.allCases.first(where: { flags.contains(Prefs.key(for: $0).flag) }) else { return nil }
        self = mode
    }

    var prefKey: String { "key.\(self)" }
    var defaultKey: ModKey { switch self { case .convert: .shift; case .tools: .command; case .actions: .option } }
    var key: String { Prefs.key(for: self).glyph }
    var title: String { switch self { case .convert: "Convert"; case .tools: "Tools"; case .actions: "Actions" } }
}

enum Geo {
    static let outer: CGFloat = 172
    static let inner: CGFloat = 66
    static let wheelSize: CGFloat = 400      // square area holding the wheel
    static let hintHeight: CGFloat = 62      // row of mode capsules under the wheel
    static var panelSize: CGSize { CGSize(width: wheelSize, height: wheelSize + hintHeight) }
}

@MainActor @Observable
final class WheelModel {
    var urls: [URL] = []
    var kind: FileKind = .other
    var mode: WheelMode = .convert
    var items: [WheelItem] = []
    var selected: Int?
    var shown = false
    /// Wheel centre in screen coordinates (AppKit, y up).
    var center: CGPoint = .zero
    /// True near the bottom of a display, where the mode bar is drawn above the wheel.
    var barOnTop = false

    func configure(urls: [URL], mode: WheelMode) {
        self.urls = urls
        kind = FileKind.of(urls)
        setMode(mode)
    }

    func setMode(_ mode: WheelMode) {
        self.mode = mode
        items = Catalog.items(mode: mode, kind: kind, urls: urls)
        selected = nil
    }

    var subject: String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
    }

    /// Segment under a screen point, or nil for the centre / outside.
    func index(at p: CGPoint) -> Int? {
        let dx = p.x - center.x, dy = center.y - p.y          // flip to y-down like SwiftUI
        let d = hypot(dx, dy)
        guard !items.isEmpty, d > Geo.inner, d < Geo.outer + 60 else { return nil }
        let span = 360.0 / Double(items.count)
        var a = atan2(dy, dx) * 180 / .pi + 90                 // 0° = top, clockwise
        if a < 0 { a += 360 }
        return Int((a / span).rounded()) % items.count
    }

    func mode(atHint p: CGPoint) -> WheelMode? {
        // Screen coordinates (y up): the bar sits just below the wheel, or just above it.
        let half = Geo.wheelSize / 2
        let inBar = barOnTop
            ? (p.y > center.y + half && p.y < center.y + half + Geo.hintHeight)
            : (p.y < center.y - half && p.y > center.y - half - Geo.hintHeight)
        guard inBar else { return nil }
        let x = p.x - (center.x - Geo.wheelSize / 2)
        let i = Int(x / (Geo.wheelSize / 3))
        return WheelMode.allCases.indices.contains(i) ? WheelMode.allCases[i] : nil
    }
}

/// Shows and hides the wheel and runs whatever is dropped on it.
@MainActor
final class WheelController {
    let model = WheelModel()
    private lazy var panel = WheelPanel(model: model, controller: self)
    private let watcher = DragWatcher()
    private(set) var visible = false
    private(set) var clickMode = false
    private var outsideMonitor: Any?
    /// Menu-bar icon animation while work runs (set by the app delegate).
    var status: StatusAnimator?

    func start() {
        watcher.onModifier = { [weak self] mode, urls in self?.dragKey(mode: mode, urls: urls) }
        watcher.onKey = { [weak self] mode in
            guard let self, self.visible, self.clickMode else { return }
            self.model.setMode(mode)
        }
        watcher.onMouseUp = { [weak self] in
            guard let self, self.visible, !self.clickMode else { return }
            // Let the drop reach the panel before it goes away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !self.clickMode { self.hide() }
            }
        }
        watcher.onTick = { [weak self] in
            guard let self, self.visible, !self.clickMode else { return }
            self.track(NSEvent.mouseLocation)
        }
        watcher.start()
    }

    private func dragKey(mode: WheelMode, urls: [URL]) {
        if visible && !clickMode {
            model.setMode(mode)
        } else {
            show(urls: urls, mode: mode, at: NSEvent.mouseLocation, clickMode: false)
        }
    }

    /// Opens the wheel for chosen files without dragging (menu, Dock, command line).
    func openForFiles(_ urls: [URL]) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        show(urls: urls, mode: .convert, at: CGPoint(x: screen.midX, y: screen.midY), clickMode: true)
    }

    func show(urls: [URL], mode: WheelMode, at point: CGPoint, clickMode: Bool) {
        Log.wheel.notice("wheel shown: \(mode.title), \(urls.count) file(s)")
        self.clickMode = clickMode
        model.configure(urls: urls, mode: mode)
        let placed = panel.place(center: point)
        model.center = placed.center
        model.barOnTop = placed.barOnTop
        // If the wheel had to move to stay on screen, bring the pointer to its
        // centre, so you always start in the cancel zone and pick by direction.
        if !clickMode, hypot(placed.center.x - point.x, placed.center.y - point.y) > 4 {
            Self.movePointer(to: placed.center)
            Log.wheel.notice("near screen edge: wheel shifted, pointer moved to its centre")
        }
        model.shown = false
        panel.orderFrontRegardless()
        visible = true
        Clicker.shared.warmUp()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { model.shown = true }
        if clickMode && outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    /// Moves the pointer to a point in AppKit screen coordinates (origin bottom-left of
    /// the main display). CoreGraphics counts from the top-left, so y is flipped.
    static func movePointer(to p: CGPoint) {
        guard let main = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: main.frame.maxY - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)   // no pause in pointer movement after the jump
    }

    func hide() {
        guard visible else { return }
        visible = false
        clickMode = false
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        withAnimation(.easeOut(duration: 0.12)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            guard let self, !self.visible else { return }
            self.panel.orderOut(nil)
            Clicker.shared.rest()
        }
    }

    func track(_ p: CGPoint) {
        let i = model.index(at: p)
        if i != model.selected {
            withAnimation(.snappy(duration: 0.16)) { model.selected = i }
            if i != nil {
                Clicker.shared.click()
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    /// Called by a drop (drag mode) or a click (click mode).
    func activate(at p: CGPoint, urls: [URL]? = nil) -> Bool {
        if let mode = model.mode(atHint: p) { model.setMode(mode); return false }
        guard let i = model.index(at: p), model.items.indices.contains(i) else {
            Log.wheel.notice("drop outside segments, cancelled")
            hide()
            return false
        }
        let item = model.items[i]
        Log.wheel.notice("running \(item.detail)")
        let files = (urls?.isEmpty == false) ? urls! : model.urls
        hide()
        run(item, on: files)
        return true
    }

    func run(_ item: WheelItem, on files: [URL]) {
        let at = NSEvent.mouseLocation
        let started = Date()
        // Silent on success: no "working" or "saved" pop-ups. Only failures,
        // and results that are themselves information (word count), are shown.
        status?.begin()
        Task { @MainActor in
            do {
                Out.resetProduced()
                let message = try await item.run(files)
                let made = Out.produced.filter { FileManager.default.fileExists(atPath: $0.path) }
                if Prefs.revealAfter, !made.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(made) }
                Log.wheel.notice("done in \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(message)")
                if item.announces {
                    Toast.shared.show(title: message, detail: item.detail, symbol: item.symbol, at: at)
                }
                status?.end(success: true)
            } catch {
                Log.wheel.error("failed: \(error.localizedDescription)")
                status?.end(success: false)
                Toast.shared.show(title: "\(item.detail) failed", detail: error.localizedDescription,
                                  symbol: "exclamationmark.circle", at: at, duration: 4)
            }
        }
    }
}

// MARK: - Panel

final class WheelPanel: NSPanel {
    private weak var controller: WheelController?

    @MainActor
    init(model: WheelModel, controller: WheelController) {
        self.controller = controller
        super.init(contentRect: CGRect(origin: .zero, size: Geo.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false   // take drops on transparent pixels too
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = NSView(frame: CGRect(origin: .zero, size: Geo.panelSize))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        let drop = DropView(frame: root.bounds, controller: controller)
        drop.autoresizingMask = [.width, .height]
        root.addSubview(drop)
        contentView = root
    }

    override var canBecomeKey: Bool { false }

    /// Positions the panel so the wheel is centred on `center`, kept on screen.
    /// Near the bottom of a display the mode bar moves above the wheel, so the
    /// wheel itself needs to shift less. Returns the real centre and bar position.
    @MainActor
    func place(center: CGPoint) -> (center: CGPoint, barOnTop: Bool) {
        let size = Geo.panelSize
        let half = Geo.wheelSize / 2
        var barOnTop = false
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - Geo.hintHeight - half)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            if center.y - f.minY < half + Geo.hintHeight, f.maxY - center.y > center.y - f.minY {
                barOnTop = true
                origin.y = center.y - half
            }
            origin.x = min(max(origin.x, f.minX), f.maxX - size.width)
            origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        }
        setFrameOrigin(origin)
        let y = barOnTop ? origin.y + half : origin.y + Geo.hintHeight + half
        return (CGPoint(x: origin.x + size.width / 2, y: y), barOnTop)
    }
}

/// Transparent layer over the wheel that receives drops and clicks.
final class DropView: NSView {
    private weak var controller: WheelController?

    init(frame: CGRect, controller: WheelController) {
        self.controller = controller
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func screenPoint(_ windowPoint: CGPoint) -> CGPoint {
        window?.convertPoint(toScreen: windowPoint) ?? windowPoint
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Log.wheel.notice("drag entered wheel")
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let p = screenPoint(sender.draggingLocation)
        MainActor.assumeIsolated { controller?.track(p) }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let p = screenPoint(sender.draggingLocation)
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        Log.wheel.notice("drop on wheel, files: \(urls.count)")
        return MainActor.assumeIsolated { controller?.activate(at: p, urls: urls) ?? false }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        MainActor.assumeIsolated { controller?.track(p) }
    }

    override func mouseUp(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        MainActor.assumeIsolated { _ = controller?.activate(at: p) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
}
