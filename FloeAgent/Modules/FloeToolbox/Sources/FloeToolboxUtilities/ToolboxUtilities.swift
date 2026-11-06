import Foundation
import CryptoKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import FloeToolboxCore

public enum ToolboxChecksumAlgorithm: String, CaseIterable, Codable, Sendable { case sha256, sha512, sha1, md5, crc32 }
public struct ToolboxChecksum: Sendable, Equatable {
    public let algorithm: ToolboxChecksumAlgorithm
    public let hexadecimal: String
    public let byteCount: UInt64
    public func matches(_ candidate: String) -> Bool {
        let value = candidate.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard value.utf8.count == hexadecimal.utf8.count, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        return value == hexadecimal
    }
}
public typealias ToolboxByteReader = @Sendable (_ offset: UInt64, _ maximumBytes: Int) async throws -> Data
private enum ChecksumState {
    case sha256(SHA256), sha512(SHA512), sha1(Insecure.SHA1), md5(Insecure.MD5), crc32(UInt32)
    init(_ algorithm: ToolboxChecksumAlgorithm) {
        switch algorithm {
        case .sha256: self = .sha256(SHA256())
        case .sha512: self = .sha512(SHA512())
        case .sha1: self = .sha1(Insecure.SHA1())
        case .md5: self = .md5(Insecure.MD5())
        case .crc32: self = .crc32(0xffffffff)
        }
    }
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1)^0xedb88320 }
        return value
    }
    mutating func update(_ bytes: Data) {
        switch self {
        case .sha256(var value): value.update(data:bytes); self = .sha256(value)
        case .sha512(var value): value.update(data:bytes); self = .sha512(value)
        case .sha1(var value): value.update(data:bytes); self = .sha1(value)
        case .md5(var value): value.update(data:bytes); self = .md5(value)
        case .crc32(var value):
            for byte in bytes { value = Self.table[Int((value^UInt32(byte))&255)]^(value >> 8) }
            self = .crc32(value)
        }
    }
    var hexadecimal: String {
        let bytes: [UInt8]
        switch self {
        case .sha256(let value): bytes = Array(value.finalize())
        case .sha512(let value): bytes = Array(value.finalize())
        case .sha1(let value): bytes = Array(value.finalize())
        case .md5(let value): bytes = Array(value.finalize())
        case .crc32(let value): return String(format:"%08x",value^0xffffffff)
        }
        return bytes.map { String(format:"%02x",$0) }.joined()
    }
}
public enum ToolboxFileChecksum {
    /// Reader adapts the existing selected-file service. This module chooses no directory or interpreter.
    public static func calculate(_ algorithm: ToolboxChecksumAlgorithm, expectedByteCount: UInt64? = nil,
                                 maximumBytes: UInt64 = 32*1024*1024*1024, read: ToolboxByteReader,
                                 progress: @Sendable (UInt64) async -> Void = { _ in }) async throws -> ToolboxChecksum {
        guard maximumBytes > 0, maximumBytes <= 1024*1024*1024*1024,
              expectedByteCount.map({ $0 <= maximumBytes }) ?? true else { throw ToolboxError.limit("checksum size") }
        var state = ChecksumState(algorithm), offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let count = Int(min(65536,maximumBytes-offset+1))
            let bytes = try await read(offset,count); try Task.checkCancellation()
            guard bytes.count <= count, UInt64(bytes.count) <= maximumBytes-offset else { throw ToolboxError.limit("checksum reader") }
            if bytes.isEmpty { break }
            state.update(bytes); offset += UInt64(bytes.count); await progress(offset)
        }
        guard expectedByteCount.map({ $0 == offset }) ?? true else { throw ToolboxError.revisionConflict }
        return ToolboxChecksum(algorithm:algorithm,hexadecimal:state.hexadecimal,byteCount:offset)
    }
}

public enum ToolboxJSONStyle: Sendable { case pretty, compact, sorted }
public enum ToolboxJSON {
    public static func format(_ input: String, style: ToolboxJSONStyle = .pretty,
                              maximumBytes: Int = 1024*1024, maximumDepth: Int = 128) throws -> String {
        guard maximumBytes > 0, maximumBytes <= 4*1024*1024, (1...128).contains(maximumDepth),
              input.utf8.count <= maximumBytes else { throw ToolboxError.limit("JSON input") }
        var quoted = false, escaped = false, depth = 0, expanded = input.utf8.count
        for byte in input.utf8 {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true; continue }
            if byte == 123 || byte == 91 { depth += 1; guard depth <= maximumDepth else { throw ToolboxError.limit("JSON depth") }; expanded += depth*2+1 }
            if byte == 125 || byte == 93 { depth -= 1; guard depth >= 0 else { throw ToolboxError.invalid("JSON structure") }; expanded += depth*2+1 }
            if byte == 44 { expanded += depth*2+1 }
            if byte == 58 { expanded += 1 }
            guard expanded <= 8*1024*1024 else { throw ToolboxError.limit("JSON output") }
        }
        guard !quoted, depth == 0 else { throw ToolboxError.invalid("JSON structure") }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with:Data(input.utf8),options:.fragmentsAllowed) }
        catch { throw ToolboxError.invalid("JSON syntax") }
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed,.withoutEscapingSlashes]
        if style == .pretty { options.insert(.prettyPrinted) }
        if style == .sorted { options.insert(.sortedKeys) }
        let result = try JSONSerialization.data(withJSONObject:value,options:options)
        guard result.count <= 8*1024*1024, let text = String(data:result,encoding:.utf8) else { throw ToolboxError.limit("JSON output") }
        return text
    }
}
public enum ToolboxTextEncoding {
    public static func base64Encode(_ input: String) throws -> String {
        guard input.utf8.count <= 1024*1024 else { throw ToolboxError.limit("text input") }
        return Data(input.utf8).base64EncodedString()
    }
    public static func base64Decode(_ input: String) throws -> String {
        guard input.utf8.count <= 2*1024*1024 else { throw ToolboxError.limit("Base64 input") }
        guard let bytes = Data(base64Encoded:input), bytes.count <= 1024*1024, let text = String(data:bytes,encoding:.utf8) else { throw ToolboxError.invalid("Base64 or UTF-8") }
        return text
    }
    /// Encodes a component, not an entire URL. Reserved path/query separators are escaped.
    public static func urlEncode(_ input: String) throws -> String {
        guard input.utf8.count <= 1024*1024 else { throw ToolboxError.limit("text input") }
        let allowed = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let text = input.addingPercentEncoding(withAllowedCharacters:allowed) else { throw ToolboxError.invalid("URL component") }; return text
    }
    public static func urlDecode(_ input: String) throws -> String {
        guard input.utf8.count <= 3*1024*1024 else { throw ToolboxError.limit("URL input") }
        guard let text = input.removingPercentEncoding, text.utf8.count <= 1024*1024 else { throw ToolboxError.invalid("percent encoding or UTF-8") }; return text
    }
}

public enum ToolboxQR {
    public enum Correction: String, CaseIterable, Sendable { case low = "L", medium = "M", quartile = "Q", high = "H" }
    public static func png(text: String, correction: Correction = .medium, scale: Int = 8) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= 1024, (1...64).contains(scale),
              let filter = CIFilter(name:"CIQRCodeGenerator") else { throw ToolboxError.invalid("QR input") }
        filter.setValue(Data(text.utf8),forKey:"inputMessage"); filter.setValue(correction.rawValue,forKey:"inputCorrectionLevel")
        guard let code = filter.outputImage else { throw ToolboxError.invalid("QR capacity") }
        let bounds = code.extent.integral.insetBy(dx:-4,dy:-4)
        guard bounds.width*Double(scale) <= 4096, bounds.height*Double(scale) <= 4096 else { throw ToolboxError.limit("QR image") }
        let background = CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:bounds)
        let result = code.composited(over:background).transformed(by:CGAffineTransform(scaleX:Double(scale),y:Double(scale)))
        let context = CIContext(options:[.useSoftwareRenderer:true])
        guard let image = context.createCGImage(result,from:result.extent) else { throw ToolboxError.invalid("QR render") }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes as CFMutableData,UTType.png.identifier as CFString,1,nil) else { throw ToolboxError.invalid("PNG encoder") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolboxError.invalid("PNG encoder") }
        return bytes as Data
    }
    public static func read(imageData: Data) throws -> [String] {
        guard imageData.count <= 16*1024*1024,
              let source = CGImageSourceCreateWithData(imageData as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue <= 16384, height.doubleValue <= 16384,
              width.doubleValue*height.doubleValue <= 16*1024*1024,
              let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw ToolboxError.invalid("QR image bounds") }
        let context = CIContext(options:[.useSoftwareRenderer:true])
        guard let detector = CIDetector(ofType:CIDetectorTypeQRCode,context:context,options:[CIDetectorAccuracy:CIDetectorAccuracyHigh]) else { throw ToolboxError.unsupported("QR detector") }
        let features = detector.features(in:CIImage(cgImage:image))
        guard features.count <= 64 else { throw ToolboxError.limit("QR count") }
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.filter { $0.utf8.count <= 8192 }
    }
}
