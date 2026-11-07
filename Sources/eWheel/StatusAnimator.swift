import AppKit

/// Animates the menu-bar icon while eWheel is working.
///
/// - Working: the picked segment spins round the wheel (1.2 s a turn). With
///   Reduce Motion on, it steps from segment to segment instead.
/// - Done: all three segments fill solid for a moment.
/// - Failed: an alert symbol for two seconds (the error also shows as a pop-up).
@MainActor
final class StatusAnimator {
    private weak var button: NSStatusBarButton?
    private let plain = AppDelegate.statusIcon()
    private let badged = AppDelegate.statusIcon(badge: true)
    private var idle: NSImage { badge ? badged : plain }

    /// Shows a dot on the icon while an update is waiting to be installed.
    var badge = false {
        didSet {
            guard badge != oldValue, jobs == 0 else { return }
            button?.image = idle
            button?.toolTip = badge ? "eWheel: an update is available" : nil
        }
    }
    private let spin: [NSImage] = (0..<36).map { AppDelegate.statusIcon(rotation: Double($0) * 10) }
    private let done = AppDelegate.statusIcon(solid: true)
    private let failed: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "eWheel: something went wrong")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    private var jobs = 0
    private var frame = 0
    private var timer: Timer?
    private var startedAt = Date()
    private var settle: DispatchWorkItem?

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    func begin() {
        jobs += 1
        guard jobs == 1 else { return }
        settle?.cancel()
        startedAt = Date()
        frame = 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let step = reduceMotion ? 12 : 1          // 12 frames = one segment (120°)
        let t = Timer(timeInterval: reduceMotion ? 0.35 : 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(by: step) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        button?.image = spin[0]
        button?.toolTip = "eWheel is working…"
    }

    func end(success: Bool) {
        jobs = max(0, jobs - 1)
        guard jobs == 0 else { return }
        // Spin for at least half a second, so instant conversions still register.
        let wait = max(0, 0.5 - Date().timeIntervalSince(startedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.jobs == 0 else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.button?.image = success ? self.done : self.failed
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.jobs == 0 else { return }
                self.button?.image = self.idle
                self.button?.toolTip = self.badge ? "eWheel: an update is available" : nil
            }
            self.settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 0.9 : 2.0), execute: work)
        }
    }

    private func advance(by step: Int) {
        frame = (frame + step) % spin.count
        button?.image = spin[frame]
    }
}
