// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeExecution
import FloeMedia
import FloeTools
import FloeWorkbench

/// The Music.AI HTTP seam into the App's EXISTING reviewed transport. Every
/// request keeps public-network/redirect policy (HTTPRequestService default
/// public mode), bounded sizes and cooperative cancellation. Only the
/// configured API host may carry the raw Authorization header; signed storage
/// PUTs/GETs never receive API credentials or cookies, and the service is
/// cookieless by construction.
struct MediaV2StemHTTPTransport: MusicAIStemHTTPTransport, Sendable {
    private let service: HTTPRequestService
    private let apiHosts: Set<String>
    init(service: HTTPRequestService = HTTPRequestService(), apiHosts: Set<String>) {
        self.service = service; self.apiHosts = Set(apiHosts.compactMap { $0.lowercased() })
    }
    func send(_ request: MusicAIStemHTTPRequest, work: AudioPCMWork) async throws -> MusicAIStemHTTPResponse {
        try work.check(); try Task.checkCancellation()
        guard ["GET", "POST", "PUT", "DELETE"].contains(request.method), MusicAIStemAPI.safeHTTPS(request.url) else {
            throw MusicAIStemError.invalidConfiguration("the stem request is not a bounded HTTPS API operation")
        }
        var headers = request.headers
        if let host = request.url.host?.lowercased(), !apiHosts.contains(host) {
            // Defense in depth: never move an API key to another origin.
            headers = headers.filter { pair in ["authorization", "cookie"].allSatisfy { blocked in pair.key.caseInsensitiveCompare(blocked) != .orderedSame } }
        }
        var body: Data?
        switch request.body {
        case .none: body = nil
        case .bytes(let data):
            guard data.count <= request.maximumRequestBytes else { throw MusicAIStemError.invalidConfiguration("the JSON body exceeds its bound") }
            body = data
        case .file(let url):
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= request.maximumRequestBytes else {
                throw MusicAIStemError.invalidConfiguration("the upload body is missing or exceeds its bound")
            }
            body = try await Self.readFile(url, limit: request.maximumRequestBytes, work: work)
        }
        let response = try await service.send(method: request.method, url: request.url, headers: headers, body: body,
            timeout: 120, maxResponseBytes: min(max(1, request.maximumResponseBytes), HTTPRequestService.maximumResponseBytes))
        try work.check(); try Task.checkCancellation()
        guard !response.truncated, response.receivedBytes <= request.maximumResponseBytes else {
            throw MusicAIStemError.invalidResponse("the provider response exceeded its bounded size")
        }
        return MusicAIStemHTTPResponse(statusCode: response.statusCode, body: Data(response.body.utf8))
    }
    private static func readFile(_ url: URL, limit: Int, work: AudioPCMWork) async throws -> Data {
        // The excerpt read is bounded and never happens on the main actor.
        let worker = Task.detached(priority: .userInitiated) { () throws -> Data in
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= limit else { throw MusicAIStemError.invalidConfiguration("the upload body grew beyond its bound") }
            }
            return data
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

/// Bounded provider-result downloads through the existing reviewed download
/// path (public network + redirect revalidation + byte cap + cancellation).
struct MediaV2StemDownloader: AudioStemCloudDownloading, Sendable {
    func download(_ url: URL, to destination: URL, maxBytes: Int, work: AudioPCMWork) async throws {
        try work.check()
        guard MusicAIStemAPI.safeHTTPS(url) else { throw AudioStemCloudError.unsafeResult("result URL is not bounded HTTPS") }
        let service = HTTPRequestService()
        let token = CancellationToken()
        let watcher = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if work.isCancelled() { token.cancel(); return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { watcher.cancel() }
        do {
            let result = try await service.download(url: url, timeout: 120, maxBytes: maxBytes, to: destination, cancellation: token)
            try work.check()
            guard (200..<300).contains(result.statusCode) else { throw MusicAIStemError.httpStatus(result.statusCode) }
        } catch is CancellationError {
            throw AudioPCMProcessingError.cancelled
        } catch let error as HTTPRequestError {
            throw MusicAIStemError.invalidResponse(error.localizedDescription)
        }
    }
}

/// App-side provider factory for the voice-separation route. The API object
/// binds the configured Music.AI profile (Keychain-backed credential) to the
/// existing reviewed transport; nothing here probes accounts or gates on
/// developer subscriptions.
@MainActor enum MediaV2StemProvider {
    static func makeAPI() throws -> MusicAIStemAPI {
        let settings = MusicAIStemSettingsStore.shared
        guard settings.isReady else {
            throw MediaPreparedCoreError.invalidOperation(
                WorkbenchText.t("请先在设置中启用并配置 Music.AI 人声分离密钥。", "Enable and configure the Music.AI voice-separation key in Settings first."))
        }
        let configuration = settings.configuration
        let transport = MediaV2StemHTTPTransport(apiHosts: Set([configuration.baseURL.host].compactMap { $0 }))
        // The credential closure stays Sendable: it captures only the
        // approved store handle and account name, never this MainActor model.
        let keychain = settings.credentialStore
        let account = MusicAIStemSettingsStore.credentialAccountName
        return try MusicAIStemAPI(configuration: configuration, transport: transport, credential: {
            guard let data = try? keychain.read(account: account),
                  let value = String(data: data, encoding: .utf8), !value.isEmpty, value.utf8.count <= 16_384 else { return nil }
            return value
        })
    }
}
#endif
