import AppKit
import AVFoundation
import PDFKit

/// `eWheel --selftest [dir]` makes sample files and runs every ⇧ and ⌘
/// segment on them, printing PASS/FAIL. Used by `Scripts/build.sh test`.
@MainActor
enum SelfTest {
    static func start(dir: String?) {
        _ = NSApplication.shared
        Task { @MainActor in
            let failures = await run(dir: dir)
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }

    /// `--selftest bench`: old (one at a time, full decode) vs new (parallel, fast path)
    /// on 12 photo-sized HEICs → JPG.
    static func bench() async -> Int {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("echoro-bench-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = Img.draw(4032, 3024) { c in
            for i in 0..<60 {
                c.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
                c.fillEllipse(in: CGRect(x: i * 61 % 3800, y: i * 47 % 2800, width: 400, height: 300))
            }
        }
        let flat = Img.flatten(photo)
        var files: [URL] = []
        for i in 0..<12 {
            let u = root.appendingPathComponent("IMG_\(i).heic")
            try! Img.write(flat, to: u, type: .heic, quality: 0.9, meta: nil)
            files.append(u)
        }
        var t = Date()
        for f in files {
            let (img, meta) = try! Img.load(f)
            try! Img.write(img, to: root.appendingPathComponent("old-\(f.lastPathComponent).jpg"), type: .jpeg, quality: 0.92, meta: meta)
        }
        let old = Date().timeIntervalSince(t)
        t = Date()
        _ = try! await each(files) { u in try await bg { try Img.convert(u, to: .jpeg, ext: "jpg") } }
        let new = Date().timeIntervalSince(t)
        print(String(format: "12 × 4032×3024 HEIC → JPG\n  before: %.2fs\n  now:    %.2fs  (%.1f× faster)", old, new, old / new))
        return 0
    }

    static func run(dir: String?) async -> Int {
        if dir == "bench" { return await bench() }
        let root = URL(fileURLWithPath: dir ?? NSTemporaryDirectory()).appendingPathComponent("ewheel-selftest-\(Int(Date().timeIntervalSince1970))")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Samples in \(root.path)")
        var samples: [URL] = []
        do { samples = try await makeSamples(in: root) } catch { print("FAIL making samples: \(error)"); return 1 }

        var pass = 0, fail = 0
        for sample in samples {
            for mode in [WheelMode.convert, .tools] {
                for item in Catalog.items(mode: mode, kind: FileKind.of([sample]), urls: [sample]) {
                    if item.interactive {
                        print("SKIP  \(sample.lastPathComponent.padding(toLength: 16, withPad: " ", startingAt: 0)) \(mode.key) \(item.title.padding(toLength: 10, withPad: " ", startingAt: 0)) opens a window (tested directly below)")
                        continue
                    }
                    do {
                        let msg = try await item.run([sample])
                        pass += 1
                        print("PASS  \(sample.lastPathComponent.padding(toLength: 16, withPad: " ", startingAt: 0)) \(mode.key) \(item.title.padding(toLength: 10, withPad: " ", startingAt: 0)) \(msg)")
                    } catch where error.localizedDescription.contains("is already under") {
                        print("SKIP  \(sample.lastPathComponent.padding(toLength: 16, withPad: " ", startingAt: 0)) \(mode.key) \(item.title.padding(toLength: 10, withPad: " ", startingAt: 0)) sample is already small (tested directly below)")
                    } catch where error.localizedDescription.contains("has no audio track") {
                        print("SKIP  \(sample.lastPathComponent.padding(toLength: 16, withPad: " ", startingAt: 0)) \(mode.key) \(item.title.padding(toLength: 10, withPad: " ", startingAt: 0)) sample video is silent (error shown correctly)")
                    } catch {
                        fail += 1
                        print("FAIL \(sample.lastPathComponent.padding(toLength: 16, withPad: " ", startingAt: 0)) \(mode.key) \(item.title.padding(toLength: 10, withPad: " ", startingAt: 0)) \(error.localizedDescription)")
                    }
                }
            }
        }
        // Features added in 1.3.0, checked directly
        let features: [(String, () async throws -> String)] = [
            ("compress to size", {
                let big = root.appendingPathComponent("big.png")
                // Random noise: like a detailed photo, it can't be squeezed under 1 MB without real work
                let noise = Img.draw(2400, 1600) { c in
                    guard let p = c.data?.assumingMemoryBound(to: UInt8.self) else { return }
                    let n = c.bytesPerRow * c.height
                    arc4random_buf(p, n)
                    for i in stride(from: 3, to: n, by: 4) { p[i] = 255 }
                }
                try Img.write(noise, to: big, type: .png, meta: nil)
                let out = try Img.compressToSize(big, maxBytes: 1_000_000, label: "1 MB")
                let size = (try out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                guard size <= 1_000_000 else { throw WheelError("\(size) bytes is over 1 MB") }
                return "\(out.lastPathComponent) is \(size / 1000) KB"
            }),
            ("resize width", {
                let png = samples.first { $0.pathExtension == "png" }!
                let out = try Img.transform(png, suffix: "-w320", Img.resize(toWidth: 320))
                let (img, _) = try Img.load(out)
                guard img.width == 320, img.height == 200 else { throw WheelError("got \(img.width)×\(img.height)") }
                return "\(out.lastPathComponent) is 320×200"
            }),
            ("trim", {
                let mov = samples.first { $0.pathExtension == "mov" }!
                let out = try await AV.trim(mov, range: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                                    end: CMTime(seconds: 1.5, preferredTimescale: 600)))
                let d = try await AVURLAsset(url: out).load(.duration).seconds
                guard abs(d - 1.0) < 0.3 else { throw WheelError("duration \(d)s, expected about 1s") }
                return "\(out.lastPathComponent) is \(String(format: "%.1f", d))s"
            }),
            ("mixed: combine PDF", {
                let png = samples.first { $0.pathExtension == "png" }!, pdf = samples.first { $0.pathExtension == "pdf" }!
                guard Mixed.canCombine([png, pdf]) else { throw WheelError("not offered") }
                let out = try await Mixed.combinePDF([png, pdf])
                let pages = PDFDocument(url: out)?.pageCount ?? 0
                guard pages == 3 else { throw WheelError("\(pages) pages, expected 3") }
                return "\(out.lastPathComponent) has 3 pages"
            }),
            ("mixed: compress", {
                let png = samples.first { $0.pathExtension == "png" }!, csv = samples.first { $0.pathExtension == "csv" }!
                return try await Mixed.compress([png, csv])
            }),
            ("undo", {
                let png = samples.first { $0.pathExtension == "png" }!
                let out = try Img.transform(png, suffix: "-undo", Img.flip)
                let realRecycle = History.shared.recycle
                History.shared.recycle = { urls in for u in urls { try FileManager.default.removeItem(at: u) } }
                defer { History.shared.recycle = realRecycle }
                History.shared.add("Flip horizontally", outputs: [out])
                _ = try await History.shared.undoLast()
                guard !FileManager.default.fileExists(atPath: out.path) else { throw WheelError("file still there") }
                return "\(out.lastPathComponent) removed by Undo"
            }),
            ("cancel stops a tool", {
                let t0 = Date()
                let task = Task { try await Shell.run("/bin/sleep", ["30"]) }
                try await Task.sleep(nanoseconds: 300_000_000)
                task.cancel()
                do { try await task.value; throw WheelError("finished instead of cancelling") } catch is CancellationError {}
                let s = Date().timeIntervalSince(t0)
                guard s < 3 else { throw WheelError("took \(s)s to stop") }
                return String(format: "stopped after %.1fs", s)
            }),
        ]
        for (name, check) in features {
            do {
                let msg = try await check()
                pass += 1
                print("PASS  \(name.padding(toLength: 27, withPad: " ", startingAt: 0)) \(msg)")
            } catch {
                fail += 1
                print("FAIL  \(name.padding(toLength: 27, withPad: " ", startingAt: 0)) \(error.localizedDescription)")
            }
        }
        print("\n\(pass) passed, \(fail) failed")
        return fail
    }

    static func makeSamples(in dir: URL) async throws -> [URL] {
        // Image
        let img = Img.draw(640, 400) { c in
            c.setFillColor(CGColor(red: 0x12 / 255, green: 0x35 / 255, blue: 0x24 / 255, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            c.setFillColor(CGColor(red: 0xC5 / 255, green: 0xEC / 255, blue: 0xD2 / 255, alpha: 1))
            c.fillEllipse(in: CGRect(x: 220, y: 100, width: 200, height: 200))
        }
        let png = dir.appendingPathComponent("sample.png")
        try Img.write(img, to: png, type: .png, meta: nil)

        // Audio: 2 s sine wave WAV
        let wav = dir.appendingPathComponent("sample.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: wav, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
        buf.frameLength = 88200
        for ch in 0..<2 { for i in 0..<88200 { buf.floatChannelData![ch][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.3) } }
        try file.write(from: buf)

        // Video: 2 s, 320x240, 15 fps
        let mov = dir.appendingPathComponent("sample.mov")
        try await makeVideo(mov)

        // PDF (2 pages)
        let pdf = dir.appendingPathComponent("sample.pdf")
        try Img.writePDF([img, Img.rotate(img)], to: pdf)

        // Documents
        let md = dir.appendingPathComponent("notes.md")
        try "# eWheel\n\nA **free**, _open-source_ conversion wheel.\n\n- Local\n- Private\n".write(to: md, atomically: true, encoding: .utf8)
        let rtf = dir.appendingPathComponent("letter.rtf")
        let a = NSAttributedString(string: "Hello from eWheel.\nSecond line.", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)

        // Data & subtitles
        let csv = dir.appendingPathComponent("table.csv")
        try "name,colour,hex\nEchoro,\"Green, deep\",#123524\nMint,Container,#C5ECD2\n".write(to: csv, atomically: true, encoding: .utf8)
        let srt = dir.appendingPathComponent("captions.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n".write(to: srt, atomically: true, encoding: .utf8)

        // Archive
        let zip = try await Arch.zip([csv, srt])

        return [png, wav, mov, pdf, md, rtf, csv, srt, zip]
    }

    static func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for f in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 320, height: 240, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(red: 0x12 / 255, green: 0x35 / 255, blue: 0x24 / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            ctx.setFillColor(CGColor(red: 0xC5 / 255, green: 0xEC / 255, blue: 0xD2 / 255, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 20 + f * 8, y: 80, width: 80, height: 80))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 15))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? WheelError("Video writer failed") }
    }
}
