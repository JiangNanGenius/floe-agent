// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Standard raw-DEFLATE encoder (RFC 1951) for draw.io compressed page
/// payloads. Pure Swift, deterministic, allocation-bounded: the LZ77 window
/// is capped at 32 KiB and the match chain is capped, so encoding cost stays
/// proportional to input size with no unbounded auxiliary state.
///
/// Why this exists: DiagramKit's public draw.io geometry export emits
/// uncompressed `<mxGraphModel>` pages and its compressed encoder is
/// internal. FloeCanvasExchange must not edit DiagramKit or copy its codec,
/// so the standard diagrams.net page transform (URI-encode -> raw-deflate ->
/// base64) is applied here to the exported XML only. Interop is validated by
/// re-importing through DiagramKit's own C inflate path and, in tests, by
/// inflating the payload with the system zlib.
enum CanvasRawDeflate {
    /// Bit writer following RFC 1951 / the zlib reference exactly: the
    /// stream fills each byte from the LEAST significant bit upward;
    /// Huffman codes contribute their bits MSB-first, all other elements
    /// (block header, extra bits) contribute LSB-first.
    private struct BitWriter {
        private var bytes: [UInt8] = []
        private var accumulator: UInt8 = 0
        private var bitCount = 0

        /// Appends one bit at the next stream position.
        private mutating func writeBit(_ bit: UInt8) {
            accumulator |= (bit & 1) << UInt8(bitCount)
            bitCount += 1
            if bitCount == 8 {
                bytes.append(accumulator)
                accumulator = 0
                bitCount = 0
            }
        }

        mutating func writeHuffman(_ code: UInt16, count: Int) {
            for shift in (0..<count).reversed() {
                writeBit(UInt8((code >> UInt16(shift)) & 1))
            }
        }

        mutating func writeBits(_ value: UInt32, count: Int) {
            for shift in 0..<count {
                writeBit(UInt8((value >> UInt32(shift)) & 1))
            }
        }

        mutating func finish() -> Data {
            if bitCount > 0 {
                bytes.append(accumulator)
                accumulator = 0
                bitCount = 0
            }
            return Data(bytes)
        }
    }

    // Fixed-Huffman literal/length code for `literal` (0...287).
    private static func fixedCode(_ literal: UInt16) -> (code: UInt16, bits: Int) {
        switch literal {
        case 0...143: return (UInt16(0x30 + literal), 8)
        case 144...255: return (UInt16(0x190 + (literal - 144)), 9)
        case 256...279: return (UInt16(literal - 256), 7)
        default: return (UInt16(0xC0 + (literal - 280)), 8)
        }
    }

    // Length codes 257...285: (base length, extra bits).
    private static let lengthBases: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtras: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]

    private static func lengthSymbol(_ length: Int) -> (code: UInt16, extraBits: Int, extraValue: UInt32) {
        var index = lengthBases.count - 1
        while index > 0, lengthBases[index] > length { index -= 1 }
        return (UInt16(257 + index), lengthExtras[index], UInt32(length - lengthBases[index]))
    }

    // Distance codes 0...29: (base distance, extra bits).
    private static let distanceBases: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577,
    ]
    private static let distanceExtras: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    private static func distanceSymbol(_ distance: Int) -> (code: UInt16, extraBits: Int, extraValue: UInt32) {
        var index = distanceBases.count - 1
        while index > 0, distanceBases[index] > distance { index -= 1 }
        return (UInt16(index), distanceExtras[index], UInt32(distance - distanceBases[index]))
    }

    private static func hash(_ bytes: [UInt8], _ position: Int) -> Int {
        (Int(bytes[position]) << 10 ^ (Int(bytes[position + 1]) << 5) ^ Int(bytes[position + 2])) & 0xFFFF
    }

    /// Encodes `data` as a single fixed-Huffman DEFLATE block stream (raw
    /// deflate, no zlib wrapper/trailer — the diagrams.net page format).
    static func encode(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let count = bytes.count
        var writer = BitWriter()
        writer.writeBits(1, count: 1) // BFINAL
        writer.writeBits(1, count: 2) // BTYPE = fixed Huffman (LSB-first field)

        // LZ77 hash chains over a 32 KiB window (ring buffers, bounded).
        var head = [Int](repeating: -1, count: 1 << 16)
        var previous = [Int](repeating: -1, count: 1 << 15)
        let windowMask = (1 << 15) - 1
        let maxChain = 128

        func insert(_ position: Int) {
            guard position + 3 <= count else { return }
            let slot = hash(bytes, position)
            previous[position & windowMask] = head[slot]
            head[slot] = position
        }

        var position = 0
        while position < count {
            var bestLength = 0
            var bestDistance = 0
            if position + 3 <= count {
                let slot = hash(bytes, position)
                var candidate = head[slot]
                var chain = 0
                let limit = min(258, count - position)
                while candidate >= 0, candidate < position, position - candidate <= 32768, chain < maxChain {
                    if bytes[candidate + bestLength] == bytes[position + bestLength] {
                        var length = 0
                        while length < limit, bytes[candidate + length] == bytes[position + length] {
                            length += 1
                        }
                        if length > bestLength {
                            bestLength = length
                            bestDistance = position - candidate
                            if length >= limit { break }
                        }
                    }
                    let next = previous[candidate & windowMask]
                    guard next > candidate, next < position else { break }
                    candidate = next
                    chain += 1
                }
            }

            if bestLength >= 3 {
                let length = lengthSymbol(bestLength)
                let fixed = fixedCode(length.code)
                writer.writeHuffman(fixed.code, count: fixed.bits)
                writer.writeBits(length.extraValue, count: length.extraBits)
                let distance = distanceSymbol(bestDistance)
                writer.writeHuffman(distance.code, count: 5)
                writer.writeBits(distance.extraValue, count: distance.extraBits)
                for offset in 0..<bestLength { insert(position + offset) }
                position += bestLength
            } else {
                let fixed = fixedCode(UInt16(bytes[position]))
                writer.writeHuffman(fixed.code, count: fixed.bits)
                insert(position)
                position += 1
            }
            if position & 0xFFF == 0 { try Task.checkCancellation() }
        }

        let endOfBlock = fixedCode(256)
        writer.writeHuffman(endOfBlock.code, count: endOfBlock.bits)
        return writer.finish()
    }
}

/// Applies the standard diagrams.net compressed-page transform to the
/// UNCOMPRESSED mxfile XML produced by DiagramKit's public draw.io export:
/// every inline `<mxGraphModel>…` page body becomes
/// `base64(rawDeflate(percentEncode(model)))`. Pages that already carry an
/// encoded body (a foreign file re-exported verbatim) are left untouched.
enum CanvasDrawIOPageCompression {
    private static let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))

    static func compressPages(ofMXFile xml: String) throws -> String {
        var result = ""
        var cursor = xml.startIndex
        while let tagStart = xml.range(of: "<diagram", range: cursor..<xml.endIndex) {
            guard let tagEnd = xml.range(of: ">", range: tagStart.lowerBound..<xml.endIndex) else {
                throw CanvasExchangeError.io("draw.io: unterminated <diagram> open tag")
            }
            // Self-closing <diagram/>: nothing to compress.
            let slashIndex = xml.index(before: tagEnd.lowerBound)
            result.append(contentsOf: xml[cursor..<tagEnd.upperBound])
            if xml[slashIndex] == "/" {
                cursor = tagEnd.upperBound
                continue
            }
            guard let closeStart = xml.range(of: "</diagram>", range: tagEnd.upperBound..<xml.endIndex) else {
                throw CanvasExchangeError.io("draw.io: unterminated <diagram> page")
            }
            let body = String(xml[tagEnd.upperBound..<closeStart.lowerBound])
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<") {
                result += try compressModel(trimmed)
            } else {
                result += body
            }
            // Leave the cursor at the closing tag so it is copied verbatim
            // by the next slice (or the final append for the last page).
            cursor = closeStart.lowerBound
        }
        result.append(contentsOf: xml[cursor..<xml.endIndex])
        return result
    }

    static func compressModel(_ model: String) throws -> String {
        guard let percentEncoded = model.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw CanvasExchangeError.io("draw.io: URI encoding failed")
        }
        let deflated = try CanvasRawDeflate.encode(Data(percentEncoded.utf8))
        return deflated.base64EncodedString()
    }
}
