import AppKit
import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Compress to a target size, resize to a width (images)

extension Img {
    /// Best quality that fits under `maxBytes`, scaling down only when quality alone can't get there.
    /// HEIC stays HEIC; everything else becomes JPEG.
    static func compressToSize(_ src: URL, maxBytes: Int, label: String) throws -> URL {
        let original = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        if original <= maxBytes { throw WheelError("\(src.lastPathComponent) is already under \(label).") }
        var (img, meta) = try load(src)
        let type: UTType = UTType(filenameExtension: src.pathExtension.lowercased()) == .heic ? .heic : .jpeg

        func encode(_ image: CGImage, _ q: Double) -> Data? {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            var p = meta
            p[kCGImageDestinationLossyCompressionQuality] = q
            CGImageDestinationAddImage(dest, type == .jpeg ? flatten(image) : image, p as CFDictionary)
            return CGImageDestinationFinalize(dest) ? data as Data : nil
        }

        for _ in 0..<8 {
            try Task.checkCancellation()
            var lo = 0.1, hi = 0.95, best: Data?
            for _ in 0..<7 {
                let q = (lo + hi) / 2
                guard let d = encode(img, q) else { break }
                if d.count <= maxBytes { best = d; lo = q } else { hi = q }
            }
            if best == nil, let d = encode(img, 0.1), d.count <= maxBytes { best = d }
            if let best {
                let out = Out.url(for: src, suffix: "-\(label.replacingOccurrences(of: " ", with: ""))", ext: type == .heic ? "heic" : "jpg")
                try best.write(to: out)
                return out
            }
            // Still too big at low quality: scale down by a quarter and try again.
            let w = Int(Double(img.width) * 0.75), h = Int(Double(img.height) * 0.75)
            img = draw(w, h) { $0.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        }
        throw WheelError("Couldn't get \(src.lastPathComponent) under \(label).")
    }

    static func resize(toWidth width: Int) -> (CGImage) -> CGImage {
        { img in
            let h = max(1, Int((Double(img.height) * Double(width) / Double(img.width)).rounded()))
            return draw(width, h) { $0.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h)) }
        }
    }
}

// MARK: - Trim (video and audio)

extension AV {
    /// Copies the chosen stretch without re-encoding when the format allows.
    static func trim(_ src: URL, range: CMTimeRange) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let isVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        let ext = src.pathExtension.lowercased()
        let (type, outExt): (AVFileType, String) = isVideo
            ? (ext == "mov" ? (.mov, "mov") : (.mp4, "mp4"))
            : (.m4a, "m4a")
        var preset = isVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
        if await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: type) {
            preset = AVAssetExportPresetPassthrough
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw WheelError("This file can't be trimmed.")
        }
        session.timeRange = range
        let out = Out.url(for: src, suffix: "-trimmed", ext: outExt)
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
}

/// The Trim window: Start and End sliders, a preview frame for video, Cancel / Trim.
@MainActor @Observable
final class TrimModel {
    let url: URL
    /// How many files share this range (Trim several at once).
    var count = 1
    var duration: Double = 0
    var start: Double = 0
    var end: Double = 0
    var preview: NSImage?
    let isVideo: Bool
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private let generator: AVAssetImageGenerator

    init(url: URL, isVideo: Bool) {
        self.url = url
        self.isVideo = isVideo
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
    }

    /// Shows the frame at `seconds` (the handle being moved), a moment after it stops moving.
    func showFrame(at seconds: Double) {
        guard isVideo else { return }
        previewTask?.cancel()
        nonisolated(unsafe) let gen = generator   // one frame request at a time; the generator is safe to use like this
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled,
                  let (cg, _) = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return }
            preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    static func format(_ s: Double) -> String {
        let t = max(0, s)
        let m = Int(t) / 60, sec = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, sec)
    }
}

@MainActor
enum TrimPanel {
    private static var window: NSWindow?
    private static var finish: ((CMTimeRange?) -> Void)?

    /// Asks for the stretch to keep. Returns nil if the window is cancelled or closed.
    /// With several files, one range applies to all of them; the sliders run up to the shortest one.
    static func ask(for urls: [URL]) async throws -> CMTimeRange? {
        guard let url = urls.first else { return nil }
        var duration = Double.infinity
        for u in urls {
            let d = try await AVURLAsset(url: u).load(.duration).seconds
            guard d.isFinite, d > 0.2 else { throw WheelError("\(u.lastPathComponent) is too short to trim.") }
            duration = min(duration, d)
        }
        let isVideo = !(try await AVURLAsset(url: url).loadTracks(withMediaType: .video)).isEmpty
        let model = TrimModel(url: url, isVideo: isVideo)
        model.count = urls.count
        model.duration = duration
        model.end = duration
        model.showFrame(at: 0)

        return await withCheckedContinuation { cont in
            finish?(nil)   // only one Trim window at a time
            finish = { range in
                finish = nil
                window?.orderOut(nil)
                window = nil
                cont.resume(returning: range)
            }
            let view = TrimView(model: model,
                                onCancel: { finish?(nil) },
                                onTrim: {
                                    let start = CMTime(seconds: model.start, preferredTimescale: 600)
                                    let end = CMTime(seconds: model.end, preferredTimescale: 600)
                                    finish?(CMTimeRange(start: start, end: end))
                                })
            let size = CGSize(width: 480, height: isVideo ? 470 : 250)
            let w = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = urls.count == 1 ? "Trim \(url.lastPathComponent)" : "Trim \(urls.count) files"
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]
            WindowSizing.attach(view, to: w, size: size)
            w.delegate = CloseWatcher.shared
            WindowSizing.place(w)
            window = w
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
    }

    /// Closing the window with the red button counts as Cancel.
    @MainActor final class CloseWatcher: NSObject, NSWindowDelegate {
        static let shared = CloseWatcher()
        func windowWillClose(_ notification: Notification) {
            TrimPanel.finish?(nil)
        }
    }
}

struct TrimView: View {
    let model: TrimModel
    let onCancel: () -> Void
    let onTrim: () -> Void

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text(model.count == 1 ? model.url.lastPathComponent : "\(model.url.lastPathComponent) and \(model.count - 1) more")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1).truncationMode(.middle)
                    if model.count > 1 {
                        Text("The same start and end are used for every file.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Color.inkSecondary)
                    }
                }
                .padding(.top, 26)
                if model.isVideo {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.25))
                        if let preview = model.preview {
                            Image(nsImage: preview).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            Image(systemName: "film").font(.system(size: 34)).foregroundStyle(Color.inkSecondary)
                        }
                    }
                    .frame(height: 200)
                }
                VStack(spacing: 10) {
                    slider("Start", value: Binding(get: { model.start }, set: { v in
                        model.start = min(v, model.end - 0.1); model.showFrame(at: model.start)
                    }))
                    slider("End", value: Binding(get: { model.end }, set: { v in
                        model.end = max(v, model.start + 0.1); model.showFrame(at: model.end)
                    }))
                    Text("Keeps \(TrimModel.format(model.end - model.start)) of \(TrimModel.format(model.duration))")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.inkSecondary)
                }
                .padding(14)
                .echoGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: GlassTint.clear)
                HStack(spacing: 10) {
                    Spacer()
                    button("Cancel", primary: false, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    button("Trim", primary: true, action: onTrim)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .foregroundStyle(Color.ink)
        .tint(Color.pick)
    }

    private func slider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).frame(width: 42, alignment: .leading)
            Slider(value: value, in: 0...max(model.duration, 0.1))
            Text(TrimModel.format(value.wrappedValue))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(primary ? Color.onPick : Color.ink)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background { if primary { Capsule().fill(Color.pick) } }
                .echoGlass(Capsule(), tint: primary ? GlassTint.picked : GlassTint.clear, interactive: true)
        }
        .buttonStyle(.plain)
    }
}
