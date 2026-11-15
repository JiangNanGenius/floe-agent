import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeWorkspace

@Suite("FloeWorkspace.NetworkMounts", .serialized)
struct NetworkWorkspaceMountTests {
    @Test("Independent workspace browsers cannot replace or unregister task mount routes")
    func isolatedRegistries() async throws {
        let root = URL(fileURLWithPath: "/tmp/workspace-route-fixture")
        let taskRegistry = NetworkWorkspaceMountRegistry()
        let browserRegistry = NetworkWorkspaceMountRegistry()
        let taskMount = NetworkWorkspaceMount(workspaceID: UUID(), name: "Files", transport: .webDAV,
            endpoint: try #require(URL(string: "https://task.example.test/")), username: "", credentialRef: nil)
        let browserMount = NetworkWorkspaceMount(workspaceID: UUID(), name: "Files", transport: .webDAV,
            endpoint: try #require(URL(string: "https://browser.example.test/")), username: "", credentialRef: nil)
        await taskRegistry.register(rootURL: root, mounts: [taskMount], credentialResolver: { _ in Data() })
        await browserRegistry.register(rootURL: root, mounts: [browserMount], credentialResolver: { _ in Data() })
        #expect(try await taskRegistry.route(rootURL: root, virtualPath: "Network/Files/doc.pdf")?.mount.id == taskMount.id)
        #expect(try await browserRegistry.route(rootURL: root, virtualPath: "Network/Files/doc.pdf")?.mount.id == browserMount.id)
        await browserRegistry.unregister(rootURL: root)
        #expect(try await taskRegistry.route(rootURL: root, virtualPath: "Network/Files/doc.pdf")?.mount.id == taskMount.id)
    }

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

    @Test("Network copy verifies a complete stable source before writing the destination")
    func copyKeepsExistingTargetOnUnverifiedInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let environment = WorkspaceToolEnvironment(rootProvider: { root }, maxReadBytes: 8, maxWriteBytes: 4)
        let mount = NetworkWorkspaceMount(workspaceID: UUID(), name: "Team", transport: .webDAV,
            endpoint: try #require(URL(string: "https://dav.example.test/")), username: "", credentialRef: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkMockURLProtocol.self]
        let adapter = try WebDAVWorkspaceMountAdapter(mount: mount, credentialResolver: { _ in Data() },
            session: URLSession(configuration: configuration))
        let source = NetworkWorkspaceMountRegistry.Route(mount: mount, relativePath: "source", adapter: adapter)
        let target = NetworkWorkspaceMountRegistry.Route(mount: mount, relativePath: "target", adapter: adapter)
        let copier = WorkspaceCopyFileTool(environment: environment)
        for scenario in ["valid", "empty", "overRead", "overWrite", "truncated", "oversent", "changed", "untaggedChange",
                         "unknownSize", "invalidSize", "unknownType", "directory", "failedProperties"] {
            let prior = Data("existing target".utf8)
            var targetBytes = prior
            var reads = 0, writes = 0, inspections = 0
            let size = ["empty": "0", "overRead": "9", "overWrite": "5", "invalidSize": "n/a"][scenario] ?? "3"
            NetworkMockURLProtocol.handler = { request in
                switch request.httpMethod {
                case "PROPFIND":
                    inspections += 1
                    let type = scenario == "unknownType" ? "" : scenario == "directory"
                        ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:resourcetype/>"
                    let length = scenario == "unknownSize" ? "" : "<d:getcontentlength>\(size)</d:getcontentlength>"
                    let tag = scenario == "changed" && inspections > 1 ? "r2" : "r1"
                    let version = scenario == "untaggedChange" ? "" : "<d:getetag>\(tag)</d:getetag>"
                    let status = scenario == "failedProperties" ? "404 Not Found" : "200 OK"
                    let xml = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/source</d:href><d:propstat><d:prop>" +
                        type + length + version + "</d:prop><d:status>HTTP/1.1 \(status)</d:status></d:propstat></d:response></d:multistatus>"
                    return (207, [:], Data(xml.utf8))
                case "GET":
                    reads += 1
                    if scenario == "empty" { return (416, ["Content-Range": "bytes */0"], Data()) }
                    let bytes = scenario == "truncated" ? "xy" : scenario == "oversent" ? "abcd" :
                        (scenario == "untaggedChange" && reads > 1 ? "xyz" : "abc")
                    return (206, [:], Data(bytes.utf8))
                case "PUT":
                    writes += 1
                    targetBytes = try NetworkMockURLProtocol.body(of: request)
                    return (204, [:], Data())
                default: return (500, [:], Data())
                }
            }
            let succeeds = scenario == "valid" || scenario == "empty"
            do {
                let output = try await copier.copyNetwork(.init(from: "Network/Team/source", to: "Network/Team/target"),
                    from: source, to: target, context: context)
                #expect(succeeds, "\(scenario) must stop before writing")
                #expect(!output.outcomeUnknown)
                #expect(output.summary.hasSuffix(#" paths={"change":"saved","from":"Network/Team/source","kind":"file","path":"Network/Team/target"}"#))
            } catch {
                #expect(!succeeds, "\(scenario) unexpected failure: \(error)")
            }
            #expect(writes == (succeeds ? 1 : 0), "\(scenario)")
            #expect(targetBytes == (succeeds ? Data((scenario == "valid" ? "abc" : "").utf8) : prior), "\(scenario)")
            if ["overRead", "overWrite", "unknownSize", "invalidSize", "unknownType", "directory", "failedProperties"].contains(scenario) {
                #expect(reads == 0, "\(scenario)")
            }
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

    static func body(of request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 64)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }

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
