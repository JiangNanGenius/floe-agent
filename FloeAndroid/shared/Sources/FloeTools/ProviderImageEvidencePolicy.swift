import Foundation

// FloeTools — Shared image-evidence policy for tool artifacts that reach a
// provider as visual input.
//
// One authority defines WHICH image types the provider wire actually carries,
// how bytes are sniffed, and the bounded decode size. MCP tool results and the
// agent runtime use the SAME policy, so a supported image is never dropped by
// one layer after another accepted it — and an unsupported one is rejected
// with an explicit diagnostic instead of silently disappearing.

public enum ProviderImageEvidencePolicy {
    /// MIME types the provider request builders serialize as image parts.
    public static let supportedMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/webp", "image/gif"
    ]

    /// Per-image decoded byte cap for inline visual evidence.
    public static let maximumImageBytes = 8 * 1_024 * 1_024
    /// Combined decoded bytes for one tool result.
    public static let maximumTotalBytes = 16 * 1_024 * 1_024
    /// Maximum number of images attached from one tool result.
    public static let maximumImages = 4
    /// Boundary used when validating a base64 payload BEFORE decoding it:
    /// base64 expands by 4/3, so this bound rejects an oversized payload
    /// without allocating its decoded form.
    public static func maximumEncodedLength(decodedLimit: Int = maximumImageBytes) -> Int {
        ((decodedLimit + 2) / 3) * 4 + 4
    }

    /// Canonical MIME type (lowercased, "image/jpg" normalized to "image/jpeg"),
    /// or nil when the type is not provider-supported.
    public static func canonicalMIMEType(_ raw: String) -> String? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "image/jpg" { return "image/jpeg" }
        return supportedMIMETypes.contains(lower) ? lower : nil
    }

    /// Preferred file extension for a supported MIME type.
    public static func fileExtension(forMIME mime: String) -> String? {
        switch canonicalMIMEType(mime) {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return nil
        }
    }

    /// Real encoded family sniffed from the bytes, when recognizable. This is
    /// a lightweight signature check (PNG/JPEG/GIF/WebP containers), not a
    /// full decode; it exists to stop a declared MIME from spoofing a
    /// different payload family.
    public static func sniffedMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return nil }
        if bytes.count >= 8, Array(bytes[0...7]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 6,
           Array(bytes[0...5]) == Array("GIF87a".utf8) || Array(bytes[0...5]) == Array("GIF89a".utf8) {
            return "image/gif"
        }
        if bytes.count >= 12,
           Array(bytes[0...3]) == Array("RIFF".utf8),
           Array(bytes[8...11]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    public enum Validation: Equatable {
        case valid(mimeType: String, data: Data)
        case unsupportedType(String)
        case mimeMismatch(declared: String, actual: String)
        case overLimit(encodedLength: Int, limit: Int)
        case empty
        case malformedBase64
        /// The base64 payload cannot be decoded into an image this policy
        /// supports (signature unrecognized).
        case unrecognizedBytes
    }

    /// Validates one base64 image item WITHOUT decoding an over-limit payload:
    /// the encoded length is checked first, then the bytes are decoded and
    /// sniffed against the declared MIME.
    public static func validate(
        declaredMIME: String,
        base64: String,
        decodedLimit: Int = maximumImageBytes
    ) -> Validation {
        guard let canonical = canonicalMIMEType(declaredMIME) else {
            return .unsupportedType(declaredMIME)
        }
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let encodedLimit = maximumEncodedLength(decodedLimit: decodedLimit)
        guard trimmed.utf8.count <= encodedLimit else {
            return .overLimit(encodedLength: trimmed.utf8.count, limit: decodedLimit)
        }
        guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) else {
            return .malformedBase64
        }
        guard !data.isEmpty else { return .empty }
        guard data.count <= decodedLimit else {
            return .overLimit(encodedLength: trimmed.utf8.count, limit: decodedLimit)
        }
        guard let sniffed = sniffedMIME(data) else { return .unrecognizedBytes }
        guard sniffed == canonical else {
            return .mimeMismatch(declared: canonical, actual: sniffed)
        }
        return .valid(mimeType: canonical, data: data)
    }

    /// Human-readable rejection reason for the explicit diagnostic.
    public static func rejectionReason(_ validation: Validation) -> String? {
        switch validation {
        case .valid:
            return nil
        case .unsupportedType(let declared):
            return "unsupported image type \(declared)"
        case .mimeMismatch(let declared, let actual):
            return "declared \(declared) but the bytes are \(actual)"
        case .overLimit(_, let limit):
            return "over the \(limit / (1_024 * 1_024)) MiB image limit"
        case .empty:
            return "empty image payload"
        case .malformedBase64:
            return "malformed base64 image payload"
        case .unrecognizedBytes:
            return "unrecognized image bytes"
        }
    }
}
