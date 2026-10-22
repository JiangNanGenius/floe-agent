// FloeProviders — Apple/system speech as a PCM SOURCE.
//
// SPDX-License-Identifier: MPL-2.0
//
// AVSpeechSynthesizer exposes offline synthesis through
// write(_:toBufferCallback:) (declared in the AVFAudio headers since iOS 13 /
// macOS 10.15; the delegate still reports didFinish/didCancel per utterance).
// This adapter produces ordered s16le mono PCM chunks on the SAME
// TTSAudioChunk contract as the cloud routes, so both the chat player and the
// continuous-voice AEC consumer can play system speech through their OWN
// engine and playback receipts. write() renders offline: it does not route to
// the speaker and does not take audio-session ownership (the PiP ducking hook
// in SpeechService remains the audible path's only session interaction).
//
// The producer here is delegate-driven (synchronous callbacks), so it uses
// the channel's byte-capped sendBounded: lossless up to
// `TTSSpeechLimits.maxSegmentAudioBytes` (≈3 min of 24 kHz mono), and an
// explicit `streamTruncated` close past the cap — never a silent drop.
//
// Rate: speechRateRatio maps onto the AVSpeechUtterance rate around the
// AVFoundation default (0.5) — the only supported knob. This path needs no
// credential and ignores billing route/model/voice requirements (empty voice
// = automatic language selection); local validation keeps text and PCM format.

import Foundation
import FloeCore
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation) && (os(iOS) || os(macOS))

/// Pure float/int PCM conversion helper (testable without a synthesizer).
public enum TTSSpeechPCM {
    /// Converts any AVAudioPCMBuffer to s16le mono at `sampleRate`. Returns
    /// nil only when the input has no frames or conversion fails.
    public static func convert(_ input: AVAudioPCMBuffer, toSampleRate sampleRate: Double) -> Data? {
        guard input.frameLength > 0 else { return nil }
        let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
        let inputFormat = input.format
        if inputFormat == target, let ptr = input.int16ChannelData {
            return Data(bytes: ptr[0], count: Int(input.frameLength) * 2)
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { return nil }
        let ratio = max(1.0, target.sampleRate / max(1.0, inputFormat.sampleRate))
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0,
              let ptr = output.int16ChannelData else { return nil }
        return Data(bytes: ptr[0], count: Int(output.frameLength) * 2)
    }
}

public final class AppleSystemSpeechAdapter: NSObject, @unchecked Sendable, TTSSpeechProviding {
    /// One in-flight offline write. Each write owns its OWN
    /// AVSpeechSynthesizer: a cancel/stop for one session must never touch
    /// another in-flight write (the delegate on a shared synth would queue or
    /// cross-stop utterances).
    private final class ActiveWrite {
        let identifier: ObjectIdentifier
        let request: TTSSynthesisRequest
        let sender: TTSAudioChunkSender
        let synthesizer: AVSpeechSynthesizer
        var sequence = 0
        var ended = false
        /// PCM carried when a producer callback delivered an odd byte count;
        /// merged into the next chunk to keep sample alignment.
        var oddCarry: UInt8?

        init(
            identifier: ObjectIdentifier,
            request: TTSSynthesisRequest,
            sender: TTSAudioChunkSender,
            synthesizer: AVSpeechSynthesizer
        ) {
            self.identifier = identifier
            self.request = request
            self.sender = sender
            self.synthesizer = synthesizer
        }
    }

    /// Synchronous-only state lock (never held across suspension).
    private let stateLock = NSLock()
    private var writes: [ObjectIdentifier: ActiveWrite] = [:]

    public override init() {
        super.init()
    }

    // MARK: - TTSSpeechProviding

    /// The Apple path needs no credential; the parameter is ignored.
    public func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        let (stream, sender) = TTSAudioChunkStream.make(
            slotCapacity: TTSSpeechLimits.channelSlotCapacity,
            byteCapacity: TTSSpeechLimits.maxSegmentAudioBytes)
        // Local-only validation (no cloud route/model/voice requirements),
        // completed BEFORE any AVFoundation object is created so a rejected
        // request never starts a synthesis.
        if request.format.container != .pcm16le {
            sender.finish(throwing: TTSSynthesisError.invalidConfiguration(
                "streaming synthesis requires PCM output"))
            return stream
        }
        if request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sender.finish(throwing: TTSSynthesisError.invalidConfiguration("request text is empty"))
            return stream
        }
        let utterance = AVSpeechUtterance(string: request.text)
        // Relative rate around the AVFoundation default (0.5 = normal).
        utterance.rate = Float(Swift.min(1.0, Swift.max(0.0, 0.5 * request.speechRateRatio)))
        // Voice precedence: explicit voice ID > explicit language >
        // text-script heuristic > en-US fallback.
        if !request.voiceID.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: request.voiceID) {
            utterance.voice = voice
        } else if let language = request.language,
                  let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Self.preferredLanguage(for: request.text))
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        let identifier = ObjectIdentifier(utterance)
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        let write = ActiveWrite(
            identifier: identifier, request: request, sender: sender, synthesizer: synthesizer)

        // Register the write BEFORE attaching the stopper: a consumer cancel
        // that lands in that window cancels the stopper through `attach`, and
        // its onCancel path then finds the registered write and stops it.
        stateLock.lock()
        writes[identifier] = write
        stateLock.unlock()

        // Consumer-cancel stopper: closing the stream cancels this task, which
        // stops the offline write; late buffers then fence against the removed
        // write (documented device-verification item: whether stopSpeaking
        // affects a writing utterance on a given OS version — fenced either
        // way).
        let stopper = Task { [weak self] in
            await withTaskCancellationHandler {
                _ = try? await Task.sleep(nanoseconds: UInt64.max)
            } onCancel: {
                self?.stopWriting(identifier: identifier)
            }
        }
        sender.attach(stopper)

        synthesizer.write(utterance) { [weak self] buffer in
            self?.handle(buffer, for: identifier)
        }
        return stream
    }

    // MARK: - Buffer / delegate plumbing

    private func handle(_ buffer: AVAudioBuffer, for identifier: ObjectIdentifier) {
        stateLock.lock()
        guard let write = writes[identifier], !write.ended else {
            stateLock.unlock()
            return // late buffer after cancel/finish: fenced and dropped
        }
        stateLock.unlock()

        guard let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0,
              let pcm = TTSSpeechPCM.convert(
                  pcmBuffer, toSampleRate: Double(write.request.format.sampleRate))
        else { return }

        // Keep sample alignment across producer callback boundaries.
        var payload = pcm
        if let carry = takeCarry(write) {
            var bytes = [carry]
            bytes.append(contentsOf: payload)
            payload = Data(bytes)
        }
        var pieces = TTSSpeechPCMChunking.split(payload)
        if let last = pieces.last, last.count % 2 == 1 {
            pieces.removeLast()
            var mutableLast = last
            let trailing = mutableLast.removeLast()
            storeCarry(write, trailing)
            if !mutableLast.isEmpty { pieces.append(mutableLast) }
        }
        for piece in pieces {
            stateLock.lock()
            guard let live = writes[identifier], live === write, !live.ended else {
                stateLock.unlock()
                return
            }
            let sequence = live.sequence
            stateLock.unlock()
            let accepted = write.sender.sendBounded(TTSAudioChunk(
                sessionID: write.request.sessionID,
                segmentIndex: write.request.segmentIndex,
                sequence: sequence,
                pcm: piece,
                sampleRate: write.request.format.sampleRate))
            if !accepted {
                // Byte cap exceeded or consumer gone: stop writing and fence.
                stopWriting(identifier: identifier)
                return
            }
            stateLock.lock()
            if writes[identifier] === write, !write.ended { write.sequence += 1 }
            stateLock.unlock()
        }
    }

    private func takeCarry(_ write: ActiveWrite) -> UInt8? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let carry = write.oddCarry
        write.oddCarry = nil
        return carry
    }

    private func storeCarry(_ write: ActiveWrite, _ byte: UInt8) {
        stateLock.lock()
        write.oddCarry = byte
        stateLock.unlock()
    }

    private func stopWriting(identifier: ObjectIdentifier) {
        stateLock.lock()
        let write = writes[identifier]
        stateLock.unlock()
        guard let write, !write.ended else { return }
        // stopSpeaking applies to the current utterance of THIS write's
        // synthesizer; for a write-only utterance this is a no-op on some OS
        // versions — late buffers are fenced regardless (see class header).
        _ = write.synthesizer.stopSpeaking(at: .immediate)
        finish(write: write, asCancelled: true)
    }

    /// The single terminalizer for a write: idempotent (the `ended` flag is
    /// set under the lock and re-checked), flushes an odd carry as its own
    /// padded final pair, then closes the sender — normal EOF with an
    /// `isFinal` chunk, or a cancellation throw. Delegate completion and
    /// consumer cancel both route through here; neither may mark `ended`
    /// BEFORE calling it, or the channel would never close.
    private func finish(write: ActiveWrite, asCancelled: Bool) {
        stateLock.lock()
        guard !write.ended else {
            stateLock.unlock()
            return
        }
        write.ended = true
        writes.removeValue(forKey: write.identifier)
        // Flush an odd carry as its own final-aligned padding pair.
        var tailBytes: [UInt8] = []
        if let carry = write.oddCarry {
            tailBytes.append(carry)
            tailBytes.append(0) // documented padding for the final odd byte
            write.oddCarry = nil
        }
        var sequence = write.sequence
        stateLock.unlock()

        if !tailBytes.isEmpty {
            _ = write.sender.sendBounded(TTSAudioChunk(
                sessionID: write.request.sessionID, segmentIndex: write.request.segmentIndex,
                sequence: sequence, pcm: Data(tailBytes),
                sampleRate: write.request.format.sampleRate))
            sequence += 1
        }
        if asCancelled {
            write.sender.finish(throwing: TTSSynthesisError.cancelled)
        } else {
            _ = write.sender.sendBounded(TTSAudioChunk(
                sessionID: write.request.sessionID, segmentIndex: write.request.segmentIndex,
                sequence: sequence, pcm: Data(),
                sampleRate: write.request.format.sampleRate, isFinal: true))
            write.sender.finish()
        }
    }

    private func completeFromDelegate(identifier: ObjectIdentifier, cancelled: Bool) {
        stateLock.lock()
        let write = writes[identifier]
        stateLock.unlock()
        guard let write else { return }
        // `finish` owns the ended check/removal; do NOT pre-mark, or the
        // isFinal chunk and channel close would be skipped and the consumer
        // would hang without EOF.
        finish(write: write, asCancelled: cancelled)
    }

    /// Same language heuristic as the historical Chat/SpeechService default.
    private static func preferredLanguage(for text: String) -> String {
        let cjk = text.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.count
        let latin = text.unicodeScalars.filter {
            (0x41...0x5A).contains(Int($0.value)) || (0x61...0x7A).contains(Int($0.value))
        }.count
        return cjk >= latin ? "zh-CN" : "en-US"
    }
}

extension AppleSystemSpeechAdapter: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        completeFromDelegate(identifier: ObjectIdentifier(utterance), cancelled: false)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        completeFromDelegate(identifier: ObjectIdentifier(utterance), cancelled: true)
    }
}

#else

/// Non-Apple build platforms (Linux cross-platform CI target): AVFoundation
/// does not exist, but the router type-checks against this fail-closed stub.
/// The iOS/iPadOS app is the only speech runtime; any attempt to synthesize
/// through it surfaces an actionable configuration error instead of silence.
public final class AppleSystemSpeechAdapter: TTSSpeechProviding {
    public init() {}

    public func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        let (stream, sender) = TTSAudioChunkStream.make()
        sender.finish(throwing: TTSSynthesisError.invalidConfiguration(
            "Apple system speech requires an Apple-platform build"))
        return stream
    }
}

#endif
