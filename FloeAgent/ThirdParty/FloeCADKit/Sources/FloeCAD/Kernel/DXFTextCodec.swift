//
//  DXFTextCodec.swift
//  FloeCADKit
//
//  DXF R12 (AC1009) text-tag encoding.
//
//  Drawing files of DXF R2004 (AC1018) and prior are ASCII files whose
//  encoding is set by $DWGCODEPAGE (ANSI_1252 when the variable is absent);
//  characters outside the encoding are written with the `\U+nnnn` schema.
//  Only R2007 (AC1021) and later are UTF-8. The drawing exporter therefore
//  keeps its truthful AC1009 contract and passes every TEXT value through
//  this codec: every scalar outside printable ASCII is escaped, which is a
//  valid superset of the codepage rule and keeps the entity bytes ASCII, so
//  Chinese text and engineering symbols survive in any reader that follows
//  the DXF string encoding. The output is deterministic.
//
//  Literal backslashes are author content, not an escape introducer. A
//  backslash that directly precedes `U+` and four hex digits is itself
//  written as `\U+005C`, so a SINGLE decoding pass restores the exact
//  author text: `\U+0041` stays `\U+0041` and never becomes `A`. Decoding
//  once (never twice) is part of the contract; `decode` scans the wire text
//  left to right and does not re-scan the characters it emits.
//

import Foundation

nonisolated enum DXFTextCodec {
    /// Encodes one string as a DXF R12 tag value.
    ///
    /// - U+0020…U+007E stay literal ASCII.
    /// - Every other scalar becomes `\U+nnnn`; scalars above the BMP use the
    ///   UTF-16 surrogate pair (`\U+D83D\U+DE00`), matching the DXF schema's
    ///   code units.
    /// - A literal backslash directly before a well-formed escape is written
    ///   as `\U+005C` so it survives one decoding pass.
    ///
    /// The caller must already have removed line breaks: a DXF tag value is
    /// one line.
    static func encode(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                if escapeHexValue(scalars, at: index + 1) != nil {
                    appendEscape(0x005C, to: &out)
                } else {
                    out.append(scalar)
                }
                index += 1
                continue
            }
            if (0x20...0x7E).contains(scalar.value) {
                out.append(scalar)
            } else {
                appendEscape(scalar.value, to: &out)
            }
            index += 1
        }
        return String(out)
    }

    /// Decodes exactly one `\U+nnnn` escape pass.
    ///
    /// Text without escapes (an existing legacy file written in the codepage
    /// or as raw bytes) is returned unchanged, so old files keep opening.
    /// An unpaired surrogate escape is not representable as a Swift scalar and
    /// is not produced by `encode`; it is left literal rather than replaced
    /// with a fabricated character.
    static func decode(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\",
                  let escape = escapeHexValue(scalars, at: index + 1) else {
                out.append(scalars[index])
                index += 1
                continue
            }
            let value = escape.value
            if (0xD800...0xDBFF).contains(value),
               escape.next < scalars.count, scalars[escape.next] == "\\",
               let low = escapeHexValue(scalars, at: escape.next + 1),
               (0xDC00...0xDFFF).contains(low.value) {
                let combined = 0x1_0000
                    + ((value - 0xD800) << 10)
                    + (low.value - 0xDC00)
                if let scalar = UnicodeScalar(combined) {
                    out.append(scalar)
                }
                index = low.next
                continue
            }
            if (0xD800...0xDFFF).contains(value) {
                out.append(scalars[index])
                index += 1
                continue
            }
            if let scalar = UnicodeScalar(value) {
                out.append(scalar)
            }
            index = escape.next
        }
        return String(out)
    }

    // MARK: - Escape helpers

    /// Parses `U+xxxx` starting at `start` (the character after a backslash).
    /// Returns the code unit and the index just past the escape.
    private static func escapeHexValue(
        _ scalars: [UnicodeScalar], at start: Int
    ) -> (value: UInt32, next: Int)? {
        guard start + 5 < scalars.count,
              scalars[start] == "U", scalars[start + 1] == "+" else { return nil }
        var value: UInt32 = 0
        for offset in 2..<6 {
            guard let digit = hexDigit(scalars[start + offset]) else { return nil }
            value = (value << 4) | digit
        }
        return (value, start + 6)
    }

    private static func hexDigit(_ scalar: UnicodeScalar) -> UInt32? {
        switch scalar.value {
        case 0x30...0x39: return scalar.value - 0x30
        case 0x41...0x46: return scalar.value - 0x41 + 10
        case 0x61...0x66: return scalar.value - 0x61 + 10
        default: return nil
        }
    }

    private static func appendEscape(_ value: UInt32, to out: inout String.UnicodeScalarView) {
        if value <= 0xFFFF {
            out.append(contentsOf: escapeText(value).unicodeScalars)
            return
        }
        let adjusted = value - 0x1_0000
        let high = 0xD800 + (adjusted >> 10)
        let low = 0xDC00 + (adjusted & 0x3FF)
        out.append(contentsOf: escapeText(high).unicodeScalars)
        out.append(contentsOf: escapeText(low).unicodeScalars)
    }

    /// `\U+` + four upper-case hex digits. Built without locale-sensitive
    /// formatting so the bytes are identical on every run and platform.
    private static func escapeText(_ value: UInt32) -> String {
        let digits = Array("0123456789ABCDEF".unicodeScalars)
        var scalars = String.UnicodeScalarView()
        scalars.append("\\")
        scalars.append("U")
        scalars.append("+")
        for shift in stride(from: 12, through: 0, by: -4) {
            scalars.append(digits[Int((value >> shift) & 0xF)])
        }
        return String(scalars)
    }
}
