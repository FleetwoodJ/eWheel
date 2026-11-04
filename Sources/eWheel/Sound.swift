import AVFoundation

/// The soft "tick" played as the pointer moves onto a new wheel segment.
/// Synthesised once (a short 1.8 kHz ping with a little noise for texture)
/// and played through AVAudioEngine, so it starts with no noticeable delay.
@MainActor
final class Clicker {
    static let shared = Clicker()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    private init() {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 0.03)) else { return }
        buf.frameLength = buf.frameCapacity
        let data = buf.floatChannelData![0]
        var seed: UInt32 = 12345
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            let attack = min(1, t / 0.0006)
            let env = attack * exp(-t * 260)
            let tone = sin(2 * .pi * 1800 * t) * 0.65 + sin(2 * .pi * 3600 * t) * 0.12
            data[i] = Float((tone + noise * 0.25) * env * 0.32)
        }
        buffer = buf
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    /// Call when the wheel opens, so the first tick is instant.
    func warmUp() {
        guard Prefs.hoverSound, !engine.isRunning else { return }
        try? engine.start()
        player.play()
    }

    /// Call when the wheel closes, to release the audio device.
    func rest() {
        guard engine.isRunning else { return }
        player.stop()
        engine.pause()
    }

    func click() {
        guard Prefs.hoverSound, let buffer else { return }
        if !engine.isRunning { warmUp() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }
}
