import AVFoundation
import CLame
import Foundation
import FloeMusicCore

/// Service-owned streaming encoder. No host CLI, network or DSP-callback I/O.
public actor MusicMP3Exporter {
    public init() {}

    public func encode(wav: URL, destination: URL, document: MusicDocument,
                       lease: MusicRenderLease, bitrate: Int = 192,
                       onProgress: @Sendable (Int64) -> Void = { _ in }) throws -> URL {
        try document.validate()
        try lease.validate(document: document)
        guard wav.isFileURL, destination.isFileURL,
              [128, 192, 256, 320].contains(bitrate) else { throw MusicNativeError.unsupported("MP3 bitrate or file URL") }
        let input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = input.processingFormat.channelCount
        guard (1...2).contains(channels), input.length > 0,
              input.processingFormat.sampleRate.isFinite, (8_000...192_000).contains(input.processingFormat.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096),
              let encoder = lame_init() else { throw MusicNativeError.invalid("MP3 input or encoder") }
        defer { _ = lame_close(encoder) }
        guard lame_set_num_channels(encoder, Int32(channels)) == 0,
              lame_set_in_samplerate(encoder, Int32(input.processingFormat.sampleRate)) == 0,
              lame_set_brate(encoder, Int32(bitrate)) == 0,
              lame_set_quality(encoder, 2) == 0,
              lame_set_bWriteVbrTag(encoder, 1) == 0,
              lame_init_params(encoder) == 0 else { throw MusicNativeError.encoder(-1) }
        let staged = musicStagingURL(for: destination)
        guard FileManager.default.createFile(atPath: staged.path, contents: nil) else { throw MusicNativeError.invalid("MP3 staging file") }
        defer { try? FileManager.default.removeItem(at: staged) }
        let output = try FileHandle(forWritingTo: staged)
        defer { try? output.close() }
        var encoded = [UInt8](repeating: 0, count: 16_384)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try lease.validate(document: document)
            try input.read(into: buffer, frameCount: 4096)
            guard buffer.frameLength > 0, let pcm = buffer.floatChannelData else { throw MusicNativeError.render("empty PCM read") }
            let right = channels == 2 ? pcm[1] : pcm[0]
            let count = encoded.withUnsafeMutableBufferPointer {
                lame_encode_buffer_ieee_float(encoder, pcm[0], right, Int32(buffer.frameLength), $0.baseAddress, Int32($0.count))
            }
            guard count >= 0 else { throw MusicNativeError.encoder(count) }
            if count > 0 { try output.write(contentsOf: Data(encoded.prefix(Int(count)))) }
            onProgress(input.framePosition)
        }
        let flushed = encoded.withUnsafeMutableBufferPointer { lame_encode_flush(encoder, $0.baseAddress, Int32($0.count)) }
        guard flushed >= 0 else { throw MusicNativeError.encoder(flushed) }
        if flushed > 0 { try output.write(contentsOf: Data(encoded.prefix(Int(flushed)))) }
        // Replace the reserved Info/Xing frame so independent decoders can use
        // the actual encoder delay/padding rather than adding it to the song.
        let tagSize = encoded.withUnsafeMutableBufferPointer { lame_get_lametag_frame(encoder, $0.baseAddress, $0.count) }
        if tagSize > 0 {
            guard tagSize <= encoded.count else { throw MusicNativeError.invalid("MP3 tag frame size") }
            try output.seek(toOffset: 0)
            try output.write(contentsOf: Data(encoded.prefix(tagSize)))
        }
        try output.synchronize()
        try output.close()
        try lease.commit(staged: staged, destination: destination)
        return destination
    }
}
