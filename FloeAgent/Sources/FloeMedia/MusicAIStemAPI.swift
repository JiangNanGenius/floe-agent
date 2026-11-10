// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum MusicAIStemError: Error, Sendable, Equatable {
    case missingConfiguration(String)
    case invalidConfiguration(String)
    case invalidResponse(String)
    case httpStatus(Int)
}

public struct MusicAIStemConfiguration: Sendable, Equatable {
    public var baseURL: URL
    public var workflow: String
    public var vocalsKey: String
    public var accompanimentKey: String
    public init(baseURL: URL = URL(string: "https://api.music.ai/v1")!, workflow: String = "music-ai/stems-vocals-accompaniment",
        vocalsKey: String = "vocals", accompanimentKey: String = "accompaniments") {
        self.baseURL = baseURL; self.workflow = workflow; self.vocalsKey = vocalsKey; self.accompanimentKey = accompanimentKey
    }
    public func validate() throws {
        guard MusicAIStemAPI.safeHTTPS(baseURL), baseURL.query == nil,
              !workflow.isEmpty, workflow.utf8.count <= 256, !workflow.unicodeScalars.contains(where: { $0.value < 32 }),
              !vocalsKey.isEmpty, !accompanimentKey.isEmpty, vocalsKey != accompanimentKey,
              vocalsKey.utf8.count <= 128, accompanimentKey.utf8.count <= 128 else { throw MusicAIStemError.invalidConfiguration("choose a valid Music.AI endpoint, workflow and distinct result keys") }
    }
}

public struct MusicAIStemHTTPRequest: Sendable {
    public enum Body: Sendable { case none, bytes(Data), file(URL) }
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Body
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
}
public struct MusicAIStemHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}
/// App adapters must use the existing bounded HTTPRequestService and task/job
/// authority. No URLSession, credential store or execution alias is added.
public protocol MusicAIStemHTTPTransport: Sendable {
    func send(_ request: MusicAIStemHTTPRequest, work: AudioPCMWork) async throws -> MusicAIStemHTTPResponse
}
public struct MusicAIStemUpload: Sendable {
    public let uploadURL: URL
    public let downloadURL: URL
}
/// Persist only within the existing owning App job record. A decoded receipt
/// is data, not permission; the App must revalidate original/run ownership.
public struct MusicAIStemJob: Codable, Sendable, Equatable {
    public let id: String
    public let workflow: String
    fileprivate init(id: String, workflow: String) { self.id = id; self.workflow = workflow }
}
public struct MusicAIStemJobSnapshot: Sendable {
    public enum State: String, Decodable, Sendable { case queued = "QUEUED", started = "STARTED", succeeded = "SUCCEEDED", failed = "FAILED" }
    public struct Failure: Decodable, Sendable { public let code: String; public let title: String; public let message: String }
    public let job: MusicAIStemJob
    public let state: State
    public let vocalsURL: URL?
    public let accompanimentURL: URL?
    public let failure: Failure?
}

/// Official upload/create/status/delete contract. The host's existing job
/// service owns polling, cancellation, downloads and final original CAS.
/// No subscription probe or developer-account test gates configured users.
public struct MusicAIStemAPI: Sendable {
    public typealias Credential = @Sendable () async throws -> String?
    public let configuration: MusicAIStemConfiguration
    private let transport: any MusicAIStemHTTPTransport
    private let credential: Credential
    public init(configuration: MusicAIStemConfiguration = .init(), transport: any MusicAIStemHTTPTransport, credential: @escaping Credential) throws {
        try configuration.validate(); self.configuration = configuration; self.transport = transport; self.credential = credential
    }
    public func prepareUpload(work: AudioPCMWork = .init()) async throws -> MusicAIStemUpload {
        struct Response: Decodable { let uploadUrl: URL; let downloadUrl: URL }
        let response: Response = try await api("GET", endpoint: "upload", work: work)
        guard Self.safeHTTPS(response.uploadUrl), Self.safeHTTPS(response.downloadUrl) else { throw MusicAIStemError.invalidResponse("upload URLs must be bounded HTTPS targets") }
        return .init(uploadURL: response.uploadUrl, downloadURL: response.downloadUrl)
    }
    public func uploadFile(_ source: URL, upload: MusicAIStemUpload, contentType: String, work: AudioPCMWork = .init()) async throws {
        try work.check()
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard source.isFileURL, values.isRegularFile == true, Self.safeHTTPS(upload.uploadURL), Self.safeHTTPS(upload.downloadURL),
              ["audio/wav", "audio/x-wav", "audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/ogg"].contains(contentType),
              let bytes = values.fileSize,
              bytes > 0, bytes <= 128 * 1_024 * 1_024 else { throw MusicAIStemError.invalidConfiguration("choose a bounded supported audio upload") }
        // Signed storage URLs receive neither the API key nor cookies.
        let response = try await transport.send(.init(method: "PUT", url: upload.uploadURL, headers: ["Content-Type": contentType], body: .file(source),
            maximumRequestBytes: 128 * 1_024 * 1_024, maximumResponseBytes: 65_536), work: work)
        try work.check(); try Self.check(response)
    }
    public func createJob(name: String, inputURL: URL, metadata: [String: String] = [:], work: AudioPCMWork = .init(),
        recordCreated: @Sendable (MusicAIStemJob) async throws -> Void) async throws -> MusicAIStemJob {
        struct Request: Encodable { let name: String; let workflow: String; let params: [String: String]; let metadata: [String: String] }
        struct Response: Decodable { let id: String }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512, Self.safeHTTPS(inputURL),
              metadata.count <= 32, metadata.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 1_024 }) else { throw MusicAIStemError.invalidConfiguration("job name, public input URL or metadata is invalid") }
        let body = try JSONEncoder().encode(Request(name: name, workflow: configuration.workflow, params: ["inputUrl": inputURL.absoluteString], metadata: metadata))
        try work.check()
        let request = try await request("POST", endpoint: "job", body: body)
        let raw = try await transport.send(request, work: work); try Self.check(raw)
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: raw.body) }
        catch { throw MusicAIStemError.invalidResponse("the create response has no valid job receipt") }
        guard Self.safeJobID(response.id) else { throw MusicAIStemError.invalidResponse("the create response has no valid job ID") }
        let job = MusicAIStemJob(id: response.id, workflow: configuration.workflow)
        // Record a known remote ID even if cancellation arrived with its
        // response. A late callback must not silently lose owned cleanup or
        // recovery information. The App's existing job store supplies this.
        try await recordCreated(job)
        try work.check(); return job
    }
    public func status(_ job: MusicAIStemJob, work: AudioPCMWork = .init()) async throws -> MusicAIStemJobSnapshot {
        struct Response: Decodable {
            let id: String; let workflow: String; let status: MusicAIStemJobSnapshot.State
            let result: [String: URL]?; let error: MusicAIStemJobSnapshot.Failure?
        }
        try validate(job)
        let response: Response = try await api("GET", endpoint: "job/" + job.id, work: work)
        guard response.id == job.id, response.workflow == job.workflow else { throw MusicAIStemError.invalidResponse("the returned job does not match this owned request") }
        let vocals = response.result?[configuration.vocalsKey], accompaniment = response.result?[configuration.accompanimentKey]
        if response.status == .succeeded {
            guard let vocals, let accompaniment, Self.safeHTTPS(vocals), Self.safeHTTPS(accompaniment), vocals != accompaniment else { throw MusicAIStemError.invalidResponse("completed separation must return distinct valid vocal and accompaniment URLs") }
        }
        if response.status == .failed {
            guard let error = response.error, !error.code.isEmpty, error.code.utf8.count <= 256,
                  error.title.utf8.count <= 1_024, error.message.utf8.count <= 4_096 else { throw MusicAIStemError.invalidResponse("failed separation has no bounded provider error") }
        }
        return .init(job: job, state: response.status, vocalsURL: response.status == .succeeded ? vocals : nil,
            accompanimentURL: response.status == .succeeded ? accompaniment : nil, failure: response.error)
    }
    /// Only the owning job service calls this for its own remote job, normally
    /// after verified download. DELETE removes a job; no claim is made that it
    /// aborts already-billed computation. Original/user assets are untouched.
    public func delete(_ job: MusicAIStemJob, work: AudioPCMWork = .init()) async throws {
        try validate(job); let request = try await request("DELETE", endpoint: "job/" + job.id, body: nil)
        let response = try await transport.send(request, work: work); try work.check(); try Self.check(response)
    }
    private func validate(_ job: MusicAIStemJob) throws {
        guard Self.safeJobID(job.id), job.workflow == configuration.workflow else { throw MusicAIStemError.invalidConfiguration("job receipt does not match the configured workflow") }
    }
    private func api<Response: Decodable>(_ method: String, endpoint: String, body: Data? = nil, work: AudioPCMWork) async throws -> Response {
        try work.check(); let request = try await request(method, endpoint: endpoint, body: body)
        let response = try await transport.send(request, work: work); try work.check(); try Self.check(response)
        do { return try JSONDecoder().decode(Response.self, from: response.body) }
        catch { throw MusicAIStemError.invalidResponse("the service returned an incompatible " + endpoint.split(separator: "/")[0] + " response") }
    }
    private func request(_ method: String, endpoint: String, body: Data?) async throws -> MusicAIStemHTTPRequest {
        guard let key = try await credential(), !key.isEmpty else { throw MusicAIStemError.missingConfiguration("apiKey") }
        guard key.utf8.count <= 16_384, !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw MusicAIStemError.invalidConfiguration("API key contains unsupported controls") }
        var headers = ["Authorization": key] // Official API uses the raw key.
        if body != nil { headers["Content-Type"] = "application/json" }
        let url = endpoint.split(separator: "/").reduce(configuration.baseURL) { $0.appendingPathComponent(String($1)) }
        return .init(method: method, url: url, headers: headers, body: body.map { .bytes($0) } ?? .none, maximumRequestBytes: 65_536, maximumResponseBytes: 65_536)
    }
    private static func check(_ response: MusicAIStemHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw MusicAIStemError.httpStatus(response.statusCode) }
        guard response.body.count <= 65_536 else { throw MusicAIStemError.invalidResponse("response exceeds the JSON/metadata bound") }
    }
    private static func safeJobID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0) }
    }
    public static func safeHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil && url.absoluteString.utf8.count <= 16_384
    }
}
