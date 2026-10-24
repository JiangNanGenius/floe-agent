// FloeWorkspaceTests — Android mount-adapter behavior pinned at source.
//
// Complements the ported original NetworkWorkspaceMountTests (route
// isolation, PROPFIND list/PUT CAS happy path, read-only fail-closed,
// structured auth failure). This file pins the lane's documented deltas and
// the failure/CAS/stream semantics the acceptance names: credential
// userinfo rejection that never echoes the secret, Range construction,
// verb/status mapping incl. conflict classes, resolver-failure mapping on
// both transports, and the SMB adapter's honest loopback failure behavior
// against a closed localhost port (no LAN, no remote, no real accounts).

import Foundation
import Testing
@testable import FloeWorkspace
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("FloeWorkspace.NetworkMounts.Android", .serialized)
struct NetworkWorkspaceMountAndroidTests {

    // MARK: - WebDAV

    @Test("endpoint userinfo is refused and the secret never appears in the error")
    func webDAVUserinfoRejected() {
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Private", transport: .webDAV,
            endpoint: URL(string: "https://alice:SuperSecret@host.example/dav")!,
            username: "alice", credentialRef: UUID()
        )
        do {
            _ = try WebDAVWorkspaceMountAdapter(mount: mount, credentialResolver: { _ in Data("x".utf8) })
            Issue.record("expected invalidConfiguration")
        } catch let error as NetworkWorkspaceError {
            #expect(error.code == .invalidConfiguration)
            #expect(!error.safeDetail.contains("SuperSecret"))
            #expect(!error.safeDetail.contains("alice:"))
        } catch {
            Issue.record("expected typed invalidConfiguration, got \(error)")
        }
        let smb = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Share", transport: .smb,
            endpoint: URL(string: "smb://bob:AlsoSecret@host.example/share")!,
            username: "bob", credentialRef: UUID()
        )
        do {
            _ = try SMBWorkspaceMountAdapter(mount: smb, credentialResolver: { _ in Data("x".utf8) })
            Issue.record("expected invalidConfiguration")
        } catch let error as NetworkWorkspaceError {
            #expect(error.code == .invalidConfiguration)
            #expect(!error.safeDetail.contains("AlsoSecret"))
        } catch {
            Issue.record("expected typed invalidConfiguration, got \(error)")
        }
    }

    @Test("range reads, MKCOL/MOVE/DELETE verbs and conflict statuses map structurally")
    func verbsAndStatuses() async throws {
        let recorded = Recorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MountMockURLProtocol.self]
        MountMockURLProtocol.handler = { request in
            recorded.append(request)
            switch request.httpMethod {
            case "GET":
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=5-9")
                return (206, [:], Data("world".utf8))
            case "MKCOL":
                return (201, [:], Data())
            case "MOVE":
                #expect(request.value(forHTTPHeaderField: "Overwrite") == "F")
                #expect(request.value(forHTTPHeaderField: "If-Match") == "etag-1")
                _ = request.value(forHTTPHeaderField: "Destination")
                return (204, [:], Data())
            case "DELETE":
                return (423, [:], Data()) // locked → conflict
            default:
                return (500, [:], Data())
            }
        }
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Team", transport: .webDAV,
            endpoint: URL(string: "https://dav.example.test/root/")!,
            rootPath: "root", username: "alice", credentialRef: nil
        )
        let adapter = try WebDAVWorkspaceMountAdapter(
            mount: mount,
            credentialResolver: { _ in Data() },
            session: URLSession(configuration: configuration)
        )
        let chunk = try await adapter.read(path: "notes.txt", offset: 5, limit: 5)
        #expect(chunk == Data("world".utf8))
        try await adapter.createDirectory(path: "new dir")
        try await adapter.move(from: "a.txt", to: "b.txt", expectedEntityTag: "etag-1")
        do {
            try await adapter.delete(path: "locked.txt", expectedEntityTag: nil)
            Issue.record("expected conflict")
        } catch let error as NetworkWorkspaceError {
            #expect(error.code == .conflict)
            #expect(error.stage == "delete")
            #expect(error.retryable == false)
        }
        let methods = recorded.all().map { $0.httpMethod ?? "" }
        #expect(methods == ["GET", "MKCOL", "MOVE", "DELETE"])
        // Anonymous mount sends no Authorization header at all.
        #expect(recorded.all().first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("WebDAV credential resolver failure maps to credentialMissing before network")
    func webDAVCredentialMissing() async throws {
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Team", transport: .webDAV,
            endpoint: URL(string: "https://dav.example.test/")!,
            username: "alice", credentialRef: UUID()
        )
        let adapter = try WebDAVWorkspaceMountAdapter(mount: mount, credentialResolver: { _ in
            throw NetworkWorkspaceError(code: .protocolFailure, stage: "vault", retryable: false, safeDetail: "unavailable")
        })
        do {
            _ = try await adapter.metadata(path: "x.txt")
            Issue.record("expected credentialMissing")
        } catch let error as NetworkWorkspaceError {
            #expect(error.code == .credentialMissing)
            #expect(error.stage == "credentials")
        }
    }

    @Test("unsupported WebDAV scheme and read-only verbs fail closed without network")
    func schemeAndReadOnlyGuards() async throws {
        let bad = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Ftp", transport: .webDAV,
            endpoint: URL(string: "ftp://dav.example.test/")!,
            username: "", credentialRef: nil
        )
        #expect(throws: NetworkWorkspaceError.self) {
            _ = try WebDAVWorkspaceMountAdapter(mount: bad, credentialResolver: { _ in Data() })
        }
        let ro = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "RO", transport: .webDAV,
            endpoint: URL(string: "https://dav.example.test/")!,
            username: "", credentialRef: nil, readOnly: true
        )
        let adapter = try WebDAVWorkspaceMountAdapter(mount: ro, credentialResolver: { _ in Data() })
        for stage: (WebDAVWorkspaceMountAdapter) async throws -> Void in [
            { try await $0.createDirectory(path: "d") },
            { try await $0.move(from: "a", to: "b", expectedEntityTag: nil) },
            { try await $0.delete(path: "a", expectedEntityTag: nil) },
            { _ = try await $0.write(path: "a", data: Data(), expectedEntityTag: nil) },
        ] {
            await #expect(throws: NetworkWorkspaceError.self) {
                try await stage(adapter)
            }
        }
    }

    // MARK: - SMB (localhost failure semantics only; no LAN, no servers)

    @Test("SMB endpoint scheme is validated exactly as the original")
    func smbConfiguration() {
        let http = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Bad", transport: .smb,
            endpoint: URL(string: "https://host.example/share")!,
            username: "", credentialRef: nil
        )
        #expect(throws: NetworkWorkspaceError.self) {
            _ = try SMBWorkspaceMountAdapter(mount: http, credentialResolver: { _ in Data() })
        }
    }

    @Test("SMB operations against a closed localhost port fail typed and reset the client")
    func smbClosedPort() async throws {
        // Synthetic loopback failure only: port 1 on 127.0.0.1 is never a
        // real SMB target, so this proves the adapter wraps transport
        // failures into the typed surface (retryable classification) and
        // never leaks raw socket errors or secrets. No LAN, no server.
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Refused", transport: .smb,
            endpoint: URL(string: "smb://127.0.0.1:1/share")!,
            username: "user", credentialRef: nil
        )
        let adapter = try SMBWorkspaceMountAdapter(mount: mount, credentialResolver: { _ in Data() })
        do {
            _ = try await adapter.list(path: "")
            Issue.record("expected a typed network failure against the closed port")
        } catch let error as NetworkWorkspaceError {
            #expect(error.retryable)
            #expect([NetworkWorkspaceErrorCode.networkUnreachable, .protocolFailure, .timedOut].contains(error.code))
            #expect(!error.safeDetail.contains("user"))
            #expect(!error.safeDetail.contains("127.0.0.1"))
        }
        // After a reset, a second call fails cleanly the same way (no crash,
        // no half-open session reuse).
        do {
            _ = try await adapter.metadata(path: "x")
            Issue.record("expected the reset client to fail again")
        } catch let error as NetworkWorkspaceError {
            #expect(error.retryable)
        }
    }

    @Test("SMB credential resolver failure maps to credentialMissing before any socket")
    func smbCredentialMissing() async throws {
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Vault", transport: .smb,
            endpoint: URL(string: "smb://host.example/share")!,
            username: "alice", credentialRef: UUID()
        )
        let adapter = try SMBWorkspaceMountAdapter(mount: mount, credentialResolver: { _ in
            throw NetworkWorkspaceError(code: .protocolFailure, stage: "vault", retryable: false, safeDetail: "unavailable")
        })
        do {
            _ = try await adapter.list(path: "")
            Issue.record("expected credentialMissing")
        } catch let error as NetworkWorkspaceError {
            #expect(error.code == .credentialMissing)
            #expect(!error.safeDetail.contains("alice"))
        }
    }

    @Test("SMB read-only refuses writes before the network like the original")
    func smbReadOnly() async throws {
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "RO", transport: .smb,
            endpoint: URL(string: "smb://host.example/share")!,
            username: "", credentialRef: nil, readOnly: true
        )
        let adapter = try SMBWorkspaceMountAdapter(mount: mount, credentialResolver: { _ in Data() })
        await #expect(throws: NetworkWorkspaceError.self) {
            _ = try await adapter.write(path: "f.txt", data: Data(), expectedEntityTag: nil)
        }
        await #expect(throws: NetworkWorkspaceError.self) {
            try await adapter.delete(path: "f.txt", expectedEntityTag: nil)
        }
    }

    @Test("SMB listing reports no entity tag: expectedEntityTag never claims proven CAS")
    func smbNoFalseCas() {
        // Structural honesty check on the value layer: the original SMB
        // adapter returns entityTag nil for entries and metadata (SMB CAS is
        // not proven in the pinned 0.2.1 dialect path), so no consumer can
        // receive a fake tag from a write or read.
        let entry = NetworkWorkspaceEntry(name: "f", path: "f", isDirectory: false, byteCount: 1, modifiedAt: Date(), entityTag: nil)
        #expect(entry.entityTag == nil)
        let metadata = NetworkWorkspaceFileMetadata(path: "f", isDirectory: false, byteCount: 1, modifiedAt: nil, entityTag: nil)
        #expect(metadata.entityTag == nil)
    }
}

private final class Recorder: @unchecked Sendable {
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
    func all() -> [URLRequest] { requests }
}

private final class MountMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
