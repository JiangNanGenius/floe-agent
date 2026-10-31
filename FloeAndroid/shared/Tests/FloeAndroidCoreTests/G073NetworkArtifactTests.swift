// SPDX-License-Identifier: MPL-2.0
//
// Authored-only regressions for the G07.3B saved-artifact lane.
// NOT executed by this lane (Main runs the combined batch). The mailbox and
// executor use synthetic bounded replies; no files, store, socket, device,
// credentials or real artifact are touched.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidNetwork
@testable import FloeAndroidCore

final class G073NetworkArtifactTests: XCTestCase {
    private let analysisID = UUID(uuidString: "70000000-0000-4000-8000-000000000007")!
    private let sessionID = UUID(uuidString: "71000000-0000-4000-8000-000000000007")!
    private let operationID = UUID(uuidString: "72000000-0000-4000-8000-000000000007")!
    private let taskID = UUID(uuidString: "73000000-0000-4000-8000-000000000007")!
    private let runID = UUID(uuidString: "74000000-0000-4000-8000-000000000007")!

    private func pcapReply() -> Data {
        Data(#"""
        {"schema":"floe.pcap-tool-summary.v1","version":1,"source":"phone",
         "analysisID":"70000000-0000-4000-8000-000000000007","status":"partial",
         "format":"pcap","privacy":"redacted",
         "totals":{"packets":3,"bytes":240,"flows":2,"retainedFlows":2},
         "matched":{"flows":1,"flowPackets":2,"flowBytes":120},
         "protocols":[{"protocol":"tcp","packets":3,"bytes":240}],
         "flows":[{"protocol":"tcp","ipVersion":4,
           "src":{"address":"ip:abcdef012345","port":12345},
           "dst":{"address":"ip:abcdef012346","port":80},
           "packets":2,"bytes":120,"firstEpochMillis":1700000000000,
           "lastEpochMillis":1700000000500,"tcpFlags":"A"}],
         "dns":[],"http":[],
         "stoppedReason":"timeBudget","cancelled":false,
         "limitations":["Only the parsed prefix is represented."]}
        """#.utf8)
    }

    private func coverageReply() -> Data {
        Data(#"""
        {"schema":"floe.coverage-tool-summary.v1","version":1,"source":"phone",
         "sessionID":"71000000-0000-4000-8000-000000000007","status":"ok",
         "name":"Home","privacy":"redacted","pointCount":1,
         "namedLocations":["Living room"],"hasFloorplan":false,
         "aggregate":{"pointCount":1,"staleCount":0,"permissionRequiredCount":1,
           "cachedScanCount":0,"noSignalCount":0,"unsampledCells":47,
           "rssiMin":-51,"rssiMax":-51,"rssiAverage":-51,"estimatedCoveragePercent":2.08},
         "points":[{"label":"Living room","x":0.5,"y":0.5,"rssiDbm":-51,
           "level":"strong","channel":6,"ageMs":1200,"stale":false,
           "scanStatus":"ok","cachedAgeMs":0,"refreshStatus":"updated",
           "permissionRequired":false,"probe":null}],
         "limitations":["User-sampled points only."]}
        """#.utf8)
    }

    // MARK: - Request / validation

    func testPcapRequestBuildsBoundedTypedFilters() throws {
        let filters = NetworkArtifactFilters(
            protocols: ["UDP", "tcp", "tcp"], services: ["DNS"],
            address: "10.0.0.1", port: 443,
            startEpochMillis: 1_700_000_000_000,
            endEpochMillis: 1_700_000_100_000)
        let request = try NetworkArtifactToolRequest.pcapAnalyze(
            analysisID: analysisID, filters: filters, operationID: operationID)
        XCTAssertEqual(request.method, .pcapAnalyze)
        XCTAssertEqual(request.operationID, operationID)
        XCTAssertLessThanOrEqual(request.requestJSON.count, NetworkArtifactLimits.maximumRequestBytes)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.requestJSON) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["method"] as? String, "network.pcapAnalyze")
        XCTAssertEqual(root["operationID"] as? String, operationID.uuidString)
        let arguments = try XCTUnwrap(root["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["analysisID"] as? String, analysisID.uuidString)
        let encodedFilters = try XCTUnwrap(arguments["filters"] as? [String: Any])
        XCTAssertEqual(encodedFilters["protocols"] as? [String], ["tcp", "udp"])
        XCTAssertEqual(encodedFilters["services"] as? [String], ["dns"])
        XCTAssertEqual(encodedFilters["address"] as? String, "10.0.0.1")
        XCTAssertEqual(encodedFilters["port"] as? Int, 443)
    }

    func testCoverageRequestRequiresUUIDAndRejectsHTTPProbeFields() throws {
        let request = try NetworkArtifactToolRequest.coverageSummary(
            sessionID: sessionID, operationID: operationID)
        XCTAssertEqual(request.method, .coverageSummary)
        XCTAssertLessThanOrEqual(request.requestJSON.count, NetworkArtifactLimits.maximumRequestBytes)
        let tool = NetworkCoverageSummaryTool.Arguments(sessionID: "not-a-uuid")
        XCTAssertThrowsError(try NetworkCoverageSummaryTool(executor: FakeExecuting()).validate(tool))
    }

    func testFilterValidationRefusesUnboundedOrWrongValues() {
        XCTAssertThrowsError(try NetworkArtifactFilters(protocols: ["tcp", "udp", "icmp", "icmpv6", "sctp"])
            .validated())
        XCTAssertThrowsError(try NetworkArtifactFilters(protocols: ["sctp"]).validated())
        XCTAssertThrowsError(try NetworkArtifactFilters(address: "http://example.test/x").validated())
        XCTAssertThrowsError(try NetworkArtifactFilters(port: 0).validated())
        XCTAssertThrowsError(try NetworkArtifactFilters(
            startEpochMillis: 10, endEpochMillis: 5).validated())
    }

    // MARK: - Mailbox

    func testUnboundMailboxRefusesSubmission() async throws {
        let mailbox = G073NetworkArtifactHostMailbox()
        do {
            _ = try await mailbox.submit(
                request: try .pcapAnalyze(analysisID: analysisID),
                owner: G073NetworkArtifactOwner(taskID: taskID, runID: runID, epoch: 1),
                cancellation: CancellationToken())
            XCTFail("unbound mailbox must refuse")
        } catch let error as G073NetworkArtifactTransportError {
            XCTAssertEqual(error, .hostUnbound)
        }
    }

    func testFullClaimRoundTripAndDescriptorCarryWorkspaceFingerprint() async throws {
        let mailbox = G073NetworkArtifactHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 9))
        let fingerprint = String(repeating: "ab", count: 32)
        let owner = G073NetworkArtifactOwner(
            taskID: taskID, runID: runID, epoch: 9,
            workspaceFingerprint: fingerprint)
        let request = try NetworkArtifactToolRequest.pcapAnalyze(
            analysisID: analysisID, operationID: operationID)
        async let reply = mailbox.submit(
            request: request, owner: owner, cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)

        var descriptorBuffer = [CChar](repeating: 0, count: 2_049)
        let descriptorLength = mailbox.describe(
            claim: claim, buffer: &descriptorBuffer, capacity: 2_048)
        XCTAssertGreaterThan(descriptorLength, 0)
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(bytes: descriptorBuffer, count: Int(descriptorLength)))
            as? [String: Any])
        XCTAssertEqual(descriptor["operation"] as? String, "networkArtifact.execute")
        XCTAssertEqual(descriptor["epoch"] as? String, "9")
        XCTAssertEqual(descriptor["method"] as? String, "network.pcapAnalyze")
        XCTAssertEqual(descriptor["taskID"] as? String, taskID.uuidString)
        XCTAssertEqual(descriptor["workspace"] as? String, fingerprint)

        XCTAssertEqual(mailbox.payloadLength(claim: claim), Int32(request.requestJSON.count))
        var payload = [UInt8](repeating: 0, count: request.requestJSON.count)
        XCTAssertEqual(mailbox.takePayload(claim: claim, buffer: &payload,
                                           capacity: Int32(payload.count)),
                       Int32(request.requestJSON.count))
        XCTAssertEqual(Data(payload), request.requestJSON)
        XCTAssertEqual(mailbox.isLive(claim: claim), 1)
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 0)

        let result = pcapReply()
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: result), 0)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: result), -101)
        let delivered = try await reply
        XCTAssertEqual(delivered, result)
    }

    func testRebindFencesWaiterAndStaleClaimCannotSettle() async throws {
        let mailbox = G073NetworkArtifactHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 11))
        let owner = G073NetworkArtifactOwner(taskID: taskID, runID: runID, epoch: 11)
        let sessionID = self.sessionID
        async let reply = mailbox.submit(
            request: try .coverageSummary(sessionID: sessionID), owner: owner,
            cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertTrue(mailbox.bind(epoch: 12))
        do {
            _ = try await reply
            XCTFail("rebind must fence the waiter")
        } catch let error as G073NetworkArtifactTransportError {
            XCTAssertEqual(error, .hostFenced)
        }
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: coverageReply()), -102)
    }

    func testOversizedReplyIsRefusedNotTruncated() async throws {
        let mailbox = G073NetworkArtifactHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 14))
        let owner = G073NetworkArtifactOwner(taskID: taskID, runID: runID, epoch: 14)
        let sessionID = self.sessionID
        async let reply = mailbox.submit(
            request: try .coverageSummary(sessionID: sessionID), owner: owner,
            cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(mailbox.complete(
            claim: claim, status: 0,
            value: Data(repeating: 0x61, count: G073NetworkArtifactHostLimits.maximumReplyBytes + 1)),
            -107)
        XCTAssertEqual(mailbox.complete(
            claim: claim, status: 1, value: Data(#"{"code":"internal"}"#.utf8)), 0)
        do { _ = try await reply } catch is G073NetworkArtifactTransportError {}
    }

    // MARK: - Executor / tools

    func testExecutorRefusesTemporaryChatAndMissingTaskBeforeSubmission() async throws {
        let host = FakeArtifactHost(epoch: 21)
        let executor = G073NetworkArtifactToolExecutor(host: host, currentEpoch: { 21 })
        let request = try NetworkArtifactToolRequest.pcapAnalyze(analysisID: analysisID)
        var context = ToolContext(runID: runID, cancellation: CancellationToken(),
                                  conversationID: taskID)
        context.temporaryReadOnly = true
        do {
            _ = try await executor.execute(request: request, context: context)
            XCTFail("temporary chat must be refused")
        } catch let error as FloeError {
            guard case .validationFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(host.requests.isEmpty)

        context.temporaryReadOnly = false
        let noTask = ToolContext(runID: runID, cancellation: CancellationToken())
        do {
            _ = try await executor.execute(request: request, context: noTask)
            XCTFail("missing task must be refused")
        } catch let error as FloeError {
            guard case .validationFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(host.requests.isEmpty)
    }

    func testExecutorBindsTaskRunEpochAndWorkspaceThenReturnsReply() async throws {
        let host = FakeArtifactHost(epoch: 22, reply: coverageReply())
        let executor = G073NetworkArtifactToolExecutor(host: host, currentEpoch: { 22 })
        let request = try NetworkArtifactToolRequest.coverageSummary(sessionID: sessionID)
        let workspace = URL(fileURLWithPath: "/tmp/floe-artifact-test-workspace")
        var context = ToolContext(runID: runID, cancellation: CancellationToken(),
                                  conversationID: taskID)
        context.workspaceRootURL = workspace
        let reply = try await executor.execute(request: request, context: context)
        XCTAssertEqual(reply, coverageReply())
        let submitted = try XCTUnwrap(host.requests.first)
        XCTAssertEqual(submitted.owner.taskID, taskID)
        XCTAssertEqual(submitted.owner.runID, runID)
        XCTAssertEqual(submitted.owner.epoch, 22)
        XCTAssertNotNil(submitted.owner.workspaceFingerprint)
    }

    func testBackgroundTaskWithoutUIHolderStillReachesHostViaTrustedContext() async throws {
        let host = FakeArtifactHost(epoch: 24, reply: coverageReply())
        let executor = G073NetworkArtifactToolExecutor(host: host, currentEpoch: { 24 })
        let request = try NetworkArtifactToolRequest.coverageSummary(sessionID: sessionID)
        // A scheduled/background task has no UI holder in this process. The
        // native executor derives task/run/epoch/workspace only from the
        // runtime-issued ToolContext, so no UI lookup is required or used.
        var context = ToolContext(runID: runID, cancellation: CancellationToken(),
                                  conversationID: taskID)
        context.workspaceRootURL = URL(fileURLWithPath: "/tmp/floe-background-task-workspace")
        let reply = try await executor.execute(request: request, context: context)
        XCTAssertEqual(reply, coverageReply())
        let submitted = try XCTUnwrap(host.requests.first)
        XCTAssertEqual(submitted.owner.taskID, taskID)
        XCTAssertEqual(submitted.owner.runID, runID)
        XCTAssertEqual(submitted.owner.epoch, 24)
        XCTAssertNotNil(submitted.owner.workspaceFingerprint)
    }

    func testToolRunRendersBoundedSummaryAndMapsPartialStatus() async throws {
        let host = FakeArtifactHost(epoch: 23, reply: pcapReply())
        let executor = G073NetworkArtifactToolExecutor(host: host, currentEpoch: { 23 })
        let request = try NetworkArtifactToolRequest.pcapAnalyze(analysisID: analysisID)
        var context = ToolContext(runID: runID, cancellation: CancellationToken(),
                                  conversationID: taskID)
        context.workspaceRootURL = URL(fileURLWithPath: "/tmp/floe-artifact-test-workspace")
        let output = try await NetworkArtifactToolRun.invoke(
            executor: executor, request: request, context: context)
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("Capture analysis"))
        XCTAssertTrue(output.summary.contains("partial"))
        XCTAssertLessThanOrEqual(output.summary.count,
                                 NetworkArtifactLimits.maximumSummaryCharacters)
        XCTAssertFalse(output.summary.contains("10.0.0.1"))
    }

    func testRegistrationExposesExactlyTwoReadOnlyTools() {
        let registry = ToolRunnerRegistry()
        let executor = FakeExecuting()
        let names = registerNetworkArtifactTools(executor: executor, registry: registry)
        XCTAssertEqual(Set(names), Set(NetworkArtifactToolNames.all))
        for name in names {
            let descriptor = registry.descriptor(named: name)
            XCTAssertNotNil(descriptor)
            XCTAssertEqual(descriptor?.effect, .readOnly)
            XCTAssertEqual(descriptor?.isSideEffecting, false)
        }
        unregisterNetworkArtifactTools(registry: registry)
        XCTAssertTrue(names.allSatisfy { registry.descriptor(named: $0) == nil })
    }
}

private final class FakeArtifactHost: G073NetworkArtifactHostSubmitting, @unchecked Sendable {
    struct Submission: Sendable {
        let request: NetworkArtifactToolRequest
        let owner: G073NetworkArtifactOwner
    }

    let epoch: UInt64
    var requests: [Submission] = []
    private let reply: Data

    init(epoch: UInt64, reply: Data? = nil) {
        self.epoch = epoch
        self.reply = reply ?? Data(#"""
        {"schema":"floe.coverage-tool-summary.v1","version":1,"source":"phone",
         "sessionID":"71000000-0000-4000-8000-000000000007","status":"ok",
         "name":"Home","privacy":"redacted","pointCount":0,"namedLocations":[],
         "hasFloorplan":false,"aggregate":{"pointCount":0,"staleCount":0,
           "permissionRequiredCount":0,"cachedScanCount":0,"noSignalCount":0,
           "unsampledCells":48},"points":[],"limitations":[]}
        """#.utf8)
    }

    var boundEpoch: UInt64 { epoch }
    var isBound: Bool { true }

    func submit(request: NetworkArtifactToolRequest, owner: G073NetworkArtifactOwner,
                cancellation: CancellationToken) async throws -> Data {
        requests.append(Submission(request: request, owner: owner))
        return reply
    }
}

private final class FakeExecuting: NetworkArtifactHostExecuting, @unchecked Sendable {
    var isAvailable: Bool { true }
    func execute(request: NetworkArtifactToolRequest, context: ToolContext) async throws -> Data {
        Data()
    }
}
