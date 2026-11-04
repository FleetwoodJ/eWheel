import AppKit
import SwiftUI

/// eWheel — a free, offline conversion wheel for macOS.
/// Drag any file, tap ⇧ / ⌘ / ⌥, and drop it on a segment.
@main
struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), args.count > i + 1 {
            Render.start(dir: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--selftest") {
            SelfTest.start(dir: args.count > i + 1 ? args[i + 1] : nil)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        if let i = args.firstIndex(of: "--open"), args.count > i + 1 {
            delegate.launchFile = URL(fileURLWithPath: args[i + 1])
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum Echoro {
    /// Echoro Green — the canonical brand colour (#123524).
    static let green = Color(red: 0x12 / 255, green: 0x35 / 255, blue: 0x24 / 255)
    /// Primary container tone (#C5ECD2).
    static let mint = Color(red: 0xC5 / 255, green: 0xEC / 255, blue: 0xD2 / 255)
    /// On-primary-container tone (#002112).
    static let deep = Color(red: 0x00, green: 0x21 / 255, blue: 0x12 / 255)
    /// Mid tone between the two (#5E8C70), used for secondary text.
    static let sage = Color(red: 0x5E / 255, green: 0x8C / 255, blue: 0x70 / 255)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    let controller = WheelController()
    var launchFile: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.statusIcon()
        controller.status = StatusAnimator(button: statusItem.button)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.start()
        Log.wheel.notice("launched")

        if let url = launchFile {
            controller.openForFiles([url])
        }
    }

    // Rebuilt every time it opens so the key hints follow Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func status(_ title: String, indent: Int = 0) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = indent
            menu.addItem(item)
        }
        status("eWheel is ready")
        status(Prefs.keySummary, indent: 1)
        status("Saving to: \(Prefs.saveLocation.title.lowercased())", indent: 1)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About eWheel", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit eWheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Wait for the menu to finish closing: activating while it is still tracking is often ignored.
    @objc private func openSettings() { DispatchQueue.main.async { SettingsWindow.shared.show() } }

    private static func creditText() -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return NSAttributedString(string: Credits.line, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: p,
        ])
    }

    /// Minimal About panel: icon, name, version and the credit line.
    @objc private func openAbout() { DispatchQueue.main.async { self.showAbout() } }

    private func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "eWheel",
            .applicationVersion: info["CFBundleShortVersionString"] as? String ?? "1.0.0",
            .version: info["CFBundleVersion"] as? String ?? "1",
            .credits: Self.creditText(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "",
        ])
    }

    /// Hidden for a menu-bar app, but lets ⌘, ⌘W and ⌘Q work while Settings is open.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "Quit eWheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    /// 18 pt template icon: a wheel of three segments (Convert, Tools, Actions)
    /// with one picked, plus a centre hub. Faded segments keep their alpha in a
    /// template image, so it adapts to light and dark menu bars.
    /// - rotation: degrees clockwise, used to spin the picked segment while working.
    /// - solid: all three segments full, the brief "done" frame.
    static func statusIcon(rotation: Double = 0, solid: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = NSPoint(x: 9, y: 9)
            let outer: CGFloat = 8, inner: CGFloat = 4.1, gap: CGFloat = 0.55
            let go = Double(gap / outer) * 180 / .pi, gi = Double(gap / inner) * 180 / .pi
            for i in 0..<3 {
                let mid = 90.0 - 120.0 * Double(i) - rotation
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: outer, startAngle: mid - 60 + go, endAngle: mid + 60 - go)
                p.appendArc(withCenter: c, radius: inner, startAngle: mid + 60 - gi, endAngle: mid - 60 + gi, clockwise: true)
                p.close()
                NSColor.black.withAlphaComponent(i == 0 || solid ? 1 : 0.38).setFill()
                p.fill()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "eWheel"
        return image
    }
}
