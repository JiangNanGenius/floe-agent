// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Bounded data parser, never an evaluator. KiCad strings are UTF-8 and may
/// contain parentheses, escaped quotes and semicolons.
public indirect enum EDASExpression: Equatable, Sendable {
    case atom(String)
    case list([EDASExpression])
    public var atom: String? { if case .atom(let value) = self { value } else { nil } }
    public var items: [Self] { if case .list(let value) = self { value } else { [] } }
    public var tag: String? { items.first?.atom }
    public func child(_ name: String) -> Self? { items.dropFirst().first { $0.tag == name } }
    public func children(_ name: String) -> [Self] { items.dropFirst().filter { $0.tag == name } }
    public func value(_ index: Int = 1) -> String? { items.indices.contains(index) ? items[index].atom : nil }
    public func number(_ index: Int = 1) throws -> Double {
        guard let string = value(index), let value = Double(string), value.isFinite, abs(value) <= 1_000_000 else {
            throw EDAError.invalid("KiCad numeric field in " + (tag ?? "list"))
        }
        return value
    }
    public func point() throws -> EDAPoint { try .init(number(1), number(2)) }

    public static func parse(_ data: Data, cancelled: @Sendable () -> Bool = { false }) throws -> Self {
        guard !data.isEmpty, data.count <= 32 * 1_024 * 1_024, String(data: data, encoding: .utf8) != nil else {
            throw EDAError.invalid("KiCad input must be bounded UTF-8 data")
        }
        guard !cancelled() else { throw EDAError.cancelled }
        return try withoutActuallyEscaping(cancelled) { check in
            var reader = Reader(bytes: Array(data), cancelled: check)
            let value = try reader.node(depth: 0)
            reader.skip()
            guard reader.position == reader.bytes.count else { throw EDAError.invalid("trailing KiCad data") }
            return value
        }
    }
    private struct Reader {
        let bytes: [UInt8]
        let cancelled: @Sendable () -> Bool
        var position = 0
        var count = 0
        mutating func skip() {
            while position < bytes.count {
                if bytes[position] <= 32 { position += 1 }
                else if bytes[position] == 59 {
                    while position < bytes.count && bytes[position] != 10 { position += 1 }
                } else { return }
            }
        }
        mutating func node(depth: Int) throws -> EDASExpression {
            count += 1
            guard count <= 1_000_000, depth <= 96 else { throw EDAError.invalid("KiCad expression budget") }
            if count.isMultiple(of: 256), cancelled() { throw EDAError.cancelled }
            skip()
            guard position < bytes.count else { throw EDAError.invalid("unfinished KiCad expression") }
            if bytes[position] == 40 {
                position += 1
                var children: [EDASExpression] = []
                while true {
                    skip()
                    guard position < bytes.count else { throw EDAError.invalid("unclosed KiCad list") }
                    if bytes[position] == 41 { position += 1; return .list(children) }
                    children.append(try node(depth: depth + 1))
                }
            }
            guard bytes[position] != 41 else { throw EDAError.invalid("unexpected KiCad close") }
            if bytes[position] == 34 {
                position += 1
                var result: [UInt8] = []
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 34 { return .atom(String(decoding: result, as: UTF8.self)) }
                    if byte == 92 {
                        guard position < bytes.count else { throw EDAError.invalid("unfinished KiCad escape") }
                        let escaped = bytes[position]; position += 1
                        switch escaped {
                        case 34, 92: result.append(escaped)
                        case 110: result.append(10)
                        case 114: result.append(13)
                        case 116: result.append(9)
                        default: throw EDAError.unsupported("KiCad string escape")
                        }
                    } else { result.append(byte) }
                    guard result.count <= 1_048_576 else { throw EDAError.invalid("KiCad string budget") }
                }
                throw EDAError.invalid("unclosed KiCad string")
            }
            let start = position
            while position < bytes.count, bytes[position] > 32, ![UInt8(40), 41, 59].contains(bytes[position]) { position += 1 }
            guard position > start, position - start <= 1_048_576 else { throw EDAError.invalid("KiCad token budget") }
            return .atom(String(decoding: bytes[start..<position], as: UTF8.self))
        }
    }
}
