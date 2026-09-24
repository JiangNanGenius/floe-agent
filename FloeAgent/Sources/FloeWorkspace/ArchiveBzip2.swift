// FloeWorkspace — bounded native bzip2 (libbz2) streaming.
//
// bzip2 is the one format the system Compression framework does not provide.
// Both the iOS and macOS SDKs do ship libbz2 (`usr/lib/libbz2.tbd`), but not as
// a Swift module; the `CFloeArchive` C target is a narrow shim over its
// streaming API, so no vendored dependency is added and the codec is the same
// one the platform `bzip2` tool uses.
//
// Both directions are push/pull streaming with fixed working memory:
//
//   * decode — `Bzip2DecodingSource` feeds bounded input chunks and receives
//     bounded output chunks. libbz2's own state is bounded by the block size
//     declared in the member header (at most a few MiB), never by the
//     expanded size. `ArchiveDecodeBudget` is consulted *before* a produced
//     chunk is appended and cancellation is polled on the same path, so an
//     expansion bomb fails while memory is still small and a long decode is
//     promptly interruptible.
//   * encode — `Bzip2StreamWriter` compresses into bounded output chunks and
//     hands each one to its sink, so neither the input nor the compressed
//     output is buffered whole.
//
// Concatenated members are decoded in sequence. Each member's exact end comes
// from libbz2's consumed-byte count, never from scanning for a magic; bytes
// after the final member that are not another valid stream are rejected as
// corrupt instead of being ignored.

import Foundation
import CFloeArchive
import FloeCore

/// Streams the decompressed bytes of a bzip2 file — one member or many
/// concatenated members.
final class Bzip2DecodingSource: ArchiveByteSource {
    static let inputChunkSize = 64 * 1024
    static let outputChunkSize = 64 * 1024

    private let file: FileByteSource
    private let budget: ArchiveDecodeBudget
    private var decoder: OpaquePointer?
    /// Bytes read from the file that the active decoder has not consumed yet.
    private var input = Data()
    private var inputOffset = 0
    private var inputEnded = false
    private var output = Data()
    private var outputOffset = 0
    /// Reused output window: one fixed 64 KiB buffer for the lifetime of the
    /// decoder, so a long stream does not churn allocations.
    private var window = [UInt8](repeating: 0, count: outputChunkSize)
    private var finished = false
    private(set) var position: Int64 = 0
    /// Verified members decoded so far (diagnostics; >= 1 on success).
    private(set) var membersDecoded = 0

    init(url: URL, budget: ArchiveDecodeBudget) throws {
        self.file = try FileByteSource(url: url)
        self.budget = budget
    }

    deinit {
        if let decoder { floe_bz2_decoder_destroy(decoder) }
    }

    var totalSize: Int64? { nil }

    func read(max: Int) throws -> Data? {
        while output.count - outputOffset < max && !finished {
            try pump()
        }
        guard outputOffset < output.count else {
            output.removeAll(keepingCapacity: true)
            outputOffset = 0
            return nil
        }
        let end = min(outputOffset + max, output.count)
        let slice = output.subdata(in: outputOffset..<end)
        outputOffset = end
        position += Int64(slice.count)
        if outputOffset == output.count {
            output.removeAll(keepingCapacity: true)
            outputOffset = 0
        }
        return slice
    }

    private func pump() throws {
        try budget.poll()
        guard !finished else { return }

        if decoder == nil {
            guard try ensureInput() else {
                // End of file between members. With no member decoded at all
                // the input is empty/truncated, never an empty archive.
                guard membersDecoded > 0 else {
                    throw ArchiveCodecError.corrupt("bzip2 input is empty")
                }
                finished = true
                return
            }
            guard let created = floe_bz2_decoder_create() else {
                throw ArchiveCodecError.codecUnavailable("bzip2 (libbz2)")
            }
            decoder = created
        }
        guard let decoder else { return }

        var consumed = 0
        var produced = 0
        let available = input.count - inputOffset
        let status: Int32 = input.withUnsafeBytes { raw -> Int32 in
            let source = raw.baseAddress.map {
                $0.advanced(by: inputOffset).assumingMemoryBound(to: UInt8.self)
            }
            return window.withUnsafeMutableBufferPointer { destination -> Int32 in
                floe_bz2_decoder_process(
                    decoder,
                    source, available,
                    destination.baseAddress, destination.count,
                    &consumed, &produced
                )
            }
        }
        inputOffset += consumed
        if produced > 0 {
            // The budget check happens before the append: an expansion bomb
            // never reaches the caller's buffer.
            try budget.reserve(produced)
            output.append(contentsOf: window[0..<produced])
            budget.didProduce(produced)
        }

        switch status {
        case FLOE_BZ2_STREAM_END:
            membersDecoded += 1
            floe_bz2_decoder_destroy(decoder)
            self.decoder = nil
            if inputOffset == input.count {
                input.removeAll(keepingCapacity: true)
                inputOffset = 0
            }
            // A tail (or more file bytes) starts the next member; trailing
            // data that is not a valid stream fails there instead of being
            // silently ignored. Clean EOF right here is the normal end.
            if inputOffset == input.count && inputEnded {
                finished = true
            }
        case FLOE_BZ2_OK:
            if consumed == 0 && produced == 0 {
                // The decoder needs more input; drop the consumed window and
                // read on. EOF here is mid-member truncation.
                if inputOffset == input.count {
                    input.removeAll(keepingCapacity: true)
                    inputOffset = 0
                }
                guard try ensureInput() else {
                    throw ArchiveCodecError.corrupt("bzip2 stream is truncated")
                }
            }
        case FLOE_BZ2_MEMORY:
            throw ArchiveCodecError.limitExceeded(
                "bzip2 decoder could not allocate its bounded working memory"
            )
        case FLOE_BZ2_PARAM:
            throw ArchiveCodecError.corrupt("bzip2 decoder rejected the stream")
        default:
            throw ArchiveCodecError.corrupt("bzip2 stream is invalid or corrupt")
        }
    }

    /// Makes at least one unconsumed input byte available; false at EOF.
    private func ensureInput() throws -> Bool {
        if inputOffset < input.count { return true }
        guard !inputEnded else { return false }
        try budget.poll()
        guard let chunk = try file.read(max: Self.inputChunkSize), !chunk.isEmpty else {
            inputEnded = true
            return false
        }
        input = chunk
        inputOffset = 0
        return true
    }
}

/// Push-streaming bzip2 encoder over libbz2's streaming compressor.
final class Bzip2StreamWriter {
    static let outputChunkSize = 64 * 1024

    private let encoder: OpaquePointer
    private let sink: (Data) throws -> Void
    private var window = [UInt8](repeating: 0, count: outputChunkSize)

    init(sink: @escaping (Data) throws -> Void) throws {
        guard let encoder = floe_bz2_encoder_create(9) else {
            throw ArchiveCodecError.codecUnavailable("bzip2 (libbz2)")
        }
        self.encoder = encoder
        self.sink = sink
    }

    deinit {
        floe_bz2_encoder_destroy(encoder)
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try pump(data, finish: false)
    }

    func finish() throws {
        try pump(Data(), finish: true)
    }

    private func pump(_ data: Data, finish: Bool) throws {
        var offset = 0
        var idle = 0
        while true {
            var consumed = 0
            var produced = 0
            let available = data.count - offset
            let status: Int32 = data.withUnsafeBytes { raw -> Int32 in
                let source = raw.baseAddress.map {
                    $0.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                }
                return window.withUnsafeMutableBufferPointer { destination -> Int32 in
                    floe_bz2_encoder_process(
                        encoder,
                        source, available,
                        destination.baseAddress, destination.count,
                        finish ? 1 : 0,
                        &consumed, &produced
                    )
                }
            }
            offset += consumed
            if produced > 0 {
                try sink(Data(window[0..<produced]))
            }
            switch status {
            case FLOE_BZ2_OK:
                // Streaming mode is done once every input byte is in (and the
                // output buffer was not filled, i.e. nothing is pending).
                if !finish && offset >= data.count && produced < window.count {
                    return
                }
                if consumed == 0 && produced == 0 {
                    idle += 1
                    guard idle <= 2 else {
                        throw ArchiveCodecError.corrupt("bzip2 encoder made no progress")
                    }
                } else {
                    idle = 0
                }
            case FLOE_BZ2_FINISHED:
                return
            case FLOE_BZ2_MEMORY:
                throw ArchiveCodecError.limitExceeded(
                    "bzip2 encoder could not allocate its bounded working memory"
                )
            default:
                throw ArchiveCodecError.corrupt("bzip2 encoder failed")
            }
        }
    }
}
