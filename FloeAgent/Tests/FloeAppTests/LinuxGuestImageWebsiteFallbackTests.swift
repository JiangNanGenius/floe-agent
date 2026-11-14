#if DEBUG && (canImport(UIKit) || os(macOS))
import Foundation
import Testing
import CryptoKit
import FloeExecution
@testable import FloeApp

private final class VMFallbackFixture: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable, Equatable { case range, full, tls, rejected, slow, suspended, tampered, body, localNetwork, oversized }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var mode: Mode = .range
        private var requests: [URLRequest] = []
        func reset(_ mode: Mode) { lock.withLock { self.mode = mode; requests = [] } }
        func append(_ request: URLRequest) -> Mode {
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = body
            }
            return lock.withLock { requests.append(captured); return mode }
        }
        func all() -> [URLRequest] { lock.withLock { requests } }
    }
    static let state = State()
    static let bytes = Data((0..<131_072).map { UInt8($0 % 251) })
    static let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    static let sha512 = SHA512.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    static let canonical = URL(string: "https://github.com/JiangNanGenius/floe-agent/releases/download/floe-vm-qualification/floe-linux-guest-qualification.zip")!
    static let image = LinuxGuestTrustedImage(id: "qualification", archiveURL: canonical,
        archiveSHA512: sha512, assetPin: .init(githubAssetID: 42, bytes: Int64(bytes.count), sha256: sha256),
        provenance: .init(sourceURL: "https://github.com/JiangNanGenius/floe-agent", distributionAllowed: true))
    static let assetID = sha256 + "-42"
    static let path = "/downloads/" + assetID + "/" + canonical.lastPathComponent
    static func index(tampered: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schema_version": 1, "stale": false,
            "fallback_policy": ["slow_seconds": 15, "slow_bytes_per_second": 524288,
                "required_mirrors": ["ghfast.top", "gh-proxy.com"]],
            "assets": [["github_asset_id": 42, "id": assetID, "name": canonical.lastPathComponent,
                "product": "vm", "size": bytes.count, "sha256": tampered ? String(repeating: "0", count: 64) : sha256,
                "sha512": sha512, "canonical_url": canonical.absoluteString]]])
    }
    static func ticket(url: String = path) -> Data {
        try! JSONSerialization.data(withJSONObject: ["url": url, "token": "qualification-opaque-token",
            "expires_at": Int(Date().timeIntervalSince1970) + 1200, "etag": "\"sha256:" + sha256 + "\"",
            "size": bytes.count, "sha256": sha256])
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.append(request)
        let url = request.url!
        if url.host != "www.floe-agent.com" {
            if mode == .oversized {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": String(Int64.max)])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            if url == Self.canonical && (mode == .slow || mode == .suspended) {
                let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": String(Self.bytes.count)])!
                client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                return
            }
            if mode == .localNetwork { client?.urlProtocol(self, didFailWithError: URLError(.dataNotAllowed)); return }
            if mode == .body { send(status: 200, data: Self.bytes); return }
            if mode == .rejected {
                send(status: 403, data: Data()); return
            }
            client?.urlProtocol(self, didFailWithError: URLError(mode == .tls ? .serverCertificateUntrusted : .cannotConnectToHost))
            return
        }
        if url.path == "/api/v1/distribution" { send(status: 200, data: Self.index(tampered: mode == .tampered)); return }
        if url.path == "/api/v1/distribution/fallback" { send(status: 200, data: Self.ticket()); return }
        guard url.path == Self.path else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let offset = request.value(forHTTPHeaderField: "Range").flatMap {
            Int($0.replacingOccurrences(of: "bytes=", with: "").replacingOccurrences(of: "-", with: ""))
        } ?? 0
        if offset > 0 && mode != .full {
            send(status: 206, data: Self.bytes.subdata(in: offset..<Self.bytes.count),
                headers: ["ETag": "\"sha256:" + Self.sha256 + "\"",
                    "Content-Range": "bytes \(offset)-\(Self.bytes.count - 1)/\(Self.bytes.count)"])
        } else {
            send(status: 200, data: Self.bytes, headers: ["ETag": "\"sha256:" + Self.sha256 + "\""])
        }
    }
    private func send(status: Int, data: Data, headers: [String: String] = [:]) {
        var headers = headers; headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("FloeApp.LinuxGuestImageWebsiteFallback", .serialized)
struct LinuxGuestImageWebsiteFallbackTests {
    private let policy = LinuxGuestImageMirrorPolicy(generation: 2, mirrorIDs: ["ghfast.top", "gh-proxy.com"])
    private func downloader(policy: LinuxGuestImageMirrorPolicy? = nil) -> LinuxGuestImageHTTPDownloader {
        let chosen = policy ?? self.policy
        return LinuxGuestImageHTTPDownloader(mirrorPolicy: { _ in chosen }, configuration: {
            let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [VMFallbackFixture.self]; return c
        }, imageForURL: { $0 == VMFallbackFixture.canonical ? VMFallbackFixture.image : nil })
    }
    private func destination() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-fallback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("image.zip")
    }

    @Test func oversizedContentLengthStopsBeforeWritingOrTryingAnotherSource() async throws {
        VMFallbackFixture.state.reset(.oversized)
        let target = try destination()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        do {
            try await downloader().download(VMFallbackFixture.canonical, to: target, maxBytes: 200_000, onProgress: { _, _ in })
            Issue.record("An oversized Content-Length was accepted")
        } catch let error {
            guard case .localRejection = error else { Issue.record("The declared size was not a terminal local refusal"); return }
        }
        #expect(VMFallbackFixture.state.all().count == 1)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func pinnedIdentityAndTicketURLRejectTamperingBeforeAdmission() async throws {
        VMFallbackFixture.state.reset(.tampered)
        let target = try destination(); defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        do { try await downloader().download(VMFallbackFixture.canonical, to: target, maxBytes: 200_000, onProgress: { _, _ in }); Issue.record("tampered index accepted") }
        catch let error { guard case .responseInvalid = error else { Issue.record("wrong terminal class"); return } }
        #expect(VMFallbackFixture.state.all().count == 4)
        #expect(!VMFallbackFixture.state.all().contains { $0.httpMethod == "POST" })
        for (key, replacement) in [("github_asset_id", 43 as Any), ("size", 131073 as Any),
            ("sha512", String(repeating: "0", count: 128) as Any), ("id", "another-asset" as Any),
            ("canonical_url", VMFallbackFixture.canonical.absoluteString + "?different" as Any),
            ("product", "android" as Any), ("name", "different.zip" as Any)] {
            var index = try #require(JSONSerialization.jsonObject(with: VMFallbackFixture.index()) as? [String: Any])
            var assets = try #require(index["assets"] as? [[String: Any]])
            assets[0][key] = replacement; index["assets"] = assets
            let data = try JSONSerialization.data(withJSONObject: index)
            #expect(throws: LinuxGuestImageTransferError.self) {
                try LinuxGuestImageWebsiteFallback.asset(in: data, image: VMFallbackFixture.image)
            }
        }
        let asset = try LinuxGuestImageWebsiteFallback.asset(in: VMFallbackFixture.index(), image: VMFallbackFixture.image)
        for bad in ["https://other.invalid" + VMFallbackFixture.path, "//other.invalid/file", "/downloads/other/file", VMFallbackFixture.path + "?token=forbidden"] {
            #expect(throws: LinuxGuestImageTransferError.self) {
                try LinuxGuestImageWebsiteFallback.ticket(in: VMFallbackFixture.ticket(url: bad), asset: asset)
            }
        }
    }

    @Test(arguments: [false, true]) func exactBytesResumeOrResetWithoutChangingPins(fullResponse: Bool) async throws {
        VMFallbackFixture.state.reset(fullResponse ? .full : .range)
        let target = try destination(); defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try VMFallbackFixture.bytes.prefix(65_536).write(to: target)
        try await downloader().download(VMFallbackFixture.canonical, to: target, maxBytes: 200_000, onProgress: { _, _ in })
        let output = try Data(contentsOf: target)
        #expect(output == VMFallbackFixture.bytes)
        #expect(SHA512.hash(data: output).map { String(format: "%02x", $0) }.joined() == VMFallbackFixture.image.archiveSHA512)
        #expect(SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined() == VMFallbackFixture.image.assetPin?.sha256)
        let requests = VMFallbackFixture.state.all()
        #expect(requests.map { $0.url!.host! } == ["github.com", "ghfast.top", "gh-proxy.com", "www.floe-agent.com", "www.floe-agent.com", "www.floe-agent.com"])
        let file = try #require(requests.last)
        #expect(file.value(forHTTPHeaderField: "Range") == "bytes=65536-")
        #expect(file.value(forHTTPHeaderField: "If-Range") == "\"sha256:" + VMFallbackFixture.sha256 + "\"")
        #expect(file.value(forHTTPHeaderField: "Authorization") == "Bearer qualification-opaque-token")
        #expect(requests.dropLast().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Origin") == nil })
    }

    @Test func tlsAndDefiniteRejectionNeverReachMirrorsOrWebsite() async throws {
        for mode in [VMFallbackFixture.Mode.tls, .rejected, .localNetwork] {
            VMFallbackFixture.state.reset(mode)
            let target = try destination(); defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
            do { try await downloader().download(VMFallbackFixture.canonical, to: target, maxBytes: 200_000, onProgress: { _, _ in }); Issue.record("terminal failure accepted") }
            catch let error { #expect(!error.allowsNextSource) }
            #expect(VMFallbackFixture.state.all().count == 1)
        }
    }

    @Test func localFileAndSizeRefusalNeverReachAnotherSource() async throws {
        VMFallbackFixture.state.reset(.body)
        let target = try destination(); defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do { try await downloader().download(VMFallbackFixture.canonical, to: target, maxBytes: 200_000, onProgress: { _, _ in }); Issue.record("local file refusal ignored") }
        catch let error { guard case .localRejection = error else { Issue.record("local error reclassified"); return } }
        #expect(VMFallbackFixture.state.all().count == 1)
        VMFallbackFixture.state.reset(.range)
        do { try await downloader().download(VMFallbackFixture.canonical, to: target, maxBytes: 1, onProgress: { _, _ in }); Issue.record("local size cap ignored") }
        catch let error { guard case .localRejection = error else { Issue.record("size error reclassified"); return } }
        #expect(VMFallbackFixture.state.all().isEmpty)
    }

    @Test func missingOrInvalidSignedPolicyCannotInventMirrorFailures() async throws {
        for value in [LinuxGuestImageMirrorPolicy.unavailable, .init(generation: nil, mirrorIDs: policy.mirrorIDs), .init(generation: 2, mirrorIDs: ["untrusted.invalid"])] {
            VMFallbackFixture.state.reset(.range)
            let target = try destination(); defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
            do { try await downloader(policy: value).download(VMFallbackFixture.canonical, to: target, maxBytes: 200_000, onProgress: { _, _ in }); Issue.record("unavailable policy invented fallback") }
            catch { }
            #expect(VMFallbackFixture.state.all().count == 1)
        }
    }

    @Test func callerCancellationStopsSuspendedRequestWithoutFallback() async throws {
        VMFallbackFixture.state.reset(.suspended)
        let target = try destination(); defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let download = downloader()
        let task = Task { try await download.download(VMFallbackFixture.canonical, to: target, maxBytes: 200_000, onProgress: { _, _ in }) }
        for _ in 0..<100 where VMFallbackFixture.state.all().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(VMFallbackFixture.state.all().count == 1)
        task.cancel()
        do { try await task.value; Issue.record("cancelled request succeeded") }
        catch let error as LinuxGuestImageTransferError { #expect(error == .cancelled) }
        catch { Issue.record("unexpected cancellation error") }
        #expect(VMFallbackFixture.state.all().count == 1)
    }

    @Test func realFifteenSecondSlowObservationIsReportedAfterBothMirrorsFail() async throws {
        VMFallbackFixture.state.reset(.slow)
        let target = try destination(); defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try await downloader().download(VMFallbackFixture.canonical, to: target, maxBytes: 200_000, onProgress: { _, _ in })
        #expect(try Data(contentsOf: target) == VMFallbackFixture.bytes)
        let admission = try #require(VMFallbackFixture.state.all().first { $0.httpMethod == "POST" })
        let data = try #require(admission.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["reason"] as? String == "upstream_slow")
        #expect((body["observation_seconds"] as? Int ?? 0) >= 15)
        #expect(body["received_bytes"] as? Int == 0)
        #expect(body["mirror_failures"] as? [String] == ["ghfast.top", "gh-proxy.com"])
    }

    @Test func wrongRangeOrEtagIsTerminalAndFullResponseResetsOffset() throws {
        let asset = try LinuxGuestImageWebsiteFallback.asset(in: VMFallbackFixture.index(), image: VMFallbackFixture.image)
        let ticket = try LinuxGuestImageWebsiteFallback.ticket(in: VMFallbackFixture.ticket(), asset: asset)
        let url = LinuxGuestImageWebsiteFallback.origin.appendingPathComponent("downloads")
        let bad = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["ETag": ticket.etag, "Content-Length": "65536", "Content-Range": "bytes 0-65535/131072"])!
        #expect(throws: LinuxGuestImageTransferError.self) { try LinuxGuestImageWebsiteFallback.responseOffset(bad, ticket: ticket, requestedOffset: 65_536) }
        let wrongETag = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["ETag": "wrong", "Content-Length": "65536", "Content-Range": "bytes 65536-131071/131072"])!
        #expect(throws: LinuxGuestImageTransferError.self) { try LinuxGuestImageWebsiteFallback.responseOffset(wrongETag, ticket: ticket, requestedOffset: 65_536) }
        let foreign = HTTPURLResponse(url: URL(string: "https://other.invalid/file")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": ticket.etag, "Content-Length": "131072"])!
        #expect(throws: LinuxGuestImageTransferError.self) { try LinuxGuestImageWebsiteFallback.responseOffset(foreign, ticket: ticket, requestedOffset: 0) }
        let full = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": ticket.etag, "Content-Length": "131072"])!
        #expect(try LinuxGuestImageWebsiteFallback.responseOffset(full, ticket: ticket, requestedOffset: 65_536) == 0)
    }
}

@Suite("Execution environment GPU setting availability")
@MainActor
struct ExecutionEnvironmentGPUSettingTests {
    @Test func pickerRequiresInstalledVerifiedQualifiedResidentGPUImage() {
        let cpu = LinuxGuestImage(id: "resident", biosPath: "firmware.fd", qualified: true)
        let gpu = LinuxGuestImage(id: "resident", biosPath: "firmware.fd", qualified: true,
            deviceCapabilities: .init(vulkanGPU: true))
        func status(_ image: LinuxGuestImage?, installed: Bool = true,
                    issue: LinuxImageVerificationIssue? = nil) -> LinuxGuestImageInstallationService.ImageStatus {
            .init(id: "resident", installed: installed, verificationIssue: issue,
                  image: image, distributable: true)
        }
        #expect(!ExecutionEnvironmentView.supportsVerifiedResidentGPU(nil))
        #expect(!ExecutionEnvironmentView.supportsVerifiedResidentGPU(status(cpu)))
        #expect(!ExecutionEnvironmentView.supportsVerifiedResidentGPU(status(gpu, installed: false)))
        #expect(!ExecutionEnvironmentView.supportsVerifiedResidentGPU(status(gpu, issue: .artifactMissing(role: "disk"))))
        #expect(ExecutionEnvironmentView.supportsVerifiedResidentGPU(status(gpu)))
    }
}
#endif
