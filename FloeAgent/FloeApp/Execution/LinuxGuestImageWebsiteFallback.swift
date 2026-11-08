// FloeApp — the website is a byte location for an already pinned VM asset.
import Foundation
import FloeExecution

nonisolated struct LinuxGuestImageMirrorPolicy: Sendable {
    let generation: Int64?
    let mirrorIDs: [String]
    static let unavailable = Self(generation: nil, mirrorIDs: [])

    var enabledIDs: [String] {
        guard let generation, generation > 0, mirrorIDs.count <= 2,
              Set(mirrorIDs).count == mirrorIDs.count,
              mirrorIDs.allSatisfy({ LinuxGuestImageWebsiteFallback.mirrorIDs.contains($0) }) else { return [] }
        return mirrorIDs
    }
}

nonisolated enum LinuxGuestImageWebsiteFallback {
    static let origin = URL(string: "https://www.floe-agent.com")!
    static let mirrorIDs: Set<String> = ["ghfast.top", "gh-proxy.com"]
    static let slowSeconds = 15
    static let slowBytesPerSecond: Int64 = 524_288
    static let indexMaximumBytes = 1_048_576
    static let ticketMaximumBytes = 16_384

    struct Asset: Decodable, Sendable {
        let githubAssetID: Int64?
        let id: String
        let name: String
        let product: String
        let size: Int64
        let sha256: String
        let sha512: String?
        let canonicalURL: String
        enum CodingKeys: String, CodingKey {
            case githubAssetID = "github_asset_id", id, name, product, size, sha256, sha512
            case canonicalURL = "canonical_url"
        }
    }
    private struct Policy: Decodable {
        let slowSeconds: Int
        let slowBytesPerSecond: Int64
        let requiredMirrors: [String]
        enum CodingKeys: String, CodingKey {
            case slowSeconds = "slow_seconds", slowBytesPerSecond = "slow_bytes_per_second"
            case requiredMirrors = "required_mirrors"
        }
    }
    private struct Index: Decodable {
        let schemaVersion: Int
        let assets: [Asset]
        let stale: Bool
        let fallbackPolicy: Policy
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", assets, stale, fallbackPolicy = "fallback_policy"
        }
    }
    struct Observation: Sendable {
        let seconds: Int
        let receivedBytes: Int64
        let slow: Bool
        var qualifiesAsSlow: Bool {
            slow && seconds >= slowSeconds && seconds <= 3600 && receivedBytes >= 0
                && receivedBytes / Int64(seconds) < slowBytesPerSecond
        }
    }
    private struct Admission: Encodable {
        let assetID: String
        let reporter = "client"
        let reason: String
        let observationSeconds: Int
        let receivedBytes: Int64
        let mirrorFailures: [String]
        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id", reporter, reason, observationSeconds = "observation_seconds"
            case receivedBytes = "received_bytes", mirrorFailures = "mirror_failures"
        }
    }
    struct Ticket: Decodable, Sendable {
        let url: String
        let token: String
        let expiresAt: Int64
        let etag: String
        let size: Int64
        let sha256: String
        enum CodingKeys: String, CodingKey {
            case url, token, expiresAt = "expires_at", etag, size, sha256
        }
    }

    static func asset(in data: Data, image: LinuxGuestTrustedImage) throws(LinuxGuestImageTransferError) -> Asset {
        guard data.count <= indexMaximumBytes,
              let pin = image.assetPin, pin.githubAssetID > 0, pin.bytes > 0,
              isDigest(pin.sha256, digits: 64), isDigest(image.archiveSHA512, digits: 128),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.schemaVersion == 1, !index.stale, index.assets.count <= 256,
              index.fallbackPolicy.slowSeconds == slowSeconds,
              index.fallbackPolicy.slowBytesPerSecond == slowBytesPerSecond,
              index.fallbackPolicy.requiredMirrors.count == 2,
              Set(index.fallbackPolicy.requiredMirrors) == mirrorIDs else {
            throw .responseInvalid(detail: "The website cache does not match this image")
        }
        // Do not search for the latest image or accept a nearby version. The
        // immutable catalog URL, GitHub ID, byte count and BOTH hashes bind it.
        let rows = index.assets.filter { $0.githubAssetID == pin.githubAssetID
            || $0.canonicalURL == image.archiveURL.absoluteString }
        guard rows.count == 1, let row = rows.first,
              row.product == "vm", row.githubAssetID == pin.githubAssetID,
              row.size == pin.bytes, row.sha256 == pin.sha256,
              row.sha512 == image.archiveSHA512,
              row.canonicalURL == image.archiveURL.absoluteString,
              row.name == image.archiveURL.lastPathComponent,
              row.id == pin.sha256 + "-" + String(pin.githubAssetID),
              row.name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            throw .responseInvalid(detail: "The pinned image is not available in the website cache")
        }
        return row
    }

    static func admission(asset: Asset, observation: Observation, failures: [String], policy: LinuxGuestImageMirrorPolicy)
        throws(LinuxGuestImageTransferError) -> URLRequest {
        guard failures.count == 2, Set(failures) == mirrorIDs,
              Set(policy.enabledIDs) == mirrorIDs, observation.seconds >= 0,
              observation.receivedBytes >= 0, !observation.slow || observation.qualifiesAsSlow else {
            throw .responseInvalid(detail: "The website fallback has no eligible transfer observation")
        }
        var request = publicRequest(path: "/api/v1/distribution/fallback")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Admission(assetID: asset.id,
            reason: observation.qualifiesAsSlow ? "upstream_slow" : "upstream_unavailable",
            observationSeconds: observation.seconds, receivedBytes: observation.receivedBytes,
            mirrorFailures: failures))
        guard let body = request.httpBody, body.count <= 4096 else {
            throw .responseInvalid(detail: "The website fallback request is invalid")
        }
        return request
    }

    static func ticket(in data: Data, asset: Asset, now: Date = Date()) throws(LinuxGuestImageTransferError) -> Ticket {
        guard data.count <= ticketMaximumBytes,
              let ticket = try? JSONDecoder().decode(Ticket.self, from: data),
              ticket.url == "/downloads/" + asset.id + "/" + asset.name,
              !ticket.token.isEmpty, ticket.token.utf8.count <= 4096,
              ticket.token.utf8.allSatisfy({ (33...126).contains($0) }),
              ticket.expiresAt > Int64(now.timeIntervalSince1970),
              ticket.expiresAt <= Int64(now.timeIntervalSince1970) + 1260,
              ticket.size == asset.size, ticket.sha256 == asset.sha256,
              ticket.etag == "\"sha256:" + asset.sha256 + "\"" else {
            throw .responseInvalid(detail: "The website download ticket is invalid or expired")
        }
        return ticket
    }

    static func downloadRequest(ticket: Ticket, offset: Int64) -> URLRequest {
        var request = publicRequest(path: ticket.url)
        request.setValue("Bearer " + ticket.token, forHTTPHeaderField: "Authorization")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(ticket.etag, forHTTPHeaderField: "If-Range")
        }
        return request
    }

    static func publicRequest(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: origin)!.absoluteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Return the actual file offset to use. A complete 200 response always
    /// resets the file; a 206 must match the exact pinned object and prefix.
    static func responseOffset(_ response: HTTPURLResponse, ticket: Ticket, requestedOffset: Int64)
        throws(LinuxGuestImageTransferError) -> Int64 {
        guard sameOrigin(response.url), response.value(forHTTPHeaderField: "ETag") == ticket.etag else {
            throw .responseInvalid(detail: "The website download response does not match this image")
        }
        if response.statusCode == 200 {
            guard response.expectedContentLength == ticket.size else {
                throw .responseInvalid(detail: "The website download size is invalid")
            }
            return 0
        }
        guard response.statusCode == 206, requestedOffset > 0, requestedOffset < ticket.size,
              response.expectedContentLength == ticket.size - requestedOffset,
              response.value(forHTTPHeaderField: "Content-Range")
                == "bytes \(requestedOffset)-\(ticket.size - 1)/\(ticket.size)" else {
            throw .responseInvalid(detail: "The website download range is invalid")
        }
        return requestedOffset
    }

    static func sameOrigin(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host == "www.floe-agent.com"
            && parts.port == nil && parts.user == nil && parts.password == nil
            && parts.query == nil && parts.fragment == nil
    }

    private static func isDigest(_ text: String, digits: Int) -> Bool {
        text.utf8.count == digits && text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
}
