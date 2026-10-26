// FloeExecutionTests — the verified-wheel seam of the managed inspector.
//
// Locks the production contract the official Skill dependency prefetch needs:
// `fetchVerifiedWheels(specs:)` returns the SAME artifact the existing model-
// review pipeline verifies (PyPI JSON selection of the bounded `*-none-any`
// wheel, HTTPS pythonhosted.org fetch under the byte cap, digest compare,
// full archive audit with native-code refusal), and `inspect` keeps its
// report/digest behavior because it now delegates to that single pipeline.
// The transport seam is the repo's proven stub-URLProtocol pattern: the
// public production entry points still run `URLSession.shared` unchanged and
// no live PyPI request is made by these tests — no second downloader, no new
// trust, caps, index or source.

import Foundation
import Testing
import ZIPFoundation
import FloeCore
@testable import FloeExecution

// MARK: - Stubbed PyPI transport

private final class InspectorStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    // Every access is protected by the static lock below.
    nonisolated(unsafe) private static var routes: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var requested: [String] = []

    static func reset(_ routes: [String: (Int, Data)]) {
        lock.withLock {
            Self.routes = routes
            Self.requested = []
        }
    }
    static var requests: [String] { lock.withLock { requested } }
    fileprivate static func route(for url: URL) -> (Int, Data)? { lock.withLock { routes[url.absoluteString] } }
    fileprivate static func note(_ url: URL) { lock.withLock { requested.append(url.absoluteString) } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return route(for: url) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (status, body) = InspectorStubURLProtocol.route(for: url) else {
            client?.urlProtocol(self, didFailWithError: CocoaError(.fileDoesNotExist))
            return
        }
        InspectorStubURLProtocol.note(url)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeStubSession(_ routes: [String: (Int, Data)]) -> URLSession {
    InspectorStubURLProtocol.reset(routes)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [InspectorStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// A REAL zip archive so the inspector's own ZIPFoundation audit — not a
/// fake marker — decides the outcome. The archive is closed (scope exit)
/// before its bytes are read back.
private func makeWheelBytes(entries: [(String, String)]) throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("stub-wheel-\(UUID().uuidString).whl")
    try { () -> Void in
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in entries {
            try archive.append(path, with: Data(text.utf8))
        }
    }()
    let bytes = try Data(contentsOf: url)
    try? FileManager.default.removeItem(at: url)
    return bytes
}

private func pypiMetadataJSON(wheelURL: String, filename: String, digest: String, size: Int) -> Data {
    let object: [String: Any] = [
        "info": ["summary": "Stub package.", "license": "BSD-3-Clause"],
        "urls": [[
            "packagetype": "bdist_wheel",
            "filename": filename,
            "url": wheelURL,
            "size": size,
            "digests": ["sha256": digest],
        ]],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - Suites

@Suite("FloeExecution.ManagedPythonPackageInspectorWheelSeam", .serialized)
struct ManagedPythonPackageInspectorWheelSeamTests {
    private let spec = "mpmath==1.3.0"
    private let filename = "mpmath-1.3.0-py3-none-any.whl"
    private var metadataURL: String { "https://pypi.org/pypi/mpmath/1.3.0/json" }
    private func wheelURL(_ host: String = "files.pythonhosted.org") -> String {
        "https://\(host)/packages/aa/bb/\(filename)"
    }
    private func pureEntries() -> [(String, String)] {
        [
            ("mpmath/__init__.py", "VERSION = '1.3.0'\ndef double(x):\n    return x * 2\n"),
            ("mpmath-1.3.0.dist-info/METADATA", "Name: mpmath\nVersion: 1.3.0\nLicense: BSD\n"),
        ]
    }

    @Test func reportAndVerifiedBundleDescribeTheSameVerifiedBytes() async throws {
        let bytes = try makeWheelBytes(entries: pureEntries())
        let digest = FloeDigest.sha256Hex(bytes)
        let json = pypiMetadataJSON(wheelURL: wheelURL(), filename: filename, digest: digest, size: bytes.count)
        let routes = [metadataURL: (200, json), wheelURL(): (200, bytes)]

        let bundles = try await ManagedPythonPackageInspector.fetchVerifiedWheels(
            specs: [spec], transport: makeStubSession(routes)
        )
        #expect(bundles.count == 1)
        let bundle = try #require(bundles.first)
        #expect(bundle.spec == spec)
        #expect(bundle.filename == filename)
        #expect(bundle.size == bytes.count)
        #expect(bundle.bytes == bytes)
        #expect(bundle.sha256 == digest)
        #expect(FloeDigest.sha256Hex(bundle.bytes) == bundle.sha256)

        // The report half keeps the artifact/digest identity of the same
        // pipeline (delegation preserved, not re-derived).
        let report = try await ManagedPythonPackageInspector.inspectReport(
            specs: [spec], transport: makeStubSession(routes)
        )
        #expect(report.contains("package=\(spec)"))
        #expect(report.contains("artifact=\(filename)"))
        #expect(report.contains("sha256=\(digest)"))
        #expect(report.contains("license=BSD"))
        #expect(report.contains("files="))
    }

    @Test func digestMismatchFailsBothPathsBeforeAnyBundleIsReturned() async throws {
        let bytes = try makeWheelBytes(entries: pureEntries())
        let wrongDigest = String(repeating: "a", count: 64)
        let json = pypiMetadataJSON(wheelURL: wheelURL(), filename: filename, digest: wrongDigest, size: bytes.count)
        let routes = [metadataURL: (200, json), wheelURL(): (200, bytes)]
        await #expect(throws: (any Error).self, "a PyPI digest that does not match the bytes must refuse") {
            _ = try await ManagedPythonPackageInspector.fetchVerifiedWheels(
                specs: [spec], transport: makeStubSession(routes)
            )
        }
        let session = makeStubSession(routes)
        do {
            _ = try await ManagedPythonPackageInspector.inspectReport(specs: [spec], transport: session)
            Issue.record("report path must refuse the same mismatch")
        } catch let error as FloeError {
            if case .validationFailed(let message) = error {
                #expect(message.contains("digest mismatch"))
            } else { Issue.record("unexpected error shape: \(error)") }
        }
    }

    @Test func nativePayloadIsRefusedWithoutReturningBytes() async throws {
        var entries = pureEntries()
        entries.append(("mpmath/_native.so", "not really an ELF"))
        let bytes = try makeWheelBytes(entries: entries)
        let digest = FloeDigest.sha256Hex(bytes)
        let json = pypiMetadataJSON(wheelURL: wheelURL(), filename: filename, digest: digest, size: bytes.count)
        let routes = [metadataURL: (200, json), wheelURL(): (200, bytes)]
        let session = makeStubSession(routes)
        do {
            let bundles = try await ManagedPythonPackageInspector.fetchVerifiedWheels(
                specs: [spec], transport: session
            )
            Issue.record("native payload must throw, got \(bundles.count) bundle(s)")
        } catch let error as FloeError {
            if case .validationFailed(let message) = error {
                #expect(message.contains("prohibited native code"))
                #expect(message.contains("_native.so"))
            } else { Issue.record("unexpected error shape: \(error)") }
        }
        // The audit refusal applies to the prefetch path exactly as to the
        // review path (same single pipeline).
        await #expect(throws: (any Error).self) {
            _ = try await ManagedPythonPackageInspector.inspectReport(
                specs: [spec], transport: makeStubSession(routes)
            )
        }
    }

    @Test func declaredSizeCapRefusesBeforeDownloadingTheWheel() async throws {
        let bytes = try makeWheelBytes(entries: pureEntries())
        let digest = FloeDigest.sha256Hex(bytes)
        let oversized = 12 * 1_024 * 1024 + 1
        let json = pypiMetadataJSON(wheelURL: wheelURL(), filename: filename, digest: digest, size: oversized)
        let session = makeStubSession([metadataURL: (200, json), wheelURL(): (200, bytes)])
        await #expect(throws: (any Error).self) {
            _ = try await ManagedPythonPackageInspector.fetchVerifiedWheels(specs: [spec], transport: session)
        }
        // The cap fires on PyPI's DECLARED size: the wheel bytes are never
        // requested at all (bounded traffic preserved exactly).
        let requests = InspectorStubURLProtocol.requests
        #expect(requests.contains(metadataURL))
        #expect(!requests.contains(wheelURL()))
    }

    @Test func oversizedDownloadedBodyIsRefusedAfterTransfer() async throws {
        let big = Data(count: 12 * 1_024 * 1024 + 1)
        let digest = FloeDigest.sha256Hex(big)
        // A lie of a declared size cannot smuggle an oversized body past the
        // post-download bound: the download-size guard refuses before any
        // archive is opened or bytes are returned.
        let json = pypiMetadataJSON(wheelURL: wheelURL(), filename: filename, digest: digest, size: 1_024)
        let session = makeStubSession([metadataURL: (200, json), wheelURL(): (200, big)])
        do {
            _ = try await ManagedPythonPackageInspector.fetchVerifiedWheels(specs: [spec], transport: session)
            Issue.record("oversized body must be refused")
        } catch let error as FloeError {
            if case .validationFailed(let message) = error {
                #expect(message.contains("Could not download a bounded wheel"))
            } else { Issue.record("unexpected error shape: \(error)") }
        }
    }

    @Test func nonPyPIHostWheelIsRefusedByTheExistingTrustBoundary() async throws {
        let bytes = try makeWheelBytes(entries: pureEntries())
        let digest = FloeDigest.sha256Hex(bytes)
        let foreign = wheelURL("evil.example.org")
        let json = pypiMetadataJSON(wheelURL: foreign, filename: filename, digest: digest, size: bytes.count)
        let session = makeStubSession([metadataURL: (200, json), foreign: (200, bytes)])
        await #expect(throws: (any Error).self) {
            _ = try await ManagedPythonPackageInspector.fetchVerifiedWheels(specs: [spec], transport: session)
        }
        #expect(!InspectorStubURLProtocol.requests.contains(foreign))
    }
}
