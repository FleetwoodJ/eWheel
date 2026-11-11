import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Every converter below uses only frameworks and command-line tools that ship
// with macOS (ImageIO, AVFoundation, PDFKit, AppKit text system, afconvert,
// zip, ditto, tar). Nothing is downloaded or uploaded.

// MARK: - Images (ImageIO)

enum Img {
    struct Format { let label: String; let type: UTType; let exts: [String] }

    static let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static let readableTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    static func readable(_ t: UTType) -> Bool { readableTypes.contains(t.identifier) }

    static let outputFormats: [Format] = {
        let all: [Format] = [
            Format(label: "JPG", type: .jpeg, exts: ["jpg", "jpeg"]),
            Format(label: "PNG", type: .png, exts: ["png"]),
            Format(label: "HEIC", type: .heic, exts: ["heic", "heif"]),
            Format(label: "WEBP", type: .webP, exts: ["webp"]),
            Format(label: "AVIF", type: UTType("public.avif") ?? .heic, exts: ["avif"]),
            Format(label: "TIFF", type: .tiff, exts: ["tiff", "tif"]),
            Format(label: "GIF", type: .gif, exts: ["gif"]),
            Format(label: "BMP", type: .bmp, exts: ["bmp"]),
        ]
        return all.filter { writable.contains($0.type.identifier) }
            + [Format(label: "PDF", type: .pdf, exts: ["pdf"])]
    }()

    /// Loads the first frame with EXIF orientation applied, plus its metadata (minus orientation).
    static func load(_ url: URL) throws -> (CGImage, [CFString: Any]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw WheelError("Can't read \(url.lastPathComponent) as an image")
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 8192
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 8192
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw WheelError("Can't decode \(url.lastPathComponent)")
        }
        props[kCGImagePropertyOrientation] = nil
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { props[k] = nil }
        return (img, props)
    }

    static func hasAlpha(_ t: UTType) -> Bool { ![UTType.jpeg, .bmp].contains(t) }

    static func write(_ img: CGImage, to out: URL, type: UTType, quality: Double? = nil, meta: [CFString: Any]?) throws {
        if type == .pdf { return try writePDF([img], to: out) }
        let image = hasAlpha(type) ? img : flatten(img)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw WheelError("This Mac can't write \(type.preferredFilenameExtension?.uppercased() ?? "that format")")
        }
        var p = meta ?? [:]
        if let quality { p[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WheelError("Couldn't write \(out.lastPathComponent)") }
    }

    static func convert(_ src: URL, to type: UTType, ext: String) throws -> URL {
        let out = Out.url(for: src, ext: ext)
        if fastWrite(src, to: out, type: type, quality: Prefs.imageQuality) { return out }
        let (img, meta) = try load(src)
        try write(img, to: out, type: type, quality: Prefs.imageQuality, meta: meta)
        return out
    }

    static func compress(_ src: URL) throws -> URL {
        let srcType = UTType(filenameExtension: src.pathExtension.lowercased())
        let keep = srcType == .heic || srcType == .jpeg
        let type: UTType = keep ? srcType! : .jpeg
        let out = Out.url(for: src, suffix: "-compressed", ext: keep ? src.pathExtension : "jpg")
        if fastWrite(src, to: out, type: type, quality: 0.55) { return out }
        let (img, meta) = try load(src)
        try write(img, to: out, type: type, quality: 0.55, meta: meta)
        return out
    }

    /// Re-encodes straight from the source (no full decode, redraw or orientation
    /// baking), keeping all metadata. Used when the result would look identical:
    /// no transparency is lost, and the orientation tag survives in the new format.
    /// Returns false when the slow path is needed.
    static func fastWrite(_ src: URL, to out: URL, type: UTType, quality: Double) -> Bool {
        guard type != .pdf, let s = CGImageSourceCreateWithURL(src as CFURL, nil) else { return false }
        let props = (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]) ?? [:]
        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? true
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let keepsOrientation = [UTType.jpeg, .heic, .tiff].contains(type)
        guard !alpha || hasAlpha(type), orientation == 1 || keepsOrientation,
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(dest, s, 0, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func transform(_ src: URL, suffix: String, keepMetadata: Bool = true, _ f: (CGImage) -> CGImage) throws -> URL {
        let (img, meta) = try load(src)
        var type = UTType(filenameExtension: src.pathExtension.lowercased()) ?? .png
        var ext = src.pathExtension
        if !writable.contains(type.identifier) { type = .png; ext = "png" }
        let out = Out.url(for: src, suffix: suffix, ext: ext)
        try write(f(img), to: out, type: type, quality: Prefs.imageQuality, meta: keepMetadata ? meta : nil)
        return out
    }

    static func draw(_ w: Int, _ h: Int, gray: Bool = false, _ body: (CGContext) -> Void) -> CGImage {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!
        ctx.interpolationQuality = .high
        body(ctx)
        return ctx.makeImage()!
    }

    static func flatten(_ img: CGImage) -> CGImage {
        draw(img.width, img.height) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
            c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }

    static func rotate(_ img: CGImage) -> CGImage {
        draw(img.height, img.width) { c in
            c.translateBy(x: 0, y: CGFloat(img.width))
            c.rotate(by: -.pi / 2)
            c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }

    static func flip(_ img: CGImage) -> CGImage {
        draw(img.width, img.height) { c in
            c.translateBy(x: CGFloat(img.width), y: 0)
            c.scaleBy(x: -1, y: 1)
            c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }

    static func square(_ img: CGImage) -> CGImage {
        let s = min(img.width, img.height)
        let rect = CGRect(x: (img.width - s) / 2, y: (img.height - s) / 2, width: s, height: s)
        return img.cropping(to: rect) ?? img
    }

    static func mono(_ img: CGImage) -> CGImage {
        let flat = flatten(img)
        return draw(img.width, img.height, gray: true) {
            $0.draw(flat, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }

    /// One page per image, longest side 842 pt (A4 height).
    static func writePDF(_ images: [CGImage], to out: URL) throws {
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw WheelError("Couldn't create PDF") }
        for img in images {
            let s = 842 / CGFloat(max(img.width, img.height))
            var box = CGRect(x: 0, y: 0, width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
            let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func combinePDF(_ urls: [URL]) throws -> URL {
        let images = try urls.map { try load($0).0 }
        let out = urls.count == 1 ? Out.url(for: urls[0], ext: "pdf")
            : Out.url(in: Out.dir(for: urls[0]), base: "Images", ext: "pdf")
        try writePDF(images, to: out)
        return out
    }
}

// MARK: - Video (AVFoundation)

enum AV {
    /// With `remux`, streams are copied into the new container without
    /// re-encoding when the format allows it (seconds instead of minutes).
    static func export(_ src: URL, preset: String, type: AVFileType, ext: String, suffix: String = "",
                       remux: Bool = false) async throws -> URL {
        let asset = AVURLAsset(url: src)
        var chosen = preset
        if remux, await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                          with: asset, outputFileType: type) {
            chosen = AVAssetExportPresetPassthrough
        }
        return try await export(asset, from: src, preset: chosen, type: type, ext: ext, suffix: suffix)
    }

    static func export(_ asset: AVAsset, from src: URL, preset: String, type: AVFileType, ext: String, suffix: String) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw WheelError("This file can't be exported with that preset")
        }
        let out = Out.url(for: src, suffix: suffix, ext: ext)
        // Live progress for the menu while the export runs
        // Reading an export session's state from another task is safe; AVFoundation just doesn't mark it Sendable.
        nonisolated(unsafe) let watched = session
        let monitor = Task {
            for await state in watched.states(updateInterval: 0.25) {
                if case .exporting(let progress) = state { JobProgress.report(progress.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: out, as: type)
        try Task.checkCancellation()
        return out
    }

    static func audio(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw WheelError("\(src.lastPathComponent) has no audio track")
        }
        var preset = AVAssetExportPresetAppleM4A
        if await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .m4a) {
            preset = AVAssetExportPresetPassthrough
        }
        return try await export(asset, from: src, preset: preset, type: .m4a, ext: "m4a", suffix: "")
    }

    static func mute(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration)
        let comp = AVMutableComposition()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw WheelError("No video track") }
        for t in tracks {
            let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try ct?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: t, at: .zero)
            ct?.preferredTransform = try await t.load(.preferredTransform)
        }
        return try await export(comp, from: src, preset: AVAssetExportPresetPassthrough, type: .mov, ext: "mov", suffix: "-muted")
    }

    static func poster(_ src: URL) async throws -> URL {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: src))
        gen.appliesPreferredTrackTransform = true
        let (img, _) = try await gen.image(at: .zero)
        let out = Out.url(for: src, suffix: "-poster", ext: "png")
        try Img.write(img, to: out, type: .png, meta: nil)
        return out
    }

    /// Up to 15 s at 10 fps, max 480 px.
    static func gif(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let seconds = try await asset.load(.duration).seconds
        let fps = 10.0
        let count = max(1, Int(min(seconds, 15) * fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let tol = CMTime(value: 1, timescale: 20)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        let out = Out.url(for: src, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw WheelError("Couldn't create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        var seen = 0
        for await result in gen.images(for: times) {
            try Task.checkCancellation()
            if let img = try? result.image { CGImageDestinationAddImage(dest, img, frame); added += 1 }
            seen += 1
            JobProgress.report(Double(seen) / Double(count))
        }
        guard added > 0, CGImageDestinationFinalize(dest) else { throw WheelError("No frames could be read") }
        return out
    }
}

// MARK: - Audio (afconvert)

enum Audio {
    static func afconvert(_ src: URL, ext: String, suffix: String = "", args: [String]) async throws -> URL {
        let out = Out.url(for: src, suffix: suffix, ext: ext)
        try await Shell.run("/usr/bin/afconvert", args + [src.path, out.path])
        return out
    }
}

// MARK: - PDF (PDFKit)

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw WheelError("Can't open \(url.lastPathComponent)") }
        if doc.isLocked { throw WheelError("\(url.lastPathComponent) is password protected") }
        return doc
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let w = Int((rotated ? box.height : box.width) * scale), h = Int((rotated ? box.width : box.height) * scale)
        return Img.draw(w, h) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: c)
        }
    }

    static func images(_ src: URL, type: UTType, ext: String) throws -> URL {
        let doc = try open(src)
        if doc.pageCount == 1, let p = doc.page(at: 0) {
            let out = Out.url(for: src, ext: ext)
            try Img.write(render(p), to: out, type: type, quality: Prefs.imageQuality, meta: nil)
            return out
        }
        let dir = try Out.folder(for: src, suffix: " pages")
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let out = dir.appendingPathComponent("\(Out.base(of: src))-\(i + 1).\(ext)")
            try Img.write(render(p), to: out, type: type, quality: Prefs.imageQuality, meta: nil)
        }
        return dir
    }

    static func text(_ src: URL) throws -> URL {
        let out = Out.url(for: src, ext: "txt")
        try (try open(src).string ?? "").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func rtf(_ src: URL) throws -> URL {
        let doc = try open(src)
        let all = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.attributedString { all.append(s); all.append(NSAttributedString(string: "\n\n")) }
        }
        let data = try all.data(from: NSRange(location: 0, length: all.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let out = Out.url(for: src, ext: "rtf")
        try data.write(to: out)
        return out
    }

    static func compress(_ src: URL) throws -> URL {
        let out = Out.url(for: src, suffix: "-compressed", ext: "pdf")
        guard try open(src).write(to: out, withOptions: [.saveImagesAsJPEGOption: true,
                                                          .optimizeImagesForScreenOption: true]) else {
            throw WheelError("Couldn't write \(out.lastPathComponent)")
        }
        return out
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for u in urls {
            let doc = try open(u)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { merged.insert(p, at: merged.pageCount) } }
        }
        let out = Out.url(in: Out.dir(for: urls[0]), base: urls.count == 1 ? Out.base(of: urls[0]) + "-merged" : "Merged", ext: "pdf")
        guard merged.write(to: out) else { throw WheelError("Couldn't write \(out.lastPathComponent)") }
        return out
    }

    static func split(_ src: URL) throws -> URL {
        let doc = try open(src)
        let dir = try Out.folder(for: src, suffix: " pages")
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let single = PDFDocument()
            single.insert(p, at: 0)
            single.write(to: dir.appendingPathComponent("\(Out.base(of: src))-\(i + 1).pdf"))
        }
        return dir
    }

    static func rotate(_ src: URL) throws -> URL {
        let doc = try open(src)
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += 90 }
        let out = Out.url(for: src, suffix: "-rotated", ext: "pdf")
        guard doc.write(to: out) else { throw WheelError("Couldn't write \(out.lastPathComponent)") }
        return out
    }
}

// MARK: - Documents (AppKit text system)

@MainActor
enum Doc {
    static let outputs: [(label: String, ext: String)] = [
        ("PDF", "pdf"), ("DOCX", "docx"), ("RTF", "rtf"), ("TXT", "txt"), ("HTML", "html"), ("ODT", "odt"), ("DOC", "doc"),
    ]

    static func load(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let a = try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return NSAttributedString(a)
        }
        if ext == "txt" || UTType(filenameExtension: ext)?.conforms(to: .plainText) == true {
            let text = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    static func convert(_ src: URL, ext: String) throws -> URL {
        let a = try load(src)
        let out = Out.url(for: src, ext: ext)
        switch ext {
        case "pdf": try printPDF(a, to: out)
        case "txt": try a.string.write(to: out, atomically: true, encoding: .utf8)
        default:
            let types: [String: NSAttributedString.DocumentType] = [
                "rtf": .rtf, "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "html": .html,
            ]
            let data = try a.data(from: NSRange(location: 0, length: a.length),
                                  documentAttributes: [.documentType: types[ext]!, .characterEncoding: String.Encoding.utf8.rawValue])
            try data.write(to: out)
        }
        return out
    }

    /// Paginated A4 PDF via the print system, saved straight to disk.
    static func printPDF(_ a: NSAttributedString, to out: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: out])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 595, height: 842)
        for m in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: m] = 54 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 595 - 108, height: 842 - 108))
        view.appearance = NSAppearance(named: .aqua)
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: 487, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(a)
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else { throw WheelError("Couldn't create PDF") }
    }

    static func stats(_ urls: [URL]) throws -> String {
        var words = 0, chars = 0
        for u in urls {
            let s = try load(u).string
            chars += s.count
            s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { _, _, _, _ in words += 1 }
        }
        let text = "\(words.formatted()) words · \(chars.formatted()) characters"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text + " (copied)"
    }
}

// MARK: - CSV / TSV / JSON

enum DataConv {
    static func parse(_ s: String, sep: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, it = s.makeIterator(), pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } }
                    else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty { quoted = true }
            else if c == sep { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" || c == "\r" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func delimited(_ rows: [[String]], sep: Character) -> String {
        rows.map { $0.map { f in
            f.contains(sep) || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
        }.joined(separator: String(sep)) }.joined(separator: "\n") + "\n"
    }

    static func load(_ url: URL) throws -> [[String]] {
        let s = try String(contentsOf: url, encoding: .utf8)
        switch url.pathExtension.lowercased() {
        case "tsv": return parse(s, sep: "\t")
        case "json":
            guard let arr = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any] else {
                throw WheelError("JSON must be an array of objects")
            }
            var headers: [String] = []
            for case let o as [String: Any] in arr { for k in o.keys.sorted() where !headers.contains(k) { headers.append(k) } }
            let rows = arr.map { el -> [String] in
                let o = el as? [String: Any] ?? [:]
                return headers.map { h in
                    guard let v = o[h], !(v is NSNull) else { return "" }
                    if let s = v as? String { return s }
                    if let d = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed) { return String(decoding: d, as: UTF8.self) }
                    return "\(v)"
                }
            }
            return [headers] + rows
        default: return parse(s, sep: ",")
        }
    }

    static func json(_ rows: [[String]]) throws -> String {
        guard let headers = rows.first else { return "[]\n" }
        func q(_ s: String) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), as: UTF8.self) }
        let objects = try rows.dropFirst().map { r in
            "  {" + (try headers.enumerated().map { i, h in "\(try q(h)): \(try q(i < r.count ? r[i] : ""))" }.joined(separator: ", ")) + "}"
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let rows = try load(src)
        let text = ext == "json" ? try json(rows) : delimited(rows, sep: ext == "tsv" ? "\t" : ",")
        let out = Out.url(for: src, ext: ext)
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

// MARK: - Subtitles

enum Subs {
    struct Cue { var start: String; var end: String; var text: String }

    static func normalise(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if s.split(separator: ":").count == 2 { s = "00:" + s }
        return s
    }

    static func parse(_ s: String) -> [Cue] {
        let text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[i].components(separatedBy: "-->")
            let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Cue(start: normalise(parts[0]), end: normalise(end), text: body)
        }
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let cues = parse(try String(contentsOf: src, encoding: .utf8))
        guard !cues.isEmpty else { throw WheelError("No subtitle cues found") }
        let out: String
        switch ext {
        case "srt":
            out = cues.enumerated().map { i, c in
                "\(i + 1)\n\(c.start.replacingOccurrences(of: ".", with: ",")) --> \(c.end.replacingOccurrences(of: ".", with: ","))\n\(c.text)\n"
            }.joined(separator: "\n")
        case "vtt":
            out = "WEBVTT\n\n" + cues.map { "\($0.start) --> \($0.end)\n\($0.text)\n" }.joined(separator: "\n")
        default:
            out = cues.map(\.text).joined(separator: "\n") + "\n"
        }
        let dest = Out.url(for: src, ext: ext)
        try out.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }
}

// MARK: - Archives (zip, ditto, tar)

enum Arch {
    private static func outName(_ urls: [URL], ext: String) -> URL {
        let dir = Out.dir(for: urls[0])
        return urls.count == 1 ? Out.url(in: dir, base: Out.base(of: urls[0]), ext: ext) : Out.url(in: dir, base: "Archive", ext: ext)
    }

    static func zip(_ urls: [URL]) async throws -> URL {
        let out = outName(urls, ext: "zip")
        try await Shell.run("/usr/bin/zip", ["-r", "-q", "-y", "-X", out.path] + urls.map(\.lastPathComponent) + ["-x", "*.DS_Store"],
                            cwd: urls[0].deletingLastPathComponent())
        return out
    }

    static func tgz(_ urls: [URL]) async throws -> URL {
        let out = outName(urls, ext: "tar.gz")
        try await Shell.run("/usr/bin/tar", ["--exclude", ".DS_Store", "-czf", out.path, "-C", urls[0].deletingLastPathComponent().path]
                            + urls.map(\.lastPathComponent))
        return out
    }

    static func extract(_ src: URL) async throws -> URL {
        let dir = try Out.folder(for: src, suffix: "")
        do { try await Shell.run("/usr/bin/tar", ["-xf", src.path, "-C", dir.path]) }
        catch { try? FileManager.default.removeItem(at: dir); throw error }
        return dir
    }

    static func repack(_ src: URL, as ext: String) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await Shell.run("/usr/bin/tar", ["-xf", src.path, "-C", tmp.path])
        let out = Out.url(for: src, ext: ext)
        if ext == "zip" {
            try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", tmp.path, out.path])
        } else {
            try await Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", tmp.path, "."])
        }
        return out
    }
}

// MARK: - Shell

enum Shell {
    /// Runs a command-line tool; cancelling the task stops the tool.
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = err.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 { cont.resume() }
                else if proc.terminationReason == .uncaughtSignal { cont.resume(throwing: CancellationError()) }   // stopped by Cancel
                else {
                    let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: WheelError(msg.isEmpty ? "\((exe as NSString).lastPathComponent) failed" : String(msg.prefix(200))))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
          }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        try Task.checkCancellation()
    }
}

// MARK: - ⌥ File actions

@MainActor
enum Actions {
    static var items: [WheelItem] { [
        Catalog.item("AIRDROP", "dot.radiowaves.left.and.right", "Share with AirDrop") { urls in
            guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
                throw WheelError("AirDrop isn't available")
            }
            NSApp.activate()
            s.perform(withItems: urls)
            return "AirDrop opened"
        },
        Catalog.item("COPY", "doc.on.doc", "Copy files") { urls in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            return "Copied \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")"
        },
        Catalog.item("MOVE", "folder", "Move to folder…") { urls in
            NSApp.activate()
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Move Here"
            guard panel.runModal() == .OK, let dest = panel.url else { return "Move cancelled" }
            for u in urls {
                let ext = u.pathExtension
                try FileManager.default.moveItem(at: u, to: Out.url(in: dest, base: Out.base(of: u), ext: ext, record: false))
            }
            return "Moved to \(dest.lastPathComponent)"
        },
        Catalog.item("COPY PATH", "link", "Copy full path") { urls in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            return urls.count == 1 ? "Path copied" : "\(urls.count) paths copied"
        },
        Catalog.item("TERMINAL", "terminal", "Open in Terminal") { urls in
            let u = urls[0]
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let dir = isDir ? u : u.deletingLastPathComponent()
            guard let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw WheelError("No terminal app found")
            }
            try await NSWorkspace.shared.open([dir], withApplicationAt: term, configuration: .init())
            return "Opened \(dir.lastPathComponent)"
        },
        Catalog.item("REVEAL", "magnifyingglass", "Show in Finder") { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return "Shown in Finder"
        },
        Catalog.item("SHA-256", "number.square", "Copy SHA-256 checksum") { urls in
            let lines = try await bg {
                try urls.map { u -> String in
                    let data = try Data(contentsOf: u, options: .mappedIfSafe)
                    let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    return urls.count == 1 ? hex : "\(hex)  \(u.lastPathComponent)"
                }
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            return "Checksum copied"
        },
    ] }
}

// MARK: - Mixed selections (files of different kinds dragged together)

@MainActor
enum Mixed {
    static func kinds(_ urls: [URL]) -> Set<FileKind> { Set(urls.map(FileKind.kind(of:))) }

    /// Every file is an image or a PDF, so they can become one PDF.
    static func canCombine(_ urls: [URL]) -> Bool { kinds(urls).isSubset(of: [.image, .pdf]) }

    static func compressible(_ kind: FileKind) -> Bool { [.image, .video, .audio, .pdf].contains(kind) }

    /// Images become pages and PDFs add all their pages, in the order the files were dragged.
    static func combinePDF(_ urls: [URL]) async throws -> URL {
        let merged = PDFDocument()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("eWheel-combine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (i, u) in urls.enumerated() {
            try Task.checkCancellation()
            let doc: PDFDocument
            if FileKind.kind(of: u) == .pdf {
                doc = try PDFTools.open(u)
            } else {
                let page = tmp.appendingPathComponent("\(i).pdf")
                try await bg { try Img.writePDF([Img.load(u).0], to: page) }
                guard let d = PDFDocument(url: page) else { throw WheelError("Couldn't add \(u.lastPathComponent)") }
                doc = d
            }
            for p in 0..<doc.pageCount { if let page = doc.page(at: p) { merged.insert(page, at: merged.pageCount) } }
            JobProgress.report(Double(i + 1) / Double(urls.count))
        }
        let out = Out.url(in: Out.dir(for: urls[0]), base: urls.count == 1 ? Out.base(of: urls[0]) : "Combined", ext: "pdf")
        guard merged.write(to: out) else { throw WheelError("Couldn't write \(out.lastPathComponent)") }
        return out
    }

    /// Compresses each file the way that suits it; skips kinds that can't be compressed.
    static func compress(_ urls: [URL]) async throws -> String {
        var done = 0, skipped = 0
        for (i, u) in urls.enumerated() {
            try Task.checkCancellation()
            try await JobProgress.$muted.withValue(true) {
                switch FileKind.kind(of: u) {
                case .image: _ = try await bg { try Img.compress(u) }; done += 1
                case .video: _ = try await AV.export(u, preset: AVAssetExportPreset960x540, type: .mp4, ext: "mp4", suffix: "-compressed"); done += 1
                case .audio: _ = try await Audio.afconvert(u, ext: "m4a", suffix: "-compressed", args: ["-f", "m4af", "-d", "aac", "-b", "96000"]); done += 1
                case .pdf: _ = try PDFTools.compress(u); done += 1
                default: skipped += 1
                }
            }
            JobProgress.report(Double(i + 1) / Double(urls.count))
        }
        if done == 0 { throw WheelError("None of these files can be compressed.") }
        return "Compressed \(done) file\(done == 1 ? "" : "s")" + (skipped > 0 ? ", skipped \(skipped)" : "")
    }
}
