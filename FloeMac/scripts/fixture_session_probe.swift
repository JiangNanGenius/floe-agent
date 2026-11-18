// Floe Mac M00 — isolated fixture session probe.
//
// SPDX-License-Identifier: MPL-2.0
//
// Launches the signed helper entry copied into a coordinator-created mkdtemp
// root, verifies the authenticated control channel and pinned identity, runs a
// real PTY task through the paired RPC path, checks child-shell sandbox
// inheritance, exercises stop admission, then stops only the owned process.
// It never reads the real Bridge data or Keychain.

import CryptoKit
import Darwin
import Foundation
import Security
import FloeMacBridgeProtocol

private struct ProbeReady: Decodable {
    var schema: String?
    var state: String
    var port: Int?
    var pid: Int32?
    var parentPID: Int32?
    var storageRoot: String?
    var workerHome: String?
    var controlSocket: String?
    var identitySource: String?
    var identityFingerprintSHA256: String?
    var listenerScope: String?
    var message: String?
}

private enum ProbeError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

@main
struct FixtureSessionProbe {
    static func main() async {
        let options: [String: String]
        do {
            options = try parse(CommandLine.arguments)
        } catch {
            print("{\"schema\":\"floe-mac-fixture-session-probe-v1\",\"passed\":false,\"error\":\"\(escape(error.localizedDescription))\"}")
            exit(2)
        }
        guard let rootPath = options["--root"], let executablePath = options["--entry-executable"] else {
            print("{\"schema\":\"floe-mac-fixture-session-probe-v1\",\"passed\":false,\"error\":\"--root and --entry-executable are required\"}")
            exit(2)
        }
        let root = URL(fileURLWithPath: canonicalPath(rootPath), isDirectory: true)
        let executable = URL(fileURLWithPath: executablePath, isDirectory: false)
        let jsonOut = options["--json-out"].map { URL(fileURLWithPath: $0, isDirectory: false) }
        let result = await run(root: root, executable: executable)
        let data = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys, .prettyPrinted]
        )
        if let data, let text = String(data: data, encoding: .utf8) {
            print(text)
            if let jsonOut { try? data.write(to: jsonOut, options: [.atomic]) }
        }
        let passed = result["passed"] as? Bool ?? false
        exit(passed ? 0 : 1)
    }

    private static func run(root: URL, executable: URL) async -> [String: Any] {
        let controlRoot = root.appendingPathComponent("Control", isDirectory: true)
        let workerHome = root.appendingPathComponent("worker-home", isDirectory: true)
        let tempDirectory = root.appendingPathComponent("tmp", isDirectory: true)
        let readyURL = controlRoot.appendingPathComponent("ready.json", isDirectory: false)
        let discoveryURL = controlRoot.appendingPathComponent("discovery.json", isDirectory: false)
        let socketURL = controlRoot.appendingPathComponent("b.sock", isDirectory: false)
        let logURL = controlRoot.appendingPathComponent("session.log", isDirectory: false)

        let clientKey = Curve25519.Signing.PrivateKey()
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = root
        process.arguments = [
            "--mode", "test",
            "--test-fixture", root.path,
            "--control-socket", socketURL.path,
            "--ready-file", readyURL.path,
            "--discovery-file", discoveryURL.path,
            "--probe-client-key", clientKey.publicKey.rawRepresentation.base64EncodedString(),
            "--orphan-idle-grace", "2"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = workerHome.path
        environment["CFFIXED_USER_HOME"] = workerHome.path
        environment["TMPDIR"] = tempDirectory.path
        environment["TMP"] = tempDirectory.path
        environment["TEMP"] = tempDirectory.path
        environment["FLOE_M00_FIXTURE_ROOT"] = root.path
        environment["FLOE_M00_REAL_HOME_DIR"] = realHomeDirectory()
        process.environment = environment
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle

        var checks: [String: Bool] = [:]
        var details: [String: Any] = [:]
        var helperPID: Int32 = 0
        var ready: ProbeReady?
        var stoppedCleanly = false
        do {
            try process.run()
            helperPID = process.processIdentifier
            details["helperPID"] = Int(helperPID)
            guard let loaded = try await waitForReady(readyURL, process: process, timeout: 20) else {
                throw ProbeError.message("helper did not become ready")
            }
            ready = loaded
            checks["readyState"] = loaded.state == "ready"
            checks["ephemeralPort"] = (loaded.port ?? 0) > 0 && loaded.port != 43_871
            checks["pidMatches"] = loaded.pid == helperPID
            checks["parentMatches"] = loaded.parentPID == getpid()
            checks["storageInsideRoot"] = loaded.storageRoot?.hasPrefix(root.path + "/") == true
            checks["workerHomeInsideRoot"] = loaded.workerHome == workerHome.path
            checks["identitySource"] = loaded.identitySource == "test-fixture-persistent"
            checks["listenerScope"] = loaded.listenerScope == "127.0.0.1"
            details["port"] = loaded.port ?? 0
            details["storageRoot"] = loaded.storageRoot ?? "missing"
            details["workerHome"] = loaded.workerHome ?? "missing"
            details["identityFingerprint"] = loaded.identityFingerprintSHA256 ?? "missing"

            let discoveryData = try Data(contentsOf: discoveryURL)
            let discovery = try JSONDecoder().decode(BridgeControlDiscovery.self, from: discoveryData)
            checks["discoveryMatches"] = discovery.pid == helperPID && discovery.socket == socketURL.path
            let client = try BridgeControlClient.connect(socketPath: discovery.socket, token: discovery.token)
            defer { client.close() }
            let initial = try await client.request(BridgeControlMessage(kind: .status))
            guard let status = initial.status else { throw ProbeError.message("status was empty") }
            checks["statusReady"] = status.state == "ready"
            checks["statusPortMatches"] = status.port == loaded.port
            checks["statusPidMatches"] = status.pid == helperPID
            checks["storeLockHeld"] = status.storeLockExclusive
            checks["storageIsFixture"] = status.storageRoot.hasPrefix(root.path + "/")
            checks["workerHomeIsFixture"] = status.workerHome == workerHome.path
            checks["noTCCProbe"] = status.screenCaptureAllowed == false && status.accessibilityAllowed == false

            let nonce = randomBytes(32)
            let challenge = try await client.request(BridgeControlMessage(kind: .challenge, nonce: nonce.base64EncodedString()))
            guard let keyText = challenge.publicKeyBase64, let keyData = Data(base64Encoded: keyText),
                  keyData.count == 32, let signatureText = challenge.signatureBase64,
                  let signature = Data(base64Encoded: signatureText) else {
                throw ProbeError.message("identity challenge was incomplete")
            }
            let validSignature = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
                .isValidSignature(signature, for: BridgeControlCodec.identityChallenge(nonce))
            checks["pinnedChallenge"] = validSignature
            checks["fingerprintMatches"] = BridgeControlCodec.fingerprint(keyData) == loaded.identityFingerprintSHA256
            let claim = try await client.request(BridgeControlMessage(kind: .claim))
            checks["claimed"] = claim.status?.hostClaimed == true

            let port = UInt16(loaded.port ?? 0)
            guard port > 0 else { throw ProbeError.message("helper reported no HTTP port") }
            let listener = listenerCheck(pid: helperPID, port: port)
            checks["onlyOwnedLoopbackListener"] = listener.ok
            details["listenerLines"] = listener.text
            let jobID = UUID().uuidString
            let command = """
            printf 'HOME=%s\\n' "$HOME"; \
            printf 'ROOT=%s\\n' "$FLOE_M00_FIXTURE_ROOT"; \
            if test -d "$FLOE_M00_REAL_HOME_DIR"; then printf 'HOME_READ_ALLOWED\\n'; else printf 'HOME_READ_DENIED\\n'; fi; \
            if /usr/bin/nc -z -w 1 1.1.1.1 80 >/dev/null 2>&1; then printf 'NET_ALLOWED\\n'; else printf 'NET_DENIED\\n'; fi; \
            printf 'fixture-file' > m00-session.txt; wc -c < m00-session.txt; sleep 2; printf 'DONE\\n'
            """
            _ = try await signedRPC(port: port, clientKey: clientKey, pinnedKey: keyData,
                                     method: "start", payload: [
                                        "workspaceID": .string("m00session"),
                                        "jobID": .string(jobID),
                                        "command": .string(command),
                                        "environment": .object([
                                            "FLOE_M00_FIXTURE_ROOT": .string(root.path),
                                            "FLOE_M00_REAL_HOME_DIR": .string(realHomeDirectory())
                                        ]),
                                        "columns": .integer(100),
                                        "rows": .integer(30)
                                     ])
            try await Task.sleep(for: .milliseconds(400))
            let active = try await client.request(BridgeControlMessage(kind: .status))
            let activeIDs = active.status?.activeTaskIDs ?? []
            checks["taskActive"] = activeIDs.contains(jobID)
            do {
                _ = try await client.request(BridgeControlMessage(kind: .stop))
                checks["stopRefusedDuringTask"] = false
            } catch {
                checks["stopRefusedDuringTask"] = error.localizedDescription.contains("Stop was refused")
                    && active.status?.state == "ready"
            }

            var output = ""
            var offset: Int64 = 0
            var completed = false
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                let polled = try await signedRPC(port: port, clientKey: clientKey, pinnedKey: keyData,
                                                 method: "poll", payload: [
                                                    "jobID": .string(jobID),
                                                    "offset": .integer(offset),
                                                    "limit": .integer(64 * 1024)
                                                 ])
                if let encoded = polled["data"]?.string, let data = Data(base64Encoded: encoded) {
                    output += String(decoding: data, as: UTF8.self)
                }
                offset = polled["offset"]?.integer ?? offset
                if polled["alive"]?.bool == false { completed = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            checks["taskCompleted"] = completed
            checks["childHomeIsFixture"] = output.contains("HOME=\(workerHome.path)")
            checks["childHomeReadDenied"] = output.contains("HOME_READ_DENIED")
            checks["childExternalNetworkDenied"] = output.contains("NET_DENIED")
            checks["taskOutputDone"] = output.contains("DONE")
            details["taskOutput"] = output
            let fileRead = try await signedRPC(port: port, clientKey: clientKey, pinnedKey: keyData,
                                               method: "file.read", payload: [
                                                "workspaceID": .string("m00session"),
                                                "path": .string("m00-session.txt"),
                                                "offset": .integer(0),
                                                "limit": .integer(1024)
                                               ])
            if let encoded = fileRead["data"]?.string, let data = Data(base64Encoded: encoded) {
                checks["fileRead"] = String(decoding: data, as: UTF8.self) == "fixture-file"
            } else {
                checks["fileRead"] = false
            }

            let stopped = try await client.request(BridgeControlMessage(kind: .stop))
            checks["stopAccepted"] = stopped.error == nil && stopped.status?.state == "stopping"
            await waitForExit(process, timeout: 8)
            stoppedCleanly = !process.isRunning
            checks["helperExited"] = stoppedCleanly
            checks["controlSocketRemoved"] = !FileManager.default.fileExists(atPath: socketURL.path)
            checks["portClosed"] = !portIsOpen(port)
            details["helperExitStatus"] = Int(process.terminationStatus)
        } catch {
            details["error"] = error.localizedDescription
        }

        if process.isRunning {
            process.terminate()
            await waitForExit(process, timeout: 3)
            if process.isRunning, helperPID > 0 {
                kill(helperPID, SIGKILL)
                await waitForExit(process, timeout: 2)
            }
            details["forcedOwnedStop"] = true
        }
        checks["ownedStopOnly"] = true
        try? logHandle?.close()
        let logTail = readTail(logURL, limit: 8_192)
        details["logTail"] = logTail
        details["checks"] = checks
        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 } && stoppedCleanly
        var payload: [String: Any] = [
            "schema": "floe-mac-fixture-session-probe-v1",
            "passed": passed,
            "root": root.path,
            "helperPID": Int(helperPID),
            "ownedStopOnly": true
        ]
        for (key, value) in details { payload[key] = value }
        payload["checks"] = checks
        return payload
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw ProbeError.message("expected --key value, got \(key)")
            }
            result[key] = arguments[index + 1]
            index += 2
        }
        return result
    }

    private static func waitForReady(_ url: URL, process: Process, timeout: TimeInterval) async throws -> ProbeReady? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let ready = try? JSONDecoder().decode(ProbeReady.self, from: data) {
                if ready.state == "ready" { return ready }
                if ready.state == "failed" {
                    throw ProbeError.message("helper reported failed: \(ready.message ?? "no message")")
                }
            }
            if !process.isRunning {
                throw ProbeError.message("helper exited before ready")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func signedRPC(port: UInt16, clientKey: Curve25519.Signing.PrivateKey,
                                  pinnedKey: Data, method: String,
                                  payload: [String: BridgeValue]) async throws -> [String: BridgeValue] {
        let body = BridgeRequestBody(clientKey: clientKey.publicKey.rawRepresentation,
                                     method: method, payload: payload)
        let request = try BridgeRequest(body: body, key: clientKey)
        guard let url = URL(string: "http://127.0.0.1:\(port)/rpc") else {
            throw ProbeError.message("invalid loopback URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 10
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        urlRequest.httpBody = try BridgeWire.encode(request)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProbeError.message("RPC \(method) returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoded = try BridgeWire.decode(BridgeResponse.self, from: data)
        return try decoded.verified(for: request.body, pinnedKey: pinnedKey)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { pointer in
            SecRandomCopyBytes(kSecRandomDefault, count, pointer.baseAddress!)
        }
        return result == errSecSuccess ? data : Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func listenerCheck(pid: Int32, port: UInt16) -> (ok: Bool, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof", isDirectory: false)
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n").dropFirst().map(String.init)
            let onlyLoopback = !lines.isEmpty && lines.allSatisfy {
                $0.contains("127.0.0.1:\(port)") && !$0.contains(":43871") && !$0.contains("*:")
            }
            return (onlyLoopback, text)
        } catch {
            return (false, "lsof failed: \(error.localizedDescription)")
        }
    }

    private static func portIsOpen(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func readTail(_ url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBufferPointer { pointer -> UnsafeMutablePointer<CChar>? in
            realpath(path, pointer.baseAddress)
        }
        guard let resolved, let canonical = String(validatingUTF8: resolved) else { return path }
        return canonical
    }

    private static func realHomeDirectory() -> String {
        if let password = getpwuid(getuid()) {
            let path = String(cString: password.pointee.pw_dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true).path
            }
        }
        return "/Users/\(NSUserName())/"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
