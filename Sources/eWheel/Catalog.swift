import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct WheelItem: Identifiable {
    let id = UUID()
    /// Short label on the segment, e.g. "PNG".
    let title: String
    let symbol: String
    /// Longer label in the centre, e.g. "Convert to PNG".
    let detail: String
    let run: @MainActor ([URL]) async throws -> String
    /// Show the result in a pop-up (only for results that are information, like a word count).
    var announces = false
    /// Opens a window first (Trim): the job only counts as working once the user confirms.
    var interactive = false
    /// Stable identity for Customise (hide / favourite); the title unless it changes with Settings.
    var key: String

    init(title: String, symbol: String, detail: String, run: @escaping @MainActor ([URL]) async throws -> String) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.run = run
        key = title
    }
}

enum FileKind: Equatable {
    case image, video, audio, pdf, document, data, subtitle, archive, folder, other, mixed

    static func of(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(kind(of:)))
        return kinds.count == 1 ? kinds.first! : .mixed
    }

    static func kind(of url: URL) -> FileKind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           url.pathExtension.lowercased() != "rtfd" { return .folder }
        let ext = url.pathExtension.lowercased()
        if ["srt", "vtt"].contains(ext) { return .subtitle }
        if ["csv", "tsv", "json"].contains(ext) { return .data }
        if ["md", "markdown"].contains(ext) { return .document }
        if ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "xar", "cpio"].contains(ext) { return .archive }
        guard let t = UTType(filenameExtension: ext) else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return Img.readable(t) ? .image : .other }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        let docs = ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                    "org.oasis-open.opendocument.text", "com.apple.webarchive", "com.apple.rtfd"]
        if t.conforms(to: .text) || t.conforms(to: .rtf) || docs.contains(t.identifier) { return .document }
        return .other
    }
}

@MainActor
enum Catalog {
    /// The segments for these files, with your Customise choices applied (unless `customised` is false).
    static func items(mode: WheelMode, kind: FileKind, urls: [URL], customised: Bool = true) -> [WheelItem] {
        let all: [WheelItem] = switch mode {
        case .convert: convert(kind, urls)
        case .tools: tools(kind, urls)
        case .actions: Actions.items
        }
        return customised ? Customisation.apply(all, mode: mode, kind: kind) : all
    }

    /// Every segment a wheel can show for a file type, for the Customise window.
    static func allItems(mode: WheelMode, kind: FileKind) -> [WheelItem] {
        // No real files: nothing is filtered out for matching the source format.
        let urls = kind == .mixed ? [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.pdf")] : []
        return items(mode: mode, kind: kind, urls: urls, customised: false)
    }

    // MARK: ⇧ Convert

    private static func convert(_ kind: FileKind, _ urls: [URL]) -> [WheelItem] {
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        func notSame(_ e: [String]) -> Bool { !(exts.count == 1 && e.contains(exts.first!)) }

        switch kind {
        case .image:
            return Img.outputFormats.filter { notSame($0.exts) }.map { f in
                item(f.label, "photo", "Convert to \(f.label)") { urls in
                    try await each(urls) { u in try await bg { try Img.convert(u, to: f.type, ext: f.exts[0]) } }
                }
            }
        case .video:
            return [
                item("MP4", "film", "Convert to MP4 (H.264)") { try await each($0) { try await AV.export($0, preset: AVAssetExportPresetHighestQuality, type: .mp4, ext: "mp4", remux: true) } },
                item("MOV", "film", "Convert to MOV") { try await each($0) { try await AV.export($0, preset: AVAssetExportPresetHighestQuality, type: .mov, ext: "mov", remux: true) } },
                item("HEVC", "film.stack", "Convert to HEVC (H.265)") { try await each($0) { try await AV.export($0, preset: AVAssetExportPresetHEVCHighestQuality, type: .mov, ext: "mov", suffix: "-hevc") } },
                item("720P", "rectangle.compress.vertical", "Convert to 720p MP4") { try await each($0) { try await AV.export($0, preset: AVAssetExportPreset1280x720, type: .mp4, ext: "mp4", suffix: "-720p") } },
                item("GIF", "photo.stack", "Convert to animated GIF") { try await each($0) { try await AV.gif($0) } },
                item("M4A", "waveform", "Extract audio as M4A") { try await each($0) { try await AV.audio($0) } },
            ].filter { notSame([$0.title.lowercased()]) }
        case .audio:
            let all: [(String, String, [String])] = [
                ("M4A", "m4a", ["-f", "m4af", "-d", "aac", "-b", "256000"]),
                ("WAV", "wav", ["-f", "WAVE", "-d", "LEI16"]),
                ("AIFF", "aiff", ["-f", "AIFF", "-d", "BEI16"]),
                ("FLAC", "flac", ["-f", "flac", "-d", "flac"]),
                ("ALAC", "m4a", ["-f", "m4af", "-d", "alac"]),
                ("CAF", "caf", ["-f", "caff", "-d", "LEI16"]),
            ]
            return all.filter { $0.0 == "ALAC" || notSame([$0.1, $0.1 == "aiff" ? "aif" : $0.1]) }.map { f in
                item(f.0, "waveform", "Convert to \(f.0)") { urls in
                    try await each(urls) { try await Audio.afconvert($0, ext: f.1, suffix: f.0 == "ALAC" ? "-alac" : "", args: f.2) }
                }
            }
        case .pdf:
            return [
                item("PNG", "photo", "Pages to PNG images") { try await each($0) { u in try await bg { try PDFTools.images(u, type: .png, ext: "png") } } },
                item("JPG", "photo", "Pages to JPG images") { try await each($0) { u in try await bg { try PDFTools.images(u, type: .jpeg, ext: "jpg") } } },
                item("TXT", "doc.plaintext", "Extract text") { try await each($0) { try PDFTools.text($0) } },
                item("RTF", "doc.richtext", "Extract rich text") { try await each($0) { try PDFTools.rtf($0) } },
            ]
        case .document:
            return Doc.outputs.filter { notSame([$0.ext]) }.map { f in
                item(f.label, f.ext == "pdf" ? "doc.richtext" : "doc.text", "Convert to \(f.label)") { urls in
                    try await each(urls) { try Doc.convert($0, ext: f.ext) }
                }
            }
        case .data:
            return [("CSV", "csv"), ("TSV", "tsv"), ("JSON", "json")].filter { notSame([$0.1]) }.map { f in
                item(f.0, "tablecells", "Convert to \(f.0)") { urls in
                    try await each(urls) { u in try await bg { try DataConv.convert(u, to: f.1) } }
                }
            }
        case .subtitle:
            return [("SRT", "srt"), ("VTT", "vtt"), ("TXT", "txt")].filter { notSame([$0.1]) }.map { f in
                item(f.0, "captions.bubble", "Convert to \(f.0)") { urls in
                    try await each(urls) { u in try await bg { try Subs.convert(u, to: f.1) } }
                }
            }
        case .archive:
            return [
                item("EXTRACT", "archivebox", "Extract archive") { try await each($0) { try await Arch.extract($0) } },
                item("ZIP", "doc.zipper", "Repack as ZIP") { try await each($0) { try await Arch.repack($0, as: "zip") } },
                item("TAR.GZ", "shippingbox", "Repack as TAR.GZ") { try await each($0) { try await Arch.repack($0, as: "tar.gz") } },
            ].filter { !($0.title == "ZIP" && exts == ["zip"]) }
        case .mixed:
            var items: [WheelItem] = []
            if Mixed.canCombine(urls) {
                items.append(item("PDF", "doc.on.doc", "Combine into one PDF") { "Saved " + (try await Mixed.combinePDF($0)).lastPathComponent })
            }
            return items + [
                item("ZIP", "doc.zipper", "Compress to ZIP") { "Saved " + (try await Arch.zip($0)).lastPathComponent },
                item("TAR.GZ", "shippingbox", "Compress to TAR.GZ") { "Saved " + (try await Arch.tgz($0)).lastPathComponent },
            ]
        case .folder, .other:
            return [
                item("ZIP", "doc.zipper", "Compress to ZIP") { "Saved " + (try await Arch.zip($0)).lastPathComponent },
                item("TAR.GZ", "shippingbox", "Compress to TAR.GZ") { "Saved " + (try await Arch.tgz($0)).lastPathComponent },
            ]
        }
    }

    // MARK: ⌘ Tools

    private static func tools(_ kind: FileKind, _ urls: [URL]) -> [WheelItem] {
        let zip = item("ZIP", "doc.zipper", "Compress to ZIP") { "Saved " + (try await Arch.zip($0)).lastPathComponent }
        switch kind {
        case .image:
            return [
                item("COMPRESS", "arrow.down.right.and.arrow.up.left", "Compress image") { try await each($0) { u in try await bg { try Img.compress(u) } } },
                item("≤ \(Prefs.targetMB) MB", "scalemass", "Compress to under \(Prefs.targetMB) MB") { urls in
                    let mb = Prefs.targetMB
                    return try await each(urls) { u in try await bg { try Img.compressToSize(u, maxBytes: mb * 1_000_000, label: "\(mb) MB") } }
                }.keyed("SIZE"),
                item("\(Prefs.resizeWidth) W", "arrow.left.and.right", "Resize to \(Prefs.resizeWidth) px wide") { urls in
                    let w = Prefs.resizeWidth
                    return try await each(urls) { u in try await bg { try Img.transform(u, suffix: "-\(w)w", Img.resize(toWidth: w)) } }
                }.keyed("WIDTH"),
                item("ROTATE", "rotate.right", "Rotate 90° clockwise") { try await each($0) { u in try await bg { try Img.transform(u, suffix: "-rotated", Img.rotate) } } },
                item("FLIP", "arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally") { try await each($0) { u in try await bg { try Img.transform(u, suffix: "-flipped", Img.flip) } } },
                item("SQUARE", "crop", "Crop to centre square") { try await each($0) { u in try await bg { try Img.transform(u, suffix: "-square", Img.square) } } },
                item("MONO", "circle.lefthalf.filled", "Black & white") { try await each($0) { u in try await bg { try Img.transform(u, suffix: "-mono", Img.mono) } } },
                item("STRIP", "location.slash", "Remove metadata") { try await each($0) { u in try await bg { try Img.transform(u, suffix: "-clean", keepMetadata: false) { $0 } } } },
                item("PDF", "doc.on.doc", "Combine into one PDF") { urls in "Saved " + (try await bg { try Img.combinePDF(urls) }).lastPathComponent },
            ]
        case .video:
            return [
                item("COMPRESS", "arrow.down.right.and.arrow.up.left", "Compress video (540p)") { try await each($0) { try await AV.export($0, preset: AVAssetExportPreset960x540, type: .mp4, ext: "mp4", suffix: "-compressed") } },
                item("TRIM", "timeline.selection", "Trim…") { urls in
                    guard let range = try await TrimPanel.ask(for: urls) else { return "Trim cancelled" }
                    JobProgress.begin()
                    return try await each(urls) { u in try await AV.trim(u, range: range) }
                }.interactiveItem,
                item("MUTE", "speaker.slash", "Remove audio") { try await each($0) { try await AV.mute($0) } },
                item("POSTER", "photo", "Save first frame") { try await each($0) { try await AV.poster($0) } },
                zip,
            ]
        case .audio:
            return [
                item("COMPRESS", "arrow.down.right.and.arrow.up.left", "Compress (AAC 96 kbps)") { try await each($0) { try await Audio.afconvert($0, ext: "m4a", suffix: "-compressed", args: ["-f", "m4af", "-d", "aac", "-b", "96000"]) } },
                item("TRIM", "timeline.selection", "Trim…") { urls in
                    guard let range = try await TrimPanel.ask(for: urls) else { return "Trim cancelled" }
                    JobProgress.begin()
                    return try await each(urls) { u in try await AV.trim(u, range: range) }
                }.interactiveItem,
                item("MONO", "speaker.wave.1", "Mix down to mono") { try await each($0) { try await Audio.afconvert($0, ext: "m4a", suffix: "-mono", args: ["-f", "m4af", "-d", "aac", "-b", "128000", "-c", "1"]) } },
                item("VOICE", "mic", "Voice memo (AAC 48 kbps mono)") { try await each($0) { try await Audio.afconvert($0, ext: "m4a", suffix: "-voice", args: ["-f", "m4af", "-d", "aac", "-b", "48000", "-c", "1", "-r", "127"]) } },
                zip,
            ]
        case .pdf:
            return [
                item("COMPRESS", "arrow.down.right.and.arrow.up.left", "Compress PDF") { try await each($0) { try PDFTools.compress($0) } },
                item("MERGE", "doc.on.doc", "Merge into one PDF") { "Saved " + (try PDFTools.merge($0)).lastPathComponent },
                item("SPLIT", "scissors", "Split into pages") { try await each($0) { try PDFTools.split($0) } },
                item("ROTATE", "rotate.right", "Rotate pages 90°") { try await each($0) { try PDFTools.rotate($0) } },
                zip,
            ]
        case .document:
            return [
                item("STATS", "number", "Word & character count") { try Doc.stats($0) }.announcing,
                item("PDF", "doc.richtext", "Convert to PDF") { try await each($0) { try Doc.convert($0, ext: "pdf") } },
                zip,
            ]
        case .mixed:
            var items: [WheelItem] = []
            if Mixed.kinds(urls).contains(where: Mixed.compressible) {
                items.append(item("COMPRESS", "arrow.down.right.and.arrow.up.left", "Compress each file") { try await Mixed.compress($0) })
            }
            if Mixed.canCombine(urls) {
                items.append(item("PDF", "doc.on.doc", "Combine into one PDF") { "Saved " + (try await Mixed.combinePDF($0)).lastPathComponent })
            }
            return items + [zip, item("TAR.GZ", "shippingbox", "Compress to TAR.GZ") { "Saved " + (try await Arch.tgz($0)).lastPathComponent }]
        case .data, .subtitle, .archive, .folder, .other:
            return [zip,
                    item("TAR.GZ", "shippingbox", "Compress to TAR.GZ") { "Saved " + (try await Arch.tgz($0)).lastPathComponent }]
        }
    }

    // MARK: helpers

    static func item(_ title: String, _ symbol: String, _ detail: String,
                     _ run: @escaping @MainActor ([URL]) async throws -> String) -> WheelItem {
        WheelItem(title: title, symbol: symbol, detail: detail, run: run)
    }
}

/// Runs `f` for every file and summarises what was written.
/// Files run in parallel, up to one per CPU core.
@MainActor
func each(_ urls: [URL], _ f: @escaping @Sendable @MainActor (URL) async throws -> URL) async throws -> String {
    let limit = max(2, ProcessInfo.processInfo.activeProcessorCount)
    // One file reports its own progress (e.g. a video export); several report files done.
    let quiet = urls.count > 1
    var outs: [URL] = []
    try await withThrowingTaskGroup(of: URL.self) { group in
        var pending = urls.makeIterator()
        for _ in 0..<limit {
            guard let u = pending.next() else { break }
            group.addTask { try await JobProgress.$muted.withValue(quiet) { try await f(u) } }
        }
        while let out = try await group.next() {
            outs.append(out)
            if quiet { JobProgress.report(Double(outs.count) / Double(urls.count)) }
            try Task.checkCancellation()
            if let u = pending.next() { group.addTask { try await JobProgress.$muted.withValue(quiet) { try await f(u) } } }
        }
    }
    return outs.count == 1 ? "Saved \(outs[0].lastPathComponent)" : "Saved \(outs.count) files"
}

/// Runs blocking work off the main thread.
func bg<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

struct WheelError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Picks a free output name next to the source: "photo.png", "photo 2.png", …
enum Out {
    static func base(of url: URL) -> String {
        var name = url.lastPathComponent
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".txz"] where name.lowercased().hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        if !url.pathExtension.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        return name
    }

    /// Folder new files go in, per Settings → "Save converted files".
    static func dir(for src: URL) -> URL {
        let fm = FileManager.default
        switch Prefs.saveLocation {
        case .beside: return src.deletingLastPathComponent()
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? src.deletingLastPathComponent()
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? src.deletingLastPathComponent()
        }
    }

    static func url(for src: URL, suffix: String = "", ext: String) -> URL {
        url(in: dir(for: src), base: base(of: src) + suffix, ext: ext)
    }

    /// Thread-safe: parallel jobs never get the same name.
    /// `record: false` for paths that aren't new files eWheel made (Move's destinations), so
    /// Undo and cancel-cleanup can never touch them.
    static func url(in dir: URL, base: String, ext: String, record: Bool = true) -> URL {
        lock.withLock {
            var candidate = dir.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
            var n = 2
            while FileManager.default.fileExists(atPath: candidate.path) || claimed.contains(candidate) {
                candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            claimed.insert(candidate)
            if record { _produced.append(candidate) }
            return candidate
        }
    }

    // Names handed out during the current run, so "Show in Finder" can select them.
    nonisolated(unsafe) private static var _produced: [URL] = []
    // Every name handed out, so a name is never reused before its file exists.
    nonisolated(unsafe) private static var claimed: Set<URL> = []
    private static let lock = NSLock()
    static var produced: [URL] { lock.withLock { _produced } }
    static func resetProduced() {
        lock.withLock {
            _produced.removeAll()
            claimed = claimed.filter { !FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    static func folder(for src: URL, suffix: String) throws -> URL {
        let dir = url(for: src, suffix: suffix, ext: "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension WheelItem {
    var announcing: WheelItem { var c = self; c.announces = true; return c }
    var interactiveItem: WheelItem { var c = self; c.interactive = true; return c }
    func keyed(_ key: String) -> WheelItem { var c = self; c.key = key; return c }
}
