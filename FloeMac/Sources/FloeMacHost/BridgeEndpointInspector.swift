// Floe Mac M00 — read-only inspection of an existing loopback Bridge.
//
// SPDX-License-Identifier: MPL-2.0
//
// When 43871 is already owned, the host never starts, stops, signals or
// rewrites that process. It records the listener PID, executable bundle
// version and real data counts so the user can decide what to do. The
// server identity is not claimed as verified: that needs a paired client key
// that this host deliberately does not have.

import AppKit
import CryptoKit
import Darwin
import FloeMacBridgeProtocol
import Foundation

struct BridgeDataInventory: Codable, Equatable, Sendable {
    var dataRoot: String
    var dataRootExists: Bool
    var pairedClientCount: Int
    var taskCount: Int
    var completedTaskCount: Int
    var unconfirmedTaskCount: Int
    var stateModified: String?
    var note: String
}

struct BridgeEndpointInventory: Codable, Equatable, Sendable {
    var schema: String
    var listening: Bool
    var pid: Int32?
    var executablePath: String?
    var parentPID: Int32?
    var bundleIdentifier: String?
    var version: String?
    var build: String?
    var classification: String
    var data: BridgeDataInventory
    var observedServerKeySHA256: String?
    var identityVerifiedByStoredPairing: Bool
    var identityVerification: String
    var note: String
}

enum BridgeEndpointInspector {
    static func inspect() -> BridgeEndpointInventory {
        let listenerPID = listenerPID()
        let listening = listenerPID != nil || LoopbackProbe.isListening(port: BridgeWire.port)
        var executablePath: String?
        var parentPID: Int32?
        if let listenerPID {
            let process = processInfo(pid: listenerPID)
            executablePath = process.path
            parentPID = process.parent
        }
        let bundle = executablePath.flatMap { enclosingBundle(for: $0) }
        let classification: String
        switch bundle?.bundleIdentifier {
        case .some("org.floeagent.macbridge"): classification = "standaloneFloeBridge"
        case .some("org.floeagent.mac.bridgecomponent"): classification = "embeddedFloeBridge"
        case .some(let identifier): classification = "other:\(identifier)"
        case .none: classification = listening ? "unknownListener" : "none"
        }
        let observedKey = listening ? observedServerKey() : nil
        let observedFingerprint = observedKey.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let verifiedByPairing = observedKey.map { storedPairingMatches(serverKey: $0) } ?? false
        let verification: String
        if let observedFingerprint {
            if verifiedByPairing {
                verification = "Server key SHA256 \(String(observedFingerprint.prefix(24)))… matches the stored verification of an existing paired client. The listener identity is bound to that pairing; the inspection created no pairing and ran no task or file operation."
            } else {
                verification = "Server key SHA256 \(String(observedFingerprint.prefix(24)))… was observed through a self-signed response, but no stored pairing matched. It is not anchored to a trusted pin."
            }
        } else if listening {
            verification = "Not verified: the listener did not return a verifiable signed response. The process and data were inspected read-only."
        } else {
            verification = "No listener."
        }
        return BridgeEndpointInventory(
            schema: "floe-mac-bridge-endpoint-v1",
            listening: listening,
            pid: listenerPID,
            executablePath: executablePath,
            parentPID: parentPID,
            bundleIdentifier: bundle?.bundleIdentifier,
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            classification: classification,
            data: inventory(),
            observedServerKeySHA256: observedFingerprint,
            identityVerifiedByStoredPairing: verifiedByPairing,
            identityVerification: verification,
            note: listening
                ? "The listener was not started, stopped, signaled or modified by this inspection."
                : "Port 43871 is free."
        )
    }

    static func listenerPID() -> Int32? {
        let output = HostShell.run("/usr/sbin/lsof", [
            "-nP", "-iTCP:\(BridgeWire.port)", "-sTCP:LISTEN", "-Fp"
        ])
        for line in output.split(separator: "\n") where line.hasPrefix("p") {
            if let pid = Int32(line.dropFirst()) { return pid }
        }
        return nil
    }

    static func inventory() -> BridgeDataInventory {
        let root = UserBridgeGuard.userBridgeRoot
        let exists = FileManager.default.fileExists(atPath: root.path)
        let pairsURL = root.appendingPathComponent("State/paired-clients.json", isDirectory: false)
        let pairCount: Int
        if FileManager.default.fileExists(atPath: pairsURL.path) {
            if let data = try? Data(contentsOf: pairsURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                pairCount = object.count
            } else {
                pairCount = -1
            }
        } else {
            pairCount = 0
        }
        let tasksRoot = root.appendingPathComponent("Tasks", isDirectory: true)
        let taskDirectories = (try? FileManager.default.contentsOfDirectory(
            at: tasksRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var taskCount = 0
        var completed = 0
        var unconfirmed = 0
        for task in taskDirectories {
            guard let values = try? task.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            taskCount += 1
            let owner = task.appendingPathComponent("owner.json")
            let result = task.appendingPathComponent("result.json")
            if FileManager.default.fileExists(atPath: result.path) {
                completed += 1
            } else if FileManager.default.fileExists(atPath: owner.path) {
                unconfirmed += 1
            }
        }
        let state = root.appendingPathComponent("State", isDirectory: true)
        let attributes = try? FileManager.default.attributesOfItem(atPath: state.path)
        let modified = (attributes?[.modificationDate] as? Date).map {
            ISO8601DateFormatter().string(from: $0)
        }
        return BridgeDataInventory(
            dataRoot: root.path,
            dataRootExists: exists,
            pairedClientCount: pairCount,
            taskCount: taskCount,
            completedTaskCount: completed,
            unconfirmedTaskCount: unconfirmed,
            stateModified: modified,
            note: "Read-only counts. 'Unconfirmed' means an owner record exists without a result receipt; it is preserved, not restarted."
        )
    }

    /// Sends one signed, unpaired `ping`. An existing Bridge answers with a
    /// signed error that contains its server key. This proves that key only
    /// against itself, not against a paired client's pin, so the report says
    /// so. It creates no pending pairing and performs no task/file operation.
    private static func observedServerKey() -> Data? {
        do {
            let key = Curve25519.Signing.PrivateKey()
            let body = BridgeRequestBody(
                clientKey: key.publicKey.rawRepresentation,
                method: "ping",
                payload: [:]
            )
            let request = try BridgeRequest(body: body, key: key)
            let payload = try BridgeWire.encode(request)
            let output = HostShell.runWithInput(
                "/usr/bin/curl",
                ["-sS", "-m", "2", "-H", "Content-Type: application/json",
                 "-H", "Host: 127.0.0.1:\(BridgeWire.port)",
                 "--data-binary", "@-", "http://127.0.0.1:\(BridgeWire.port)/rpc"],
                input: payload
            )
            guard !output.isEmpty, let data = output.data(using: .utf8) else { return nil }
            let response = try BridgeWire.decode(BridgeResponse.self, from: data)
            let serverKey = response.body.serverKey
            guard serverKey.count == 32,
                  try Curve25519.Signing.PublicKey(rawRepresentation: serverKey)
                    .isValidSignature(response.signature, for: BridgeWire.encode(response.body)) else {
                return nil
            }
            return serverKey
        } catch {
            return nil
        }
    }

    private struct StoredPair: Decodable {
        var key: Data
        var verification: String?
        var nonce: String?
    }

    /// The existing pair record already contains the pairing verification
    /// computed from the client key, server key and nonce. Matching it against
    /// the observed server key proves the listener is the same identity that
    /// client approved, without reading or using a client private key.
    private static func storedPairingMatches(serverKey: Data) -> Bool {
        let url = UserBridgeGuard.userBridgeRoot
            .appendingPathComponent("State/paired-clients.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let pairs = try? JSONDecoder().decode([String: StoredPair].self, from: data) else {
            return false
        }
        for pair in pairs.values {
            guard pair.key.count == 32,
                  let nonce = pair.nonce,
                  let verification = pair.verification else { continue }
            if BridgeWire.pairingVerification(clientKey: pair.key, serverKey: serverKey, nonce: nonce) == verification {
                return true
            }
        }
        return false
    }

    private static func processInfo(pid: Int32) -> (path: String?, parent: Int32?) {
        let output = HostShell.run("/bin/ps", ["-p", String(pid), "-o", "ppid=,comm="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return (nil, nil) }
        let parts = output.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
        let parent = parts.count == 2 ? Int32(parts[0]) : nil
        let path = parts.count == 2 ? String(parts[1]) : nil
        return (path, parent)
    }

    private static func enclosingBundle(for executablePath: String) -> Bundle? {
        var url = URL(fileURLWithPath: executablePath, isDirectory: false)
        for _ in 0..<6 {
            if url.pathExtension == "app" {
                return Bundle(url: url)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }
}

enum HostShell {
    static func run(_ executable: String, _ arguments: [String]) -> String {
        runWithInput(executable, arguments, input: nil)
    }

    static func runWithInput(_ executable: String, _ arguments: [String], input: Data?) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        if input != nil {
            process.standardInput = Pipe()
        }
        do {
            try process.run()
            if let input, let handle = process.standardInput as? Pipe {
                handle.fileHandleForWriting.write(input)
                try? handle.fileHandleForWriting.close()
            }
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
