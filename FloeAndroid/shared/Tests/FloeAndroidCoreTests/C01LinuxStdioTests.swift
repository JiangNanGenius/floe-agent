// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeAndroidCore

final class C01LinuxStdioTests: XCTestCase {
    private actor CloseEvents {
        var values: [Bool] = []
        func append(_ value: Bool) { values.append(value) }
    }

    private actor Transport: C01LinuxStdioTransporting {
        var pages: [(Data, Data)]
        let released: Bool
        var writes: [UInt8] = []
        init(pages: [(Data, Data)] = [], released: Bool = false) {
            self.pages = pages; self.released = released
        }
        func capability(epoch: UInt64) async -> C01LinuxStdioCapability {
            C01LinuxStdioCapability(contractVersion: "floe-multi-workload-v3",
                stdioContractVersion: "floe-service-stdio-v1", serviceRoleAvailable: true,
                stdioAvailable: true, detail: "")
        }
        func start(_ request: C01LinuxStdioStartRequest) async throws -> C01LinuxStdioStartReply {
            throw C01LinuxStdioFailure(.unavailable, "Not a process test")
        }
        func write(sessionID: String, data: Data) async throws -> C01LinuxStdioWriteReply {
            writes.append(data.first ?? 0)
            await Task.yield()
            return C01LinuxStdioWriteReply(acceptedBytes: data.count, partial: false, errnoCode: nil)
        }
        func poll(_ request: C01LinuxStdioPollRequest) async throws -> C01LinuxStdioPollReply {
            let next = pages.isEmpty ? (Data(), Data()) : pages.removeFirst()
            return C01LinuxStdioPollReply(sessionID: request.sessionID,
                stdout: next.0, stderr: next.1,
                stdoutCursor: request.stdoutCursor + UInt64(next.0.count),
                stderrCursor: request.stderrCursor + UInt64(next.1.count),
                stdoutGapBytes: 0, stderrGapBytes: 0, stdoutMore: !pages.isEmpty, stderrMore: false,
                stdoutDroppedBytes: 0, stderrDroppedBytes: 0,
                stdoutEOF: released && pages.isEmpty, stderrEOF: released && pages.isEmpty,
                leaseReleased: released && pages.isEmpty, cancelled: false,
                stopReason: nil, exitCode: released ? 0 : nil, termSig: nil, waitErrno: nil, workspaceStatus: nil)
        }
        func closeStdin(sessionID: String) async throws -> C01LinuxStdioStdinEofReply {
            C01LinuxStdioStdinEofReply(state: "closed", reason: nil, errnoCode: nil)
        }
        func requestStop(sessionID: String) async throws {}
    }

    private func channel(_ transport: Transport, events: CloseEvents = CloseEvents(),
                         closeBudget: TimeInterval = 0,
                         runID: UUID = UUID(), taskID: UUID = UUID()) -> C01MCPStdioChannel {
        let task = taskID, project = UUID()
        let binding = C01LinuxStdioBinding(projectID: project, engineProjectID: UUID(),
            environmentID: "test-env", rootIdentity: String(repeating: "a", count: 64),
            taskID: task, runID: runID, conversationID: task, workspaceID: project,
            workspaceRootURL: URL(fileURLWithPath: "/test/Projects/\(project.uuidString)"),
            serverRevision: 1, configDigest: String(repeating: "b", count: 64), displayName: "Fixture",
            command: "node", arguments: ["server.mjs"], cwdRelative: ".", acceptedEpoch: 7)
        return C01MCPStdioChannel(configurationID: UUID(), binding: binding, sessionID: UUID().uuidString,
            transport: transport, validity: { true }, closeReleaseBudget: closeBudget,
            onClosed: { _, released in await events.append(released) })
    }

    func testForeignRunCannotBorrowAStdioChannel() async throws {
        let transport = Transport()
        let runID = UUID(), taskID = UUID()
        let subject = channel(transport, runID: runID, taskID: taskID)
        try await subject.validateInvocation(runID: runID, taskID: taskID)
        do {
            try await subject.validateInvocation(runID: UUID(), taskID: taskID)
            XCTFail("another run borrowed this process")
        } catch let error as C02MCPSetupFailure {
            XCTAssertEqual(error.code, .stdioUnavailable)
        }
        do {
            try await subject.validateInvocation(runID: runID, taskID: UUID())
            XCTFail("another task borrowed this process")
        } catch let error as C02MCPSetupFailure {
            XCTAssertEqual(error.code, .stdioUnavailable)
        }
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testSplitUTF8LineAndStderrStaySeparate() async throws {
        let expected = Data("{\"text\":\"文\"}".utf8)
        let wire = expected + Data([10])
        let split = wire.firstIndex(where: { $0 >= 128 })! + 1
        let transport = Transport(pages: [(wire.prefix(split), Data("diagnostic".utf8)),
                                          (wire.suffix(from: split), Data())])
        let subject = channel(transport)
        let line = try await subject.readLine(maxBytes: 1024, timeout: 1)
        XCTAssertEqual(line, expected)
        let stderr = await subject.drainStderr(maxBytes: 1024)
        XCTAssertEqual(stderr, Data("diagnostic".utf8))
    }

    func testConcurrentLargeWritesDoNotInterleaveChunks() async throws {
        let transport = Transport()
        let subject = channel(transport)
        let size = MailboxC01LinuxStdioTransport.maximumWriteBytes * 2
        async let first: Void = subject.write(Data(repeating: 65, count: size))
        async let second: Void = subject.write(Data(repeating: 66, count: size))
        _ = try await (first, second)
        let writes = await transport.writes
        XCTAssertTrue(writes == [65, 65, 66, 66] || writes == [66, 66, 65, 65])
    }

    func testCloseWithoutReleaseProofDoesNotReportReleased() async {
        let events = CloseEvents()
        let subject = channel(Transport(), events: events)
        await subject.close()
        await subject.close()
        let values = await events.values
        XCTAssertEqual(values, [false])
    }

    func testCloseReportsOnlyActualRelease() async {
        let events = CloseEvents()
        let subject = channel(Transport(released: true), events: events, closeBudget: 1)
        await subject.close()
        let values = await events.values
        XCTAssertEqual(values, [true])
    }

    func testPartialLineEOFIsAProtocolFailure() async {
        let subject = channel(Transport(pages: [(Data("{\"id\":".utf8), Data())], released: true))
        do {
            _ = try await subject.readLine(maxBytes: 1024, timeout: 1)
            XCTFail("An incomplete frame cannot become a successful reply")
        } catch let failure as C02MCPSetupFailure {
            XCTAssertEqual(failure.code, .stdioResponseInvalid)
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
    }
}
