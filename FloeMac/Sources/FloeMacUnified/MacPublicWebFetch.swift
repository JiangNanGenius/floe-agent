// SPDX-License-Identifier: MPL-2.0
import CMacPublicWeb
import Darwin
import Foundation
import FloeCore
import FloeModels
import os
#if FLOE_MAC_HOST_SMOKE
import FloeMacSelfCore
#endif
import FloeTools

/// Read public pages without launching a browser or borrowing its session.
struct MacPublicWebFetch: AgentTool, MacAgentWorkspaceExecutable {
    struct Arguments: Decodable, Sendable {
        var url: String
        var format: WebFetchPage.Format?
        var maxCharacters: Int?
        var startCharacter: Int?
        var timeout: Double?
    }

    static let name = "web.fetch"
    static let toolDescription = "Read a public HTTPS page in the background. Returns status, final URL, title, content type and a page of untrusted website content. Use startCharacter to continue. Requests run without cookies or authentication."
    static let parametersJSON = #"""
    {"type":"object","properties":{"url":{"type":"string","maxLength":8192},"format":{"type":"string","enum":["text","markdown","html","json"]},"maxCharacters":{"type":"integer","minimum":1000,"maximum":200000},"startCharacter":{"type":"integer","minimum":0,"maximum":10000000},"timeout":{"type":"number","minimum":1,"maximum":120}},"required":["url"],"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    static let executionBoundary: ToolExecutionBoundary = .any

    func run(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        guard argumentsJSON.count <= 16_384,
              let args = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any],
              Set(args.keys).isSubset(of: ["url", "format", "maxCharacters", "startCharacter", "timeout"]) else {
            throw FloeError.validationFailed("Use only public page retrieval parameters.")
        }
        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        try validate(arguments)
        return try await execute(arguments, context: context)
    }

    func validate(_ args: Arguments) throws {
        _ = try Self.target(args.url)
        guard (1_000...200_000).contains(args.maxCharacters ?? 80_000),
              (0...10_000_000).contains(args.startCharacter ?? 0),
              (1...120).contains(args.timeout ?? 30) else {
            throw FloeError.validationFailed("Requested page or timeout is outside the supported range.")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try MacTaskWebAccess.validate(Self.descriptor, context: context)
        // getaddrinfo and easy_perform are blocking APIs. Run them off the
        // main actor and Swift's cooperative executor. Cancellation reaches
        // both the redirect loop and libcurl's in-flight transfer callback.
        let token = context.cancellation.derived()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try Self.fetch(args, token: token) })
                }
            }
        } onCancel: { token.cancel() }
    }

    private static func target(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 8_192, !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              !host.contains("%"), !host.hasSuffix("."),
              !["localhost", "local", "internal", "lan", "home"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              (1...65_535).contains(url.port ?? 443) else {
            throw FloeError.validationFailed("A public HTTPS URL without embedded credentials is required.")
        }
        return url
    }

    private struct Hop {
        var status: Int
        var body: String
        var mime: String
        var redirect: String?
        var truncated: Bool
    }

    private static let resolverQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.floeagent.public-web.dns"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    /// A synchronous system resolver may outlive a timeout. It only returns
    /// numeric addresses; it never initiates an HTTP request. Relinquish the
    /// caller promptly on cancellation, even while the resolver is blocked.
    private static func addresses(for host: String, deadline: ContinuousClock.Instant,
                                  token: CancellationToken) throws -> [String] {
        let result = OSAllocatedUnfairLock<Result<[String], Error>?>(initialState: nil)
        let ready = DispatchSemaphore(value: 0)
        let job = BlockOperation {
            let resolution = Result { try NetworkDestinationPolicy.systemResolve(host) }
            result.withLock { $0 = resolution }
            ready.signal()
        }
        resolverQueue.addOperation(job)
        defer { job.cancel() }
        repeat {
            try token.throwIfCancelled()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        } while ready.wait(timeout: .now() + .milliseconds(80)) == .timedOut
        guard let resolved = result.withLock({ $0 }) else { throw URLError(.cannotFindHost) }
        return try resolved.get()
    }

    private static func fetch(_ args: Arguments, token: CancellationToken) throws -> ToolExecutionOutput {
        let maxCharacters = args.maxCharacters ?? 80_000
        let capacity = min(1_048_576, max(8_192, maxCharacters * 8 + 16_384))
        let deadline = ContinuousClock.now + .milliseconds(Int64((args.timeout ?? 30) * 1_000))
        var url = try target(args.url)
        for hop in 0...5 {
            try token.throwIfCancelled()
            let hostname = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let addresses = try addresses(for: hostname, deadline: deadline, token: token)
            // Validate the same answers used for the socket. Letting a second
            // system lookup choose an endpoint after policy review creates a race.
            try NetworkDestinationPolicy.validate(host: hostname, allowTransientTunnel: false) { _ in addresses }
            // Exclude translated, transition, scoped, and special-use IPv6
            // destinations. Only a native global-unicast address can be pinned.
            guard addresses.allSatisfy(acceptsRoute) else {
                throw FloeError.validationFailed("Only publicly routable HTTPS destinations are supported.")
            }
            let response = try request(url, addresses: addresses, capacity: capacity, deadline: deadline, token: token)
            if let next = response.redirect, [301, 302, 303, 307, 308].contains(response.status) {
                guard hop < 5 else { throw FloeError.validationFailed("The page redirected too many times.") }
                url = try target(next)
                continue
            }
            return try WebFetchPage.output(body: response.body, statusCode: response.status,
                                           contentType: response.mime, url: url.absoluteString,
                                           truncated: response.truncated, format: args.format ?? .text,
                                           startCharacter: args.startCharacter ?? 0, maxCharacters: maxCharacters)
        }
        throw FloeError.validationFailed("The page redirected too many times.")
    }

    private static func acceptsRoute(_ numeric: String) -> Bool {
        guard numeric.contains(":") else { return !numeric.hasPrefix("192.88.99.") }
        var address = in6_addr()
        guard inet_pton(AF_INET6, numeric, &address) == 1 else { return false }
        return withUnsafeBytes(of: address) { bytes in
            bytes[0] & 0xe0 == 0x20
                && !(bytes[0] == 0x20 && bytes[1] == 0x02)
                && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2)
        }
    }

    private static func request(_ url: URL, addresses: [String], capacity: Int, deadline: ContinuousClock.Instant,
                                token: CancellationToken) throws -> Hop {
        for address in addresses {
            try token.throwIfCancelled()
            let duration = ContinuousClock.now.duration(to: deadline).components
            let millis = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
            guard millis > 0 else { throw URLError(.timedOut) }
            let socketAddress = address.contains(":") ? "[\(address)]" : address
            let pin = "::\(socketAddress):\(url.port ?? 443)"
            var transfer = FloeWebTransfer()
            transfer.capacity = capacity
            transfer.cancelContext = Unmanaged.passUnretained(token).toOpaque()
            transfer.isCancelled = { context in
                guard let context else { return 1 }
                return Unmanaged<CancellationToken>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
            }
            defer { free(transfer.mime); free(transfer.redirect) }
            var data = Data(count: capacity)
            let code = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                transfer.bytes = buffer.bindMemory(to: UInt8.self).baseAddress
                return floe_web_get(url.absoluteString, pin, millis, &transfer)
            }
            try token.throwIfCancelled()
            if code == CURLE_COULDNT_CONNECT { continue }
            guard code == CURLE_OK, transfer.status > 0 else {
                throw FloeError.validationFailed("Could not read the HTTPS page (network error \(code.rawValue)).")
            }
            let content = String(decoding: data.prefix(transfer.length), as: UTF8.self)
            return Hop(status: transfer.status, body: content, mime: transfer.mime.map { String(cString: $0) } ?? "",
                       redirect: transfer.redirect.map { String(cString: $0) }, truncated: transfer.truncated != 0)
        }
        throw URLError(.cannotConnectToHost)
    }
}

#if FLOE_MAC_HOST_SMOKE
extension MacPublicWebFetch {
    /// Run through the production task binding, including the descriptor and
    /// the same executor the model uses. The optional network leg uses IANA's
    /// public example domain with no task content in the request.
    static func verify(binding: FloeMacSelfToolBinding, conversationID: UUID, readPublicPage: Bool) async -> Bool {
        guard binding.allowedToolNames.contains(name),
              let descriptor = binding.executor.descriptor(named: name),
              descriptor.executionBoundary == .any, descriptor.effect == .readOnly else { return false }
        let token = CancellationToken()
        let context = ToolContext(runID: UUID(), scope: .local, workspaceRootURL: binding.boundary.workspaceRootURL,
                                  cancellation: token, conversationID: conversationID)
        func invoke(_ arguments: [String: String], asChild: Bool = false, removeHandoff: Bool = false) async throws -> ToolResult {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            let call = try ToolCall(id: UUID().uuidString, toolName: name, argumentsJSON: data, scope: .local)
            var caller = asChild ? MacSearchSmoke.childFixture(context: context, descriptor: descriptor, callID: call.id) : context
            if removeHandoff { caller.childExecution = nil }
            return try await binding.executor.execute(call, context: caller)
        }
        do {
            for parameters in [["url": "file:///etc/hosts"], ["url": "https://127.0.0.1/"],
                               ["url": "https://user@example.com/"], ["url": "https://example.com/", "cookieContext": "browser"]] {
                guard try await invoke(parameters).status != .ok else { return false }
            }
            let address = ["url": "https://example.com/", "format": "text"]
            let child = MacSearchSmoke.childFixture(context: context, descriptor: descriptor, callID: "fetch-probe")
            try MacTaskWebAccess.validate(descriptor, context: child)
            guard try await invoke(address, asChild: true, removeHandoff: true).status != .ok else { return false }
            guard readPublicPage else { return true }
            for asChild in [false, true] {
                let page = try await invoke(address, asChild: asChild)
                guard page.status == .ok, let json = try JSONSerialization.jsonObject(with: Data(page.outputSummary.utf8)) as? [String: Any],
                      json["statusCode"] as? Int == 200, json["title"] as? String == "Example Domain",
                      (json["text"] as? String)?.contains("Example Domain") == true else { return false }
            }
            return true
        } catch { return false }
    }
}
#endif
