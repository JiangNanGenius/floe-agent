import AVFoundation
import Foundation
import FloeMusicCore

public struct MusicDJGestureStep: Sendable {
    public var frame: Int64
    public var deck: MusicDJSession.DeckSlot
    public var position: Double?
    public var rate: Double?
    public var crossfader: Double?
    public init(frame: Int64, deck: MusicDJSession.DeckSlot, position: Double? = nil, rate: Double? = nil, crossfader: Double? = nil) {
        self.frame = frame; self.deck = deck; self.position = position; self.rate = rate; self.crossfader = crossfader
    }
}

private final class MusicPCMPageCache {
    let file: AVAudioFile
    private var pages: [Int64: [[Float]]] = [:]
    private var order: [Int64] = []
    init(url: URL) throws { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
    private func value(_ frame: Int64, _ channel: Int) throws -> Float {
        guard frame >= 0, frame < file.length else { return 0 }
        let base = frame / 4096 * 4096
        if pages[base] == nil {
            file.framePosition = base
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw MusicNativeError.invalid("DJ cache buffer") }
            try file.read(into: buffer)
            guard let pcm = buffer.floatChannelData else { throw MusicNativeError.invalid("DJ PCM format") }
            pages[base] = (0..<2).map { Array(UnsafeBufferPointer(start: pcm[$0], count: Int(buffer.frameLength))) }
            order.append(base)
            if order.count > 8 { pages.removeValue(forKey: order.removeFirst()) }
        }
        guard let page = pages[base], Int(frame - base) < page[channel].count else { return 0 }
        return page[channel][Int(frame - base)]
    }
    func stereo(at position: Double) throws -> (Float, Float) {
        guard position.isFinite, position >= 0, position < min(9.0e18, Double(file.length)) else { return (0, 0) }
        let frame = Int64(position.rounded(.down))
        let fraction = Float(position - Double(frame))
        let a = try value(frame, 0), b = try value(frame + 1, 0)
        let c = try value(frame, 1), d = try value(frame + 1, 1)
        return (a + (b - a) * fraction, c + (d - c) * fraction)
    }
}

/// An actual-audio foothold for the deck module: bounded offline source
/// reading, rate/reverse/jog gestures, beat loops and equal-power mixing.
/// Linear interpolation here is NOT professional low-latency scratch or
/// qualified keylock/time-stretch. No UI timer or hardware cue claim.
public actor MusicDJBounce {
    public init() {}
    public func render(session initial: MusicDJSession, sources: [ResolvedMusicSource], document: MusicDocument,
                       lease: MusicRenderLease, frames: Int64, steps: [MusicDJGestureStep] = [], destination: URL) throws -> MusicRenderReceipt {
        try document.validate(); try initial.validate(); try lease.validate(document: document)
        guard frames > 0, destination.isFileURL,
              initial.sampleRate == document.tempoMap.sampleRate,
              !initial.deckA.keyLocked, !initial.deckB.keyLocked else { throw MusicNativeError.unsupported("DJ keylock or output") }
        for index in steps.indices {
            let step = steps[index]
            guard step.frame >= 0, step.frame < frames,
                  index == 0 || step.frame >= steps[index - 1].frame,
                  step.position.map({ $0.isFinite && $0 >= 0 && $0 < 9.0e18 }) ?? true,
                  step.rate.map({ $0.isFinite && (-4...4).contains($0) }) ?? true,
                  step.crossfader.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw MusicNativeError.invalid("DJ gesture") }
        }
        let work = destination.deletingLastPathComponent().appendingPathComponent(".dj-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = musicStagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staged) }
        var readers: [MusicPCMPageCache?] = []
        let decks = [initial.deckA, initial.deckB]
        for deck in decks {
            guard let id = deck.assetID else { readers.append(nil); continue }
            guard let source = sources.first(where: { $0.asset.id == id }),
                  source.asset.contentHash == deck.assetContentHash,
                  source.asset.sourceRevision == deck.assetSourceRevision else { throw MusicNativeError.invalid("DJ source version") }
            let url = work.appendingPathComponent("\(source.asset.contentHash).caf")
            if !FileManager.default.fileExists(atPath: url.path) {
                try MusicAudioPreparation.prepare(source, sampleRate: initial.sampleRate, destination: url)
            }
            let reader = try MusicPCMPageCache(url: url)
            guard abs(Double(reader.file.length) - Double(deck.assetDurationSamples)) <= 1 else {
                throw MusicNativeError.invalid("DJ decoded source duration")
            }
            readers.append(reader)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(initial.sampleRate), channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024), let pcm = buffer.floatChannelData else { throw MusicNativeError.invalid("DJ output format") }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: staged, settings: musicPCMFileSettings(format))
        var positions = decks.map { Double($0.playheadSamples) }, rates = decks.map(\.rate)
        var session = initial
        var frame: Int64 = 0, nextStep = 0
        while frame < frames {
            try Task.checkCancellation(); try lease.validate(document: document)
            let count = Int(min(1024, frames - frame)); buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let clock = frame + Int64(index)
                while nextStep < steps.count, steps[nextStep].frame <= clock {
                    let step = steps[nextStep], slot = step.deck == .a ? 0 : 1
                    if let position = step.position { positions[slot] = position }
                    if let rate = step.rate { rates[slot] = rate }
                    if let value = step.crossfader { try session.setCrossfader(value) }
                    nextStep += 1
                }
                let gains = session.channelGains()
                var left: Float = 0, right: Float = 0
                for slot in 0..<2 where decks[slot].playing {
                    if let loop = decks[slot].activeLoop, let grid = decks[slot].beatGrid {
                        let beatLength = grid.beatLengthSamples(sampleRate: session.sampleRate)
                        let start = Double(grid.firstBeatSample) + Double(loop.startBeat) * beatLength
                        let length = Double(loop.lengthBeats) * beatLength
                        let offset = (positions[slot] - start).truncatingRemainder(dividingBy: length)
                        positions[slot] = start + (offset < 0 ? offset + length : offset)
                    }
                    let sample = try readers[slot]?.stereo(at: positions[slot]) ?? (0, 0)
                    // The core's per-deck master contribution already
                    // includes masterGain; apply it exactly once.
                    let gain = Float(slot == 0 ? gains.deckAMaster : gains.deckBMaster)
                    left += sample.0 * gain; right += sample.1 * gain
                    positions[slot] += rates[slot]
                }
                guard left.isFinite, right.isFinite else { throw MusicNativeError.invalid("DJ output samples") }
                pcm[0][index] = left; pcm[1][index] = right
            }
            try writer?.write(from: buffer); frame += Int64(count)
        }
        writer = nil
        try musicSynchronize(staged)
        let hash = try MusicAudioPreparation.hashFile(staged)
        try lease.commit(staged: staged, destination: destination)
        return MusicRenderReceipt(projectID: document.id.rawValue, revision: document.revision, frames: frames,
                                  sampleRate: session.sampleRate, tailFrames: 0, sha256: hash, file: destination)
    }
}
