import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation

extension MediaExportEngine {
    public func convertAudio(input: String, output: String, container: String, sampleRate: Double?, channels: Int?, bitRate: Int?, cancellation: CancellationToken?) async throws -> String {
        let sourceURL = try resolve(input), outputURL = try resolveOutput(output)
        guard sourceURL != outputURL else { throw FloeError.validationFailed("Choose a separate audio output file") }
        let container = container.lowercased()
        guard ["wav", "caf", "aiff", "aif", "m4a"].contains(container) else { throw FloeError.validationFailed("Audio containers: wav, caf, aiff, m4a") }
        let file = try AVAudioFile(forReading: sourceURL)
        let rate = sampleRate ?? file.processingFormat.sampleRate
        let channelCount = channels ?? Int(file.processingFormat.channelCount)
        guard rate.isFinite, (8_000...192_000).contains(rate), (1...2).contains(channelCount) else {
            throw FloeError.validationFailed("Audio conversion supports 8–192 kHz and mono/stereo")
        }
        if let bitRate, container != "m4a" || !(16_000...512_000).contains(bitRate) {
            throw FloeError.validationFailed("bitRate is supported for AAC m4a only, between 16000 and 512000")
        }
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".floe-audio-\(UUID().uuidString).\(container)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channelCount]
        if container == "m4a" {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            if let bitRate { settings[AVEncoderBitRateKey] = bitRate }
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = container == "aiff" || container == "aif"
        }
        do {
            let destination = try AVAudioFile(forWriting: temporary, settings: settings)
            guard let converter = AVAudioConverter(from: file.processingFormat, to: destination.processingFormat),
                  let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: destination.processingFormat, frameCapacity: 8192) else {
                throw FloeError.validationFailed("Audio converter rejected the requested format")
            }
            var inputError: (any Error)?
            var done = false
            while !done {
                try cancellation?.throwIfCancelled(); try Task.checkCancellation()
                var error: NSError?
                let status = converter.convert(to: outputBuffer, error: &error) { requested, state in
                    if file.framePosition >= file.length { state.pointee = .endOfStream; return nil }
                    do {
                        try file.read(into: sourceBuffer, frameCount: min(requested, sourceBuffer.frameCapacity))
                        state.pointee = .haveData
                        return sourceBuffer
                    } catch { inputError = error; state.pointee = .endOfStream; return nil }
                }
                if let inputError { throw inputError }
                if let error { throw error }
                guard status != .error else { throw FloeError.internalError("Audio conversion failed") }
                if outputBuffer.frameLength > 0 { try destination.write(from: outputBuffer) }
                done = status == .endOfStream
                if !done { await Task.yield() }
            }
            // AVAudioFile closes and finalizes the container before independent validation below.
        }
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        let verified = try AVAudioFile(forReading: temporary)
        let seconds = Double(verified.length) / verified.fileFormat.sampleRate
        let expected = Double(file.length) / file.fileFormat.sampleRate
        guard verified.length > 0, verified.fileFormat.sampleRate == rate,
              verified.fileFormat.channelCount == UInt32(channelCount), abs(seconds - expected) < 0.1 else {
            throw FloeError.validationFailed("Converted audio failed duration, rate or channel verification")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: outputURL) }
        return "status=ok output=\(output) sampleRate=\(rate) channels=\(channelCount) duration=\(seconds)"
    }
}
#endif
