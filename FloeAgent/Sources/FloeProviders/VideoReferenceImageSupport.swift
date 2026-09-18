import Foundation
import FloeCore

/// Redirect policy for provider result downloads.
///
/// API calls never follow cross-host redirects (`SameHostRedirectPolicy` in
/// the video HTTP layer). Result downloads may legitimately redirect from the
/// provider API host to a provider-owned media host; only the documented
/// Google media surfaces are followed, and the credential header must be
/// stripped before the redirected request is sent. Pure and fixture-tested so
/// the download coordinator cannot drift from the policy.
public enum VideoDownloadRedirectPolicy {
    /// Hosts (or their subdomains) that Google generated-media downloads may
    /// redirect to.
    public static let allowedRedirectHosts = [
        "googleapis.com", "googleusercontent.com", "google.com", "googlevideo.com"
    ]

    public static func isAllowedMediaRedirectHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return allowedRedirectHosts.contains { lowered == $0 || lowered.hasSuffix("." + $0) }
    }

    /// True when a redirect may be followed: HTTPS only, same host or an
    /// allowlisted Google media host. Callers strip `x-goog-api-key` and
    /// `Authorization` on the cross-host case.
    public static func allowsRedirect(from originalHost: String?, to target: URL) -> Bool {
        guard let targetHost = target.host,
              target.scheme?.lowercased() == "https",
              target.user == nil, target.password == nil else { return false }
        if let originalHost, targetHost.caseInsensitiveCompare(originalHost) == .orderedSame {
            return true
        }
        return isAllowedMediaRedirectHost(targetHost)
    }
}

/// Reference-image support for the native video adapters.
///
/// Ordinary Agent tools can only read local bytes (conversation attachment or
/// a guarded workspace file). Those bytes are handed to a provider as an
/// inline `data:` URL, which is the documented inline-upload form for every
/// supported family:
/// - Google Veo: `instances[].referenceImages[].image.inlineData`
///   (Gemini API reference, 2026-09-19); Gemini Omni interactions take
///   `{"type": "image", "data": <base64>, "mime_type": ...}` input parts.
/// - Volcengine Ark Seedance: `content[].image_url.url` documents
///   "图片 URL、图片 Base64 编码、素材 ID".
/// - Alibaba DashScope Wan: `input.media[].url` / legacy `input.img_url`
///   document `data:{MIME};base64,{data}`.
///
/// Providers that are not verified for inline images return `false` here, so
/// a route is never advertised (or silently attempted) as image-to-video when
/// the adapter cannot actually send the image.
public enum VideoReferenceImagePolicy {
    /// Conservative ceiling for one inline reference image. Bounds the tool
    /// read, the JSON body and the provider's request size.
    public static let maximumBytes = 8 * 1024 * 1024
    /// Ordinary chat submits one reference image per job.
    public static let maximumAssets = 1
    /// File signatures accepted for inline upload.
    public static let acceptedMIMETypes = ["image/png", "image/jpeg", "image/webp"]

    public static func supportsReferenceImages(
        providerKind: ProviderKind,
        modelRemoteID: String
    ) -> Bool {
        switch providerKind {
        case .googleGemini:
            // Veo (reference images / first frame) and Omni (input image
            // parts) both accept inline images.
            return true
        case .volcengineArk:
            return true
        case .alibabaStudio:
            // The Wan adapter only builds an image request for the documented
            // first-frame field of the 3.x family. Any other Wan model is
            // text-only here rather than silently dropping the image.
            return modelRemoteID.hasPrefix("wan3.0-")
        case .openAI, .anthropic, .local, .custom:
            return false
        }
    }

    /// Builds the inline `data:` URL handed to `RemoteVideoRequest`. The
    /// payload is validated as an accepted image format; an unrecognized file
    /// is rejected instead of being uploaded under a guessed MIME type.
    public static func inlineDataURL(data: Data, declaredMIMEType: String? = nil) throws -> URL {
        guard !data.isEmpty else {
            throw RemoteVideoError.invalidRequest("The reference image is empty.")
        }
        guard data.count <= maximumBytes else {
            throw RemoteVideoError.invalidRequest(
                "The reference image is \(data.count) bytes; the limit is \(maximumBytes) bytes."
            )
        }
        guard let mimeType = detectedMIMEType(data) else {
            throw RemoteVideoError.invalidRequest(
                "Unsupported reference image format. Use PNG, JPEG or WebP."
            )
        }
        if let declaredMIMEType, declaredMIMEType.caseInsensitiveCompare(mimeType) != .orderedSame,
           !(declaredMIMEType.lowercased() == "image/jpg" && mimeType == "image/jpeg") {
            // The declared UTI disagrees with the bytes; the bytes win, but a
            // known mismatch is surfaced rather than silently relabeled.
            throw RemoteVideoError.invalidRequest(
                "The reference image content (\(mimeType)) does not match its declared type (\(declaredMIMEType))."
            )
        }
        let encoded = data.base64EncodedString()
        guard let url = URL(string: "data:\(mimeType);base64,\(encoded)"), url.scheme == "data" else {
            throw RemoteVideoError.invalidRequest("The reference image could not be encoded for upload.")
        }
        return url
    }

    /// Sniffs the accepted image formats by signature. Returns nil for
    /// anything else (including SVG and HEIC, which the documented provider
    /// inline forms do not accept here).
    public static func detectedMIMEType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if bytes.count >= 3, bytes[0...2] == [0xFF, 0xD8, 0xFF] {
            return "image/jpeg"
        }
        if bytes.count >= 12,
           Array(bytes[0...3]) == Array("RIFF".utf8),
           Array(bytes[8...11]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    /// Parses an inline `data:` URL coming through `RemoteVideoRequest`.
    /// `https` URLs are not silently downloaded: a provider that needs bytes
    /// must receive the bytes it was handed.
    public static func inlineImage(from url: URL, providerName: String) throws -> (mimeType: String, base64: String) {
        guard url.scheme?.lowercased() == "data" else {
            throw RemoteVideoError.invalidRequest(
                "\(providerName) requires an inline reference image; \(url.scheme ?? "unknown") URLs are not uploaded."
            )
        }
        let raw = url.absoluteString
        guard let comma = raw.firstIndex(of: ","),
              raw[raw.startIndex..<comma].contains(";base64") else {
            throw RemoteVideoError.invalidRequest("The inline reference image is not base64 encoded.")
        }
        let header = String(raw[raw.startIndex..<comma])
        let payload = String(raw[raw.index(after: comma)...])
        let mimeType = header
            .replacingOccurrences(of: "data:", with: "")
            .replacingOccurrences(of: ";base64", with: "")
            .trimmingCharacters(in: .whitespaces)
        let normalized = mimeType.isEmpty ? "image/png" : mimeType
        guard acceptedMIMETypes.contains(normalized.lowercased()),
              Data(base64Encoded: payload) != nil else {
            throw RemoteVideoError.invalidRequest("The inline reference image payload is not a supported base64 image.")
        }
        return (normalized.lowercased(), payload)
    }
}
