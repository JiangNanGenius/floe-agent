// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import FloeHeavyEditorSupport

/// The App may supply its existing music service without transferring its DAW,
/// audio session, sound fonts or ownership to the score editor. Arguments contain
/// compiled score events, never a path or an owner chosen by model content.
public struct ScorePlaybackAdapter: Sendable {
    private let transport: @Sendable (EditorJSON) async throws -> EditorJSON
    private let stop: (@Sendable () async -> Void)?
    public init(transport: @escaping @Sendable (EditorJSON) async throws -> EditorJSON,
                stop: (@Sendable () async -> Void)? = nil) {
        self.transport = transport; self.stop = stop
    }
    public var nativeExtension: HeavyEditorNativeExtension {
        HeavyEditorNativeExtension(operations: ["score.transport"], cancel: { _ in await stop?() }, presentationClosed: { await stop?() }) { operation, arguments in
            guard operation == "score.transport" else { throw HeavyEditorError.invalidCommand }
            return try await transport(arguments)
        }
    }
}

/// A real, offline reference synthesizer for the independent qualification host.
/// These are deliberately labeled reference timbres, not a General MIDI soundfont.
public actor ScorePlaybackService {
    private var player: AVAudioPlayer?
    private var audioData: Data?
    private var renderTask: Task<Data, any Error>?
    public init() {}
    public nonisolated var adapter: ScorePlaybackAdapter {
        ScorePlaybackAdapter(transport: { [self] arguments in try await run(arguments) },
                             stop: { [self] in await stop() })
    }
    public nonisolated var nativeExtension: HeavyEditorNativeExtension { adapter.nativeExtension }

    public func run(_ arguments: EditorJSON) async throws -> EditorJSON {
        let action = arguments["action"].string ?? "status"
        switch action {
        case "start":
            if arguments["performance"] != .null {
                renderTask?.cancel()
                let performance = arguments["performance"]
                let task = Task.detached(priority: .userInitiated) {
                    try ScoreReferenceAudio.renderWAV(performance)
                }
                renderTask = task
                let data = try await task.value
                try Task.checkCancellation()
                player?.stop()
                audioData = data
                player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                player?.prepareToPlay()
            }
            guard let player else { throw HeavyEditorError.engine(EditorText.t("请先打开并编译乐谱。", "Open and compile a score first.")) }
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if let position = arguments["position"].number {
                guard position.isFinite, position >= 0 else { throw HeavyEditorError.invalidDocument }
                player.currentTime = min(player.duration, position)
            }
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.numberOfLoops = arguments["loop"] == .bool(true) ? -1 : 0
            guard player.play() else { throw HeavyEditorError.engine(EditorText.t("音频输出尚未准备好。", "Audio output is not ready.")) }
        case "pause": player?.pause()
        case "stop": renderTask?.cancel(); player?.stop(); player?.currentTime = 0
        case "seek":
            guard let position = arguments["position"].number, position.isFinite, position >= 0 else { throw HeavyEditorError.invalidDocument }
            if let player { player.currentTime = min(player.duration, position) }
        case "status": break
        default: throw HeavyEditorError.invalidCommand
        }
        return .object([
            "playing": .bool(player?.isPlaying ?? false),
            "position": .number(player?.currentTime ?? 0),
            "duration": .number(player?.duration ?? 0),
            "referenceTimbres": .bool(true)
        ])
    }
    public func stop() { renderTask?.cancel(); player?.stop(); player?.currentTime = 0 }
}

/// PCM16 mono RIFF/WAVE synthesis. The normal App can bypass this renderer with
/// ScorePlaybackAdapter and use its own music engine. Reference limits are explicit.
public enum ScoreReferenceAudio {
    public static let sampleRate = 22_050
    public static func renderWAV(_ performance: EditorJSON) throws -> Data {
        guard performance["format"].string == "floe.score.performance/1",
              let duration = performance["duration"].number, duration.isFinite,
              duration > 0, duration <= 900,
              performance["events"].array.count <= 50_000 else {
            throw HeavyEditorError.engine(EditorText.t("参考播放支持最长15分钟、最多50000个事件；较长乐谱请导出MIDI，或使用宿主音乐服务。", "Reference playback supports up to 15 minutes and 50,000 events. Export MIDI or use the host music service for longer scores."))
        }
        let count = Int(ceil(duration * Double(sampleRate)))
        var mix = [Float](repeating: 0, count: count)
        for (index, event) in performance["events"].array.enumerated() {
            if index % 32 == 0 { try Task.checkCancellation() }
            guard let start = event["start"].number, let length = event["duration"].number,
                  let pitch = event["pitch"].number, let velocity = event["velocity"].number,
                  start.isFinite, length.isFinite, pitch.isFinite, velocity.isFinite,
                  start >= 0, start <= duration, length > 0, length <= 900,
                  pitch >= 0, pitch <= 127, velocity >= 0, velocity <= 127 else { throw HeavyEditorError.invalidDocument }
            let volume = event["volume"].number ?? 1
            guard volume.isFinite, volume >= 0, volume <= 1 else { throw HeavyEditorError.invalidDocument }
            if volume == 0 || velocity == 0 { continue }
            let first = Int(start * Double(sampleRate))
            let samples = min(Int(length * Double(sampleRate)), count - first)
            guard samples > 0 else { continue }
            let frequency = 440 * pow(2, (pitch - 69) / 12)
            let gain = Float(volume * velocity / 127 * 0.18)
            let programValue = event["program"].number ?? 0
            guard programValue.isFinite, programValue >= 0, programValue <= 127 else { throw HeavyEditorError.invalidDocument }
            let program = Int(programValue)
            let percussion = event["percussion"] == .bool(true)
            var random: UInt32 = UInt32(index &+ 1) &* 2_654_435_761
            for sample in 0..<samples {
                if sample % 8192 == 0 { try Task.checkCancellation() }
                let time = Double(sample) / Double(sampleRate)
                let phase = 2 * Double.pi * frequency * time
                let attack = min(1, time / 0.006)
                let release = min(1, Double(samples - sample) / (Double(sampleRate) * 0.035))
                let signal: Double
                if percussion {
                    random ^= random << 13; random ^= random >> 17; random ^= random << 5
                    let noise = Double(random) / Double(UInt32.max) * 2 - 1
                    if pitch < 38 { signal = sin(2 * .pi * (48 * time + 16 * (1 - exp(-time * 30)) / 30)) * exp(-time * 11) }
                    else if pitch == 38 || pitch == 40 { signal = (noise * 0.75 + sin(2 * .pi * 185 * time) * 0.25) * exp(-time * 18) }
                    else { signal = (noise * 0.65 + sin(phase * 1.41) * 0.35) * exp(-time * 36) }
                } else if (40..<56).contains(program) {
                    signal = (sin(phase) + sin(phase * 2) * 0.32 + sin(phase * 3) * 0.15) * 0.7
                } else if (56..<80).contains(program) {
                    signal = (sin(phase) + sin(phase * 2) * 0.25) * 0.75
                } else {
                    signal = (sin(phase) + sin(phase * 2) * 0.25 * exp(-time * 6) + sin(phase * 3) * 0.08 * exp(-time * 12)) * exp(-time * 0.7)
                }
                mix[first + sample] += Float(signal * attack * release) * gain
            }
        }
        let peak = mix.reduce(Float(0)) { max($0, abs($1)) }
        let normalization = peak > 0.96 ? 0.96 / peak : 1
        let dataSize = count * 2
        var output = Data()
        output.reserveCapacity(44 + dataSize)
        func ascii(_ s: String) { output.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { output.append(UInt8(n & 255)); output.append(UInt8(n >> 8)) }
        func u32(_ n: UInt32) { u16(UInt16(n & 65535)); u16(UInt16(n >> 16)) }
        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(dataSize))
        for sample in mix {
            let bounded = max(-1, min(1, sample * normalization))
            u16(UInt16(bitPattern: Int16((bounded * 32767).rounded())))
        }
        return output
    }
}
