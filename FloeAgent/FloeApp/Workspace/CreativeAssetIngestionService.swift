#if canImport(UIKit)
import Crypto
import Darwin
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import FloeCore
import FloePersistence

enum CreativeAssetIngestionError: LocalizedError, Equatable {
    case unsafeURL
    case unsupportedImage
    case payloadTooLarge
    case invalidResponse
    case missingLocalFile

    var errorDescription: String? {
        switch self {
        case .unsafeURL:
            "素材网址不安全。仅支持公开 HTTPS 图片，不能访问本机或私有网络。"
        case .unsupportedImage:
            "下载内容不是受支持的图片，或图片尺寸超过安全限制。"
        case .payloadTooLarge:
            "参考图片超过 20 MiB，无法安全导入。"
        case .invalidResponse:
            "图片服务器没有返回可用的图片响应。"
        case .missingLocalFile:
            "参考素材尚未下载到本机，请重新导入后再生成。"
        }
    }
}

/// The one ingestion boundary for the material library and Canvas Agent.
/// Remote images are validated and persisted before any provider can receive
/// them; provider adapters continue to accept local bytes only.
actor CreativeAssetIngestionService {
    static let maximumRemoteBytes = 20 * 1_024 * 1_024
    static let maximumPixelCount = 80_000_000

    private let assetStore: CreativeAssetStore

    init(assetStore: CreativeAssetStore) {
        self.assetStore = assetStore
    }

    func importLocalFile(_ source: URL) async throws -> CreativeAssetRecord {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CreativeAssetIngestionError.missingLocalFile
        }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let type = UTType(filenameExtension: source.pathExtension)
        return try await persist(
            data: data,
            kind: Self.mediaKind(for: type),
            displayName: source.deletingPathExtension().lastPathComponent,
            fileExtension: Self.safeExtension(type: type, fallback: source.pathExtension),
            mimeType: type?.preferredMIMEType,
            sourceURL: nil,
            license: nil,
            tags: ["导入"]
        )
    }

    func importRemoteImage(
        from sourceURL: URL,
        displayName: String?,
        license: String?
    ) async throws -> CreativeAssetRecord {
        guard Self.isSafePublicHTTPSURL(sourceURL) else {
            throw CreativeAssetIngestionError.unsafeURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: RemoteAssetSessionDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.setValue("image/avif,image/webp,image/png,image/jpeg", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              Self.isSafePublicHTTPSURL(finalURL) else {
            throw CreativeAssetIngestionError.invalidResponse
        }
        if http.expectedContentLength > Self.maximumRemoteBytes || data.count > Self.maximumRemoteBytes {
            throw CreativeAssetIngestionError.payloadTooLarge
        }
        let normalized = try Self.normalizedImage(data)
        let fallbackName = finalURL.deletingPathExtension().lastPathComponent
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = if let name, !name.isEmpty {
            name
        } else {
            fallbackName.isEmpty ? "网络参考图" : fallbackName
        }
        return try await persist(
            data: normalized.data,
            kind: .image,
            displayName: resolvedName,
            fileExtension: normalized.fileExtension,
            mimeType: normalized.mimeType,
            sourceURL: sourceURL,
            license: license,
            tags: ["网络导入", "参考图"]
        )
    }

    private func persist(
        data: Data,
        kind: MediaKind,
        displayName: String,
        fileExtension: String,
        mimeType: String?,
        sourceURL: URL?,
        license: String?,
        tags: [String]
    ) async throws -> CreativeAssetRecord {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try await assetStore.asset(contentHash: hash),
           let relative = existing.localRelativePath,
           FileManager.default.fileExists(atPath: try localURL(relativePath: relative).path) {
            return existing
        }
        let existing = try await assetStore.asset(contentHash: hash)
        let id = existing?.id ?? UUID()
        let safeName = Self.sanitizedFilename(displayName)
        let filename = "\(id.uuidString)-\(safeName).\(fileExtension)"
        let destination = try materialsDirectory().appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        let record = CreativeAssetRecord(
            id: id,
            contentHash: hash,
            kind: kind,
            displayName: displayName,
            mimeType: mimeType,
            localRelativePath: "Materials/\(filename)",
            cloudRecordName: existing?.cloudRecordName,
            byteCount: Int64(data.count),
            sourceURL: sourceURL,
            license: license,
            tags: Array(Set((existing?.tags ?? []) + tags)).sorted(),
            referenceCount: existing?.referenceCount ?? 0,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )
        do {
            try await assetStore.save(record)
            return record
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func materialsDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("FloeAgent/Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func localURL(relativePath: String) throws -> URL {
        guard !relativePath.contains("..") else {
            throw CreativeAssetIngestionError.missingLocalFile
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return support.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    private static func normalizedImage(_ data: Data) throws -> (data: Data, fileExtension: String, mimeType: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= 20_000, height <= 20_000,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maximumPixelCount,
              let image = UIImage(data: data) else {
            throw CreativeAssetIngestionError.unsupportedImage
        }
        if let alpha = image.cgImage?.alphaInfo,
           [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha),
           let png = image.pngData(), png.count <= maximumRemoteBytes {
            return (png, "png", "image/png")
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.94),
              jpeg.count <= maximumRemoteBytes else {
            throw CreativeAssetIngestionError.payloadTooLarge
        }
        return (jpeg, "jpg", "image/jpeg")
    }

    private static func mediaKind(for type: UTType?) -> MediaKind {
        guard let type else { return .document }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .document
    }

    private static func safeExtension(type: UTType?, fallback: String) -> String {
        let candidate = type?.preferredFilenameExtension ?? fallback.lowercased()
        let safe = candidate.filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? "bin" : String(safe.prefix(12))
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "asset" : cleaned).prefix(80))
    }

    static func isSafePublicHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal") else { return false }
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var sawAddress = false
        while let info = cursor?.pointee {
            defer { cursor = info.ai_next }
            guard let address = info.ai_addr else { continue }
            sawAddress = true
            if info.ai_family == AF_INET {
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let value = UInt32(bigEndian: ipv4.sin_addr.s_addr)
                let a = UInt8((value >> 24) & 0xff), b = UInt8((value >> 16) & 0xff)
                if a == 0 || a == 10 || a == 127 || a >= 224
                    || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                    || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) {
                    return false
                }
            } else if info.ai_family == AF_INET6 {
                var ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
                let isIPv4Mapped = bytes.prefix(10).allSatisfy { $0 == 0 }
                    && bytes[10] == 0xff && bytes[11] == 0xff
                if isIPv4Mapped {
                    let a = bytes[12], b = bytes[13]
                    if a == 0 || a == 10 || a == 127 || a >= 224
                        || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                        || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) {
                        return false
                    }
                }
                if bytes.allSatisfy({ $0 == 0 })
                    || bytes == Array(repeating: 0, count: 15) + [1]
                    || (bytes[0] & 0xfe) == 0xfc
                    || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
                    return false
                }
            }
        }
        return sawAddress
    }
}

private final class RemoteAssetSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(CreativeAssetIngestionService.isSafePublicHTTPSURL) == true ? request : nil)
    }
}
#endif
