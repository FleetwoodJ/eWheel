import AppKit
import CryptoKit

/// A newer release found on GitHub.
struct AppUpdate {
    let version: String
    let notes: String
    let dmgURL: URL
    let size: Int
    /// SHA-256 of the DMG as GitHub reports it ("digest" on the release asset), when available.
    let sha256: String?
    let pageURL: URL
}

/// One-click updates from the GitHub Releases of FleetwoodJ/eWheel.
///
/// Check: GET the latest release from GitHub's public API and compare its
/// version with this app's. That request is eWheel's only network access; it
/// sends nothing about you or your files, and automatic checks can be turned off.
///
/// Install: download the DMG, verify its size and SHA-256 against GitHub,
/// mount it, check the app inside is eWheel at the expected version, copy it
/// next to the running app, swap the two in place, and relaunch.
@MainActor
final class Updater {
    static let shared = Updater()
    static let repo = "FleetwoodJ/eWheel"

    private(set) var available: AppUpdate?
    private(set) var busy = false
    /// Called whenever `available` changes, so the menu and icon can follow.
    var onChange: (() -> Void)?
    var status: StatusAnimator?
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: Automatic checks

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// About once a day, and only when "Check for updates automatically" is on.
    private func checkIfDue() {
        guard Prefs.autoUpdateCheck, !busy else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        Task {
            do { try await check() } catch { Log.wheel.notice("automatic update check failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Checking

    @discardableResult
    func check() async throws -> AppUpdate? {
        // EWHEEL_UPDATE_FEED lets the release flow be tested against a local file.
        let feed = ProcessInfo.processInfo.environment["EWHEEL_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("eWheel/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WheelError(http.statusCode == 404 ? "No releases found on GitHub." : "GitHub replied with error \(http.statusCode).")
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw WheelError("GitHub's reply wasn't understood.") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let isFinal = json["draft"] as? Bool != true && json["prerelease"] as? Bool != true

        guard isFinal, Self.isNewer(version, than: currentVersion) else {
            set(nil)
            Log.wheel.notice("update check: up to date (\(currentVersion), latest \(version))")
            return nil
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let link = dmg["browser_download_url"] as? String, let url = URL(string: link) else {
            throw WheelError("eWheel \(version) is out, but its download isn't ready yet. Try again shortly.")
        }
        let digest = (dmg["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(Self.repo)/releases")!
        let update = AppUpdate(version: version, notes: json["body"] as? String ?? "", dmgURL: url,
                               size: dmg["size"] as? Int ?? 0, sha256: digest?.lowercased(), pageURL: page)
        set(update)
        Log.wheel.notice("update check: \(version) available (have \(currentVersion))")
        return update
    }

    private func set(_ update: AppUpdate?) {
        available = update
        onChange?()
    }

    /// Compares dotted versions numerically: 1.10.0 is newer than 1.9.2.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Menu actions

    /// "Check for Updates…": always gives an answer.
    func checkNow() {
        Task {
            do {
                if let update = try await check() { promptInstall(update) }
                else { alert("You're up to date", "eWheel \(currentVersion) is the latest version.") }
            } catch {
                alert("Couldn't check for updates", error.localizedDescription)
            }
        }
    }

    func promptInstall(_ update: AppUpdate) {
        guard !busy else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        a.messageText = "eWheel \(update.version) is available"
        var info = "You have version \(currentVersion)."
        let notes = Self.plainNotes(update.notes)
        if !notes.isEmpty { info += "\n\n" + notes }
        info += "\n\neWheel will download the update, replace itself and relaunch. It takes a few seconds."
        a.informativeText = info
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { install(update) }
    }

    func install(_ update: AppUpdate) {
        Task {
            do {
                try await performInstall(update, relaunch: true)
            } catch {
                Log.wheel.error("update failed: \(error.localizedDescription)")
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "The update couldn't be installed"
                a.informativeText = error.localizedDescription + "\n\nYou can download eWheel \(update.version) from GitHub instead."
                a.addButton(withTitle: "Open Download Page")
                a.addButton(withTitle: "Close")
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.pageURL) }
            }
        }
    }

    // MARK: Installing

    func performInstall(_ update: AppUpdate, relaunch: Bool) async throws {
        guard !busy else { return }
        busy = true
        status?.begin()
        var ok = false
        defer {
            busy = false
            status?.end(success: ok)
        }

        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        if app.path.contains("/AppTranslocation/") || app.path.hasPrefix("/Volumes/") {
            throw WheelError("eWheel is running from the disk image or a temporary location. Drag it into your Applications folder, open it from there, then update.")
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            throw WheelError("eWheel doesn't have permission to replace itself in \(folder.path).")
        }

        let work = fm.temporaryDirectory.appendingPathComponent("eWheel-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download
        Log.wheel.notice("update: downloading \(update.version)")
        let (temp, response) = try await URLSession.shared.download(from: update.dmgURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WheelError("The download failed (error \(http.statusCode)).")
        }
        let dmg = work.appendingPathComponent("eWheel.dmg")
        try fm.moveItem(at: temp, to: dmg)

        // 2. Verify size and checksum against what GitHub reported
        let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
        if update.size > 0, data.count != update.size {
            throw WheelError("The download was incomplete. Please try again.")
        }
        if let expected = update.sha256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw WheelError("The download didn't match GitHub's checksum, so it wasn't installed.") }
        }

        // 3. Mount (hidden from Finder) and check what's inside
        let mount = work.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try await Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        do {
            guard let name = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }),
                  let bundle = Bundle(url: mount.appendingPathComponent(name)) else {
                throw WheelError("The disk image doesn't contain the app.")
            }
            guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw WheelError("The downloaded app isn't eWheel, so it wasn't installed.")
            }
            // The app inside must carry an intact code signature for the same identifier.
            do {
                try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict",
                                                          "-R=identifier \"\(Bundle.main.bundleIdentifier ?? "")\"", bundle.bundleURL.path])
            } catch {
                throw WheelError("The downloaded app's signature couldn't be verified, so it wasn't installed.")
            }
            let newVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            guard newVersion == update.version else {
                throw WheelError("The download contains version \(newVersion), not \(update.version).")
            }

            // 4. Copy next to the running app, then swap the two in place
            let staged = folder.appendingPathComponent(".eWheel-\(update.version)-update.app")
            try? fm.removeItem(at: staged)
            try await Shell.run("/usr/bin/ditto", [bundle.bundleURL.path, staged.path])
            _ = try fm.replaceItemAt(app, withItemAt: staged)
        } catch {
            try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        ok = true
        Log.wheel.notice("update: installed \(update.version)")
        set(nil)
        if relaunch { Self.relaunch(app) }
    }

    /// Starts the new copy a moment after this one quits.
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    /// Release notes without Markdown symbols, kept short for the alert.
    static func plainNotes(_ md: String) -> String {
        let text = md
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: Test hook

    /// `eWheel --update-now`: check the feed and install without asking or relaunching.
    /// Used with EWHEEL_UPDATE_FEED to test the whole update flow locally.
    static func runHeadlessUpdate() {
        _ = NSApplication.shared
        Task { @MainActor in
            do {
                guard let update = try await shared.check() else { print("up to date"); exit(0) }
                print("installing \(update.version)…")
                try await shared.performInstall(update, relaunch: false)
                print("installed \(update.version)")
                exit(0)
            } catch {
                print("FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
