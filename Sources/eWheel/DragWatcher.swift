import AppKit

/// Tiny file logger: ~/Library/Logs/eWheel.log (kept under ~200 KB).
enum Log {
    struct Channel: Sendable {
        func notice(_ s: String) { Log.write(s) }
        func error(_ s: String) { Log.write("ERROR " + s) }
    }
    static let wheel = Channel()
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/eWheel.log")
    private static let queue = DispatchQueue(label: "com.echoro.ewheel.log")

    static func write(_ s: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(s)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 200_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Watches for a file drag anywhere on screen and for modifier taps during it.
///
/// No Accessibility or Input Monitoring permission is needed: it polls the
/// class properties `NSEvent.pressedMouseButtons` / `NSEvent.modifierFlags`
/// and the system drag pasteboard, which every app may read.
@MainActor
final class DragWatcher {
    var onModifier: ((WheelMode, [URL]) -> Void)?   // a key was tapped while files are being dragged
    var onKey: ((WheelMode) -> Void)?                // a key was tapped while not dragging
    var onMouseUp: (() -> Void)?
    var onTick: (() -> Void)?

    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private let dragBoard = NSPasteboard(name: .drag)
    private lazy var lastCount = dragBoard.changeCount
    private var dragging = false
    private var mouseWasDown = false
    private var lastFlags: NSEvent.ModifierFlags = []

    func start() {
        // Without this, App Nap throttles a background menu-bar app's timers and drags are missed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Watching for file drags")
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        if !down && mouseWasDown { onMouseUp?() }
        mouseWasDown = down

        // A new drag writes to the drag pasteboard. Seeing its count change while
        // the button is held means a drag is in progress, even if this tick ran late.
        var justStarted = false
        let count = dragBoard.changeCount
        if count != lastCount {
            lastCount = count
            if down { dragging = true; justStarted = true }
        }
        if !down { dragging = false }

        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
        let newly = flags.subtracting(lastFlags)
        if dragging, !newly.isEmpty {
            let names = [(NSEvent.ModifierFlags.shift, "⇧"), (.command, "⌘"), (.control, "⌃"), (.option, "⌥")].filter { newly.contains($0.0) }.map(\.1)
            Log.wheel.notice("key pressed during drag: \(names.joined()) (wheel: \(WheelMode(flags: newly)?.title ?? "none assigned"))")
        }
        lastFlags = flags

        if justStarted { Log.wheel.notice("drag started, files: \(self.draggedFiles().count)") }

        // A key tapped during the drag, or already held when the drag began.
        if let mode = WheelMode(flags: newly) ?? (justStarted ? WheelMode(flags: flags) : nil) {
            let urls = dragging ? draggedFiles() : []
            Log.wheel.notice("key for \(mode.title), dragging: \(self.dragging), files: \(urls.count)")
            if !urls.isEmpty { onModifier?(mode, urls) } else { onKey?(mode) }
        }
        onTick?()
    }

    private func draggedFiles() -> [URL] {
        (dragBoard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
