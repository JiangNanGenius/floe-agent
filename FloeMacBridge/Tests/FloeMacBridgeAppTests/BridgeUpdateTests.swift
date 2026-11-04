#if os(macOS)
import Foundation
import Testing
import Sparkle
import CryptoKit
import FloeMacBridgeProtocol
@testable import FloeMacBridgeApp

@MainActor
@Suite("Bridge update admission", .serialized)
struct BridgeUpdateTests {
    @Test("Every owned activity blocks reservation and stale abort cannot reopen a new install")
    func everyActivityAndStaleAbort() throws {
        let gate = BridgeUpdateActivity()
        for kind in [BridgeUpdateActivity.Kind.request, .job, .transfer, .consent, .maintenance] {
            let lease = try gate.begin(kind)
            #expect(gate.reserveInstallationIfIdle() == nil)
            gate.finish(lease)
        }
        let first = try #require(gate.reserveInstallationIfIdle())
        #expect(throws: (any Error).self) { try gate.begin(.request) }
        gate.resume(after: first)
        let second = try #require(gate.reserveInstallationIfIdle())
        gate.resume(after: first)
        #expect(gate.owns(second))
        gate.resume(after: second)
        let request = try gate.begin(.request); gate.finish(request)
    }
    @Test("Deferred handler runs once only after both transfer and accepted reply finish")
    func noEarlyInstallation() throws {
        let gate = BridgeUpdateActivity()
        let coordinator = BridgeUpdateInstallation(activity: gate, polling: false)
        let transfer = try gate.begin(.transfer), reply = try gate.begin(.request)
        var calls = 0
        coordinator.postpone { calls += 1 }
        #expect(calls == 0)
        #expect(!coordinator.tryPendingInstallation())
        gate.finish(transfer)
        #expect(!coordinator.tryPendingInstallation())
        gate.finish(reply)
        #expect(coordinator.tryPendingInstallation())
        #expect(calls == 1)
        #expect(!coordinator.tryPendingInstallation())
        #expect(throws: (any Error).self) { try gate.begin(.job) }
        coordinator.abort()
        let next = try gate.begin(.job); gate.finish(next)
    }
    @Test("Abort drops stale pending callback and a second Sparkle callback retains the fence")
    func abortAndSecondCallback() throws {
        let gate = BridgeUpdateActivity()
        let owner = BridgeUpdateInstallation(activity: gate, polling: false)
        var old = 0, replacement = 0
        owner.postpone { old += 1 }; owner.abort()
        #expect(!owner.tryPendingInstallation()); #expect(old == 0)
        owner.postpone { replacement += 1 }
        #expect(owner.tryPendingInstallation())
        owner.postpone { replacement += 1 }
        #expect(throws: (any Error).self) { try gate.begin(.transfer) }
        #expect(owner.tryPendingInstallation()); #expect(replacement == 2)
        owner.abort()
        let transfer = try gate.begin(.transfer); gate.finish(transfer)
    }
    @Test("Main actor suspension cannot admit a job across a reserved idle check")
    func actorReentryCannotSlipThrough() async throws {
        let gate = BridgeUpdateActivity()
        let owner = BridgeUpdateInstallation(activity: gate, polling: false)
        #expect(owner.reserveForTerminationIfIdle())
        let rejected = await Task.detached {
            do { _ = try gate.begin(.job); return false } catch { return true }
        }.value
        #expect(rejected)
        owner.abort()
        let admitted = await Task.detached {
            do { let token = try gate.begin(.job); gate.finish(token); return true } catch { return false }
        }.value
        #expect(admitted)
    }
    @Test("Real PTY lifetime blocks installation through output and result persistence")
    func actualJobBlocksInstall() async throws {
        let base = ProcessInfo.processInfo.environment["FLOE_BRIDGE_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("bridge-update-job-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try BridgePaths(home: root), gate = BridgeUpdateActivity()
        let jobs = BridgeJobs(paths: paths, updateActivity: gate)
        let id = UUID().uuidString
        do {
            _ = try await jobs.start(id: id, clientID: "update-fixture", workspaceID: "fixture",
                command: "printf 'update-fixture'; sleep 0.15", cwd: root, environment: [:], columns: 80, rows: 24)
            #expect(gate.reserveInstallationIfIdle() == nil)
            let deadline = Date().addingTimeInterval(5)
            while gate.activityCount != 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(gate.activityCount == 0)
            let token = try #require(gate.reserveInstallationIfIdle())
            let task = try paths.managed("Tasks", id: id)
            let output = try String(contentsOf: task.appendingPathComponent("output.bin"), encoding: .utf8)
            #expect(output.contains("update-fixture"))
            #expect(FileManager.default.fileExists(atPath: task.appendingPathComponent("result.json").path))
            do {
                _ = try await jobs.start(id: UUID().uuidString, clientID: "update-fixture", workspaceID: "fixture",
                    command: "exit 0", cwd: root, environment: [:], columns: 80, rows: 24)
                Issue.record("Job crossed update reservation")
            } catch { /* expected real admission refusal */ }
            gate.resume(after: token)
        } catch {
            await jobs.stopAllAndWait(); throw error
        }
        await jobs.stopAllAndWait()
    }
    @Test("Failed real job admission releases its lease")
    func failedJobStartRestoresIdle() async throws {
        let base = ProcessInfo.processInfo.environment["FLOE_BRIDGE_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("bridge-update-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity(), jobs = BridgeJobs(paths: try BridgePaths(home: root), updateActivity: gate)
        do {
            _ = try await jobs.start(id: "invalid", clientID: "fixture", workspaceID: "fixture", command: "exit 0", cwd: root, environment: [:], columns: 80, rows: 24)
            Issue.record("Invalid job ID succeeded")
        } catch {}
        #expect(gate.activityCount == 0)
        let permit = try #require(gate.reserveInstallationIfIdle()); gate.resume(after: permit)
    }
    @Test("Real signed file transfer and accepted mutation stay fenced through reply delivery")
    func actualTransferAndReply() async throws {
        let base = ProcessInfo.processInfo.environment["FLOE_BRIDGE_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("bridge-update-transfer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try BridgePaths(home: root), gate = BridgeUpdateActivity()
        // Public synthetic fixture bytes, never the user's Bridge/Sparkle keys.
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x41, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let clientID = BridgeWire.digest(client.publicKey.rawRepresentation)
        let pairs = [clientID: BridgeService.Pair(key: client.publicKey.rawRepresentation, name: "Fixture", acceptedAt: Date(), verification: nil, nonce: nil)]
        try BridgeWire.encode(pairs).write(to: paths.root.appendingPathComponent("State/paired-clients.json"))
        let service = try BridgeService(paths: paths, updateActivity: gate, signingKey: server)
        func request(_ method: String, _ payload: [String: BridgeValue]) throws -> BridgeRequest {
            try BridgeRequest(body: BridgeRequestBody(clientKey: client.publicKey.rawRepresentation, method: method, payload: payload), key: client)
        }
        let begin = try request("file.begin", ["workspaceID": .string("fixture"), "path": .string("result.txt")])
        let began = try await service.respondForDelivery(begin)
        let result = try BridgeWire.decode(BridgeResponse.self, from: began.data).verified(for: begin.body, pinnedKey: server.publicKey.rawRepresentation)
        let transferID = try #require(result["transferID"]?.string)
        let accepted = try BridgeWire.decode([String: Int64].self, from: Data(contentsOf: paths.root.appendingPathComponent("State/request-ids.json")))
        #expect(accepted[clientID + ":" + begin.body.id.uuidString] != nil)
        service.finishDelivery(began.lease)
        #expect(gate.activityCount == 1) // Transfer persists between RPCs.
        #expect(service.reserveUpdateInstallationIfIdle() == nil)
        let bytes = Data("actual-transfer-fixture".utf8)
        let chunk = try await service.respondForDelivery(request("file.chunk", ["transferID": .string(transferID), "offset": .integer(0), "data": .string(bytes.base64EncodedString())]))
        service.finishDelivery(chunk.lease)
        let commit = try request("file.commit", ["transferID": .string(transferID), "sha256": .string(BridgeWire.digest(bytes))])
        let committed = try await service.respondForDelivery(commit)
        _ = try BridgeWire.decode(BridgeResponse.self, from: committed.data).verified(for: commit.body, pinnedKey: server.publicKey.rawRepresentation)
        #expect(try Data(contentsOf: paths.root.appendingPathComponent("Workspaces/fixture/result.txt")) == bytes)
        #expect(gate.activityCount == 1) // Committed but HTTP reply not delivered.
        #expect(service.reserveUpdateInstallationIfIdle() == nil)
        service.finishDelivery(committed.lease)
        let token = try #require(service.reserveUpdateInstallationIfIdle())
        do {
            _ = try await service.respondForDelivery(request("ping", [:]))
            Issue.record("RPC crossed service update reservation")
        } catch {}
        gate.resume(after: token)
        let ping = try request("ping", [:])
        let resumed = try await service.respondForDelivery(ping)
        _ = try BridgeWire.decode(BridgeResponse.self, from: resumed.data).verified(for: ping.body, pinnedKey: server.publicKey.rawRepresentation)
        service.finishDelivery(resumed.lease)
        #expect(gate.activityCount == 0)
    }
    @Test("Real pending native consent prevents update and decline restores admission")
    func pendingConsentBlocksInstall() async throws {
        let base = ProcessInfo.processInfo.environment["FLOE_BRIDGE_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("bridge-update-consent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x43, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x44, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        let request = try BridgeRequest(body: BridgeRequestBody(clientKey: client.publicKey.rawRepresentation, method: "pair", payload: ["name": .string("Fixture"), "nonce": .string(String(repeating: "a", count: 64))]), key: client)
        let reply = try await service.respondForDelivery(request)
        let value = try BridgeWire.decode(BridgeResponse.self, from: reply.data).verified(for: request.body, pinnedKey: server.publicKey.rawRepresentation)
        #expect(value["paired"] == .bool(false))
        service.finishDelivery(reply.lease)
        #expect(service.reserveUpdateInstallationIfIdle() == nil)
        try await service.approve(BridgeWire.digest(client.publicKey.rawRepresentation), verification: BridgeWire.pairingVerification(clientKey: client.publicKey.rawRepresentation, serverKey: server.publicKey.rawRepresentation, nonce: String(repeating: "a", count: 64)), allow: false)
        let token = try #require(service.reserveUpdateInstallationIfIdle()); gate.resume(after: token)
    }
    @Test("Official Sparkle postpone, on-quit and abort selectors are implemented")
    func officialDelegateSelectors() {
        let owner = BridgeUpdateInstallation(activity: BridgeUpdateActivity(), polling: false)
        let delegate = BridgeUpdaterDelegate(installation: owner)
        for selector in ["updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                         "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
                         "updater:didAbortWithError:", "updater:didFinishUpdateCycleForUpdateCheck:error:"] {
            #expect(delegate.responds(to: NSSelectorFromString(selector)))
        }
    }
    @Test("Official Kimi manifest permits only matching HTTPS CDN archive paths")
    func kimiManifestValidation() throws {
        let valid = Data(#"{"version":"0.6.8","app":{"url":"https://cdn.kimi.com/kimi-computer-use/0.6.8/KimiCU.app.zip"},"app_x86_64":{"url":"https://cdn.kimi.com/kimi-computer-use/0.6.8/KimiCU-x86_64.app.zip"}}"#.utf8)
        #expect(try BridgeConfiguration.kimiCUDownloadURL(from: valid, intel: false).lastPathComponent == "KimiCU.app.zip")
        #expect(try BridgeConfiguration.kimiCUDownloadURL(from: valid, intel: true).lastPathComponent == "KimiCU-x86_64.app.zip")
        for rejected in ["http://cdn.kimi.com", "https://cdn.kimi.com.evil.invalid", "https://user@cdn.kimi.com"] {
            let changed = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "https://cdn.kimi.com", with: rejected).utf8)
            #expect(throws: (any Error).self) { try BridgeConfiguration.kimiCUDownloadURL(from: changed, intel: false) }
        }
    }
}
#endif
