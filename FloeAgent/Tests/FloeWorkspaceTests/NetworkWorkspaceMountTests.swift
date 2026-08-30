import Foundation
import Testing
@testable import FloeWorkspace

@Suite("FloeWorkspace.NetworkMounts", .serialized)
struct NetworkWorkspaceMountTests {
    @Test("WebDAV adapter lists, reads and conditionally writes without persisting a secret")
    func webDAVOperations() async throws {
        let endpoint = try #require(URL(string: "https://dav.example.test/root/"))
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(),
            name: "Team",
            transport: .webDAV,
            endpoint: endpoint,
            username: "alice",
            credentialRef: UUID()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        NetworkMockURLProtocol.handler = { request in
            switch request.httpMethod {
            case "PROPFIND" where request.value(forHTTPHeaderField: "Depth") == "1":
                let xml = """
                <?xml version="1.0"?>
                <d:multistatus xmlns:d="DAV:">
                  <d:response><d:href>/root/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
                  <d:response><d:href>/root/notes.txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>5</d:getcontentlength><d:getetag>v1</d:getetag></d:prop></d:propstat></d:response>
                </d:multistatus>
                """
                return (207, ["Content-Type": "application/xml"], Data(xml.utf8))
            case "GET":
                return (200, [:], Data("hello".utf8))
            case "PUT":
                #expect(request.value(forHTTPHeaderField: "If-Match") == "v1")
                #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
                return (204, ["ETag": "v2"], Data())
            default:
                return (500, [:], Data())
            }
        }
        let adapter = try WebDAVWorkspaceMountAdapter(
            mount: mount,
            credentialResolver: { _ in Data("password".utf8) },
            session: session
        )
        let entries = try await adapter.list(path: "")
        #expect(entries.map(\.name) == ["notes.txt"])
        #expect(try await adapter.read(path: "notes.txt", offset: 0, limit: 5) == Data("hello".utf8))
        let written = try await adapter.write(path: "notes.txt", data: Data("world".utf8), expectedEntityTag: "v1")
        #expect(written.entityTag == "v2")
        #expect(!String(data: try JSONEncoder().encode(mount), encoding: .utf8)!.contains("password"))
    }

    @Test("read-only network mount rejects writes before network access")
    func readOnlyFailsClosed() async throws {
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Archive", transport: .webDAV,
            endpoint: try #require(URL(string: "https://dav.example.test/")),
            username: "", credentialRef: nil, readOnly: true
        )
        let adapter = try WebDAVWorkspaceMountAdapter(mount: mount, credentialResolver: { _ in Data() })
        await #expect(throws: NetworkWorkspaceError.self) {
            _ = try await adapter.write(path: "file.txt", data: Data(), expectedEntityTag: nil)
        }
    }

    @Test("WebDAV authentication failure is structured and non-retryable")
    func authenticationFailureIsStructured() async throws {
        let mount = NetworkWorkspaceMount(
            workspaceID: UUID(), name: "Private", transport: .webDAV,
            endpoint: try #require(URL(string: "https://dav.example.test/")),
            username: "alice", credentialRef: UUID()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        NetworkMockURLProtocol.handler = { _ in (401, [:], Data()) }
        let adapter = try WebDAVWorkspaceMountAdapter(
            mount: mount,
            credentialResolver: { _ in Data("wrong".utf8) },
            session: session
        )

        do {
            _ = try await adapter.list(path: "")
            Issue.record("Expected authentication failure")
        } catch let error as NetworkWorkspaceError {
            #expect(error.code == .authenticationFailed)
            #expect(error.stage == "list")
            #expect(error.retryable == false)
            #expect(!error.safeDetail.contains("wrong"))
        }
    }
}

private final class NetworkMockURLProtocol: URLProtocol, @unchecked Sendable {
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
