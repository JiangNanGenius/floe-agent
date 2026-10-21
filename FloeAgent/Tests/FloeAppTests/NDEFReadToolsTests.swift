// FloeAppTests — prepared tests for NDEF decoding, ownership and the
// `apple.nfc.readNDEF` tool contract.
//
// No hardware, system NFC sheet or tag is used. The reader service's own
// delegate is compile-only here; hardware acceptance remains primary-owned.

#if canImport(UIKit) && canImport(CoreNFC)
import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeApp

@Suite("FloeApp.NDEFReadTools")
struct NDEFReadToolsTests {
    private func context(
        conversation: UUID? = UUID(),
        cancellation: CancellationToken = CancellationToken()
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            cancellation: cancellation,
            environmentID: "env-nfc",
            conversationID: conversation
        )
    }

    private func tool(
        service: FakeNDEFReader,
        foreground: Bool = true
    ) -> AppleNDEFReadTool {
        AppleNDEFReadTool(
            service: service,
            isForeground: { foreground },
            alertMessage: "Hold your iPhone near the tag."
        )
    }

    private func textPayload(
        _ text: String,
        language: String = "en",
        utf16: Bool = false
    ) -> Data {
        let languageData = Data(language.utf8)
        var status = UInt8(languageData.count & 0x3F)
        if utf16 { status |= 0x80 }
        var data = Data([status])
        data.append(languageData)
        if utf16 {
            data.append(contentsOf: [0xFF, 0xFE])
            data.append(text.data(using: .utf16LittleEndian) ?? Data())
        } else {
            data.append(Data(text.utf8))
        }
        return data
    }

    private func uriPayload(_ code: UInt8, _ suffix: String) -> Data {
        var data = Data([code])
        data.append(Data(suffix.utf8))
        return data
    }

    private func record(
        tnf: UInt8 = 0x01,
        type: String = "T",
        payload: Data,
        identifier: Data? = nil
    ) -> NDEFRawRecord {
        NDEFRawRecord(
            typeNameFormat: tnf,
            type: Data(type.utf8),
            identifier: identifier,
            payload: payload
        )
    }

    @Test("Well-known text and URI records decode without opening the URL")
    func textAndURIRecords() {
        let message = NDEFDecoder.decode([
            record(payload: textPayload("Hello", language: "en")),
            record(type: "U", payload: uriPayload(0x04, "example.com/path")),
            record(
                tnf: 0x03,
                type: "",
                payload: Data("https://absolute.example/x".utf8)
            )
        ])
        #expect(message.records.count == 3)
        #expect(message.records[0].kind == .text)
        #expect(message.records[0].text == "Hello")
        #expect(message.records[0].language == "en")
        #expect(message.records[1].kind == .uri)
        #expect(message.records[1].uri == "https://example.com/path")
        #expect(message.records[2].uri == "https://absolute.example/x")
        let rendered = NDEFOutput.render(message)
        #expect(rendered.contains("autoOpened=false"))
        #expect(rendered.contains("execution=none"))
        #expect(!rendered.contains("openURL"))
    }

    @Test("UTF-16 text requires/uses a BOM and marks the missing-BOM case")
    func utf16Text() {
        let valid = NDEFDecoder.decode([
            record(payload: textPayload("你好", language: "zh", utf16: true))
        ])
        #expect(valid.records[0].text == "你好")
        #expect(!valid.records[0].issues.contains("textUTF16MissingBOM"))

        var missingBOM = Data([UInt8(0x80 | 2)])
        missingBOM.append(Data("en".utf8))
        missingBOM.append(Data("Hi".data(using: .utf16LittleEndian) ?? Data()))
        let missing = NDEFDecoder.decode([record(payload: missingBOM)])
        #expect(missing.records[0].issues.contains("textUTF16MissingBOM"))
    }

    @Test("Malformed text, unknown URI prefixes and invalid UTF-8 preserve an explicit issue")
    func malformedRecords() {
        let badLanguageLength = NDEFDecoder.decode([
            record(payload: Data([0x05, 0x65, 0x6E]))
        ])
        #expect(badLanguageLength.records[0].issues.contains("textLanguageLengthExceeded"))

        let unknownPrefix = NDEFDecoder.decode([
            record(type: "U", payload: uriPayload(0x24, "not-a-uri"))
        ])
        #expect(unknownPrefix.records[0].uri == nil)
        #expect(unknownPrefix.records[0].issues.contains("uriPrefixUnsupported"))

        let invalidUTF8 = NDEFDecoder.decode([
            record(payload: Data([0x00, 0xFF, 0xFE, 0xFD]))
        ])
        #expect(invalidUTF8.records[0].text == nil)
        #expect(invalidUTF8.records[0].issues.contains("textInvalidUTF8"))
    }

    @Test("MIME and unknown records preserve bounded raw provenance")
    func mimeAndUnknownRecords() {
        let payload = Data(repeating: 0xAB, count: 256)
        let message = NDEFDecoder.decode([
            NDEFRawRecord(
                typeNameFormat: 0x02,
                type: Data("text/plain".utf8),
                identifier: nil,
                payload: payload
            ),
            NDEFRawRecord(
                typeNameFormat: 0x07,
                type: Data("x".utf8),
                identifier: nil,
                payload: Data([0x00, 0x01])
            )
        ])
        #expect(message.records[0].kind == .mime)
        #expect(message.records[0].mimeType == "text/plain")
        #expect(message.records[0].rawSHA256.count == 64)
        #expect(message.records[0].rawPrefixHex.count == 96 * 2)
        #expect(message.records[1].kind == .unknown)
        #expect(message.records[1].issues.contains("tnfReserved"))
        let rendered = NDEFOutput.render(message)
        #expect(rendered.contains("sha256="))
        #expect(rendered.contains("rawPrefixHex="))
    }

    @Test("Record and byte bounds are enforced without silent loss")
    func recordAndByteBounds() {
        let many = (0..<40).map { index in
            record(type: "T", payload: textPayload("row-\(index)"))
        }
        let bounded = NDEFDecoder.decode(many)
        #expect(bounded.reportedRecordCount == 40)
        #expect(bounded.records.count == 32)
        #expect(bounded.omittedRecords == 8)
        #expect(bounded.truncated)

        let large = NDEFDecoder.decode([
            record(payload: Data(repeating: 0x41, count: 9_000))
        ])
        #expect(large.records[0].payloadTruncated)
        #expect(large.records[0].rawPrefixHex.count == 96 * 2)
        #expect(large.truncated)

        let longText = String(repeating: "a", count: 4_000)
        let text = NDEFDecoder.decode([record(payload: textPayload(longText))])
        #expect(text.records[0].valueTruncated)
        #expect(text.records[0].text?.count == 1_024)
    }

    @Test("One session gate admits one owner and never steals or cancels it")
    func ownerCollisionGate() {
        let gate = NDEFSessionGate()
        let first = NDEFSessionOwner(
            conversationID: UUID(),
            environmentID: "env",
            clientSessionID: "client-a",
            runID: UUID()
        )
        let second = NDEFSessionOwner(
            conversationID: UUID(),
            environmentID: "env",
            clientSessionID: "client-b",
            runID: UUID()
        )
        let token = gate.acquire(owner: first)
        #expect(token != nil)
        #expect(gate.isBusy)
        #expect(gate.acquire(owner: second) == nil)
        #expect(gate.isCurrent(token ?? UUID()))
        gate.release(token: token ?? UUID())
        #expect(!gate.isBusy)
        let secondToken = gate.acquire(owner: second)
        #expect(secondToken != nil)
        gate.release(token: secondToken ?? UUID())
    }

    @Test("A successful tool scan reports limits, records and no payload execution")
    func successfulScanOutput() async throws {
        let service = FakeNDEFReader()
        let message = NDEFDecoder.decode([
            record(payload: textPayload("Hello")),
            record(type: "U", payload: uriPayload(0x04, "example.com"))
        ])
        await service.setOutcome(.success(message))
        let output = try await tool(service: service).execute(
            .init(timeoutSeconds: 20),
            context: context()
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=ok"))
        #expect(output.summary.contains("recordCount=2"))
        #expect(output.summary.contains("sessionSeconds=20"))
        #expect(output.summary.contains("autoOpened=false"))
        #expect(output.summary.contains("execution=none"))
        #expect(output.summary.contains("text=\"Hello\""))
        #expect(output.summary.contains("uri=\"https://example.com\""))
        let reads = await service.readCount
        #expect(reads == 1)
    }

    @Test("Busy, unavailable, foreground, interruption and configuration errors stay distinct")
    func errorStates() async throws {
        let busy = FakeNDEFReader()
        await busy.setOutcome(.busy)
        let busyOutput = try await tool(service: busy).execute(
            .init(),
            context: context()
        )
        #expect(busyOutput.summary.contains("status=busy"))
        #expect(busyOutput.exitStatus == 75)

        let unavailable = FakeNDEFReader(isAvailable: false)
        let unavailableOutput = try await tool(service: unavailable).execute(
            .init(),
            context: context()
        )
        #expect(unavailableOutput.summary.contains("status=unavailable"))
        #expect(unavailableOutput.exitStatus == 77)

        let foreground = try await tool(
            service: FakeNDEFReader(),
            foreground: false
        ).execute(.init(), context: context())
        #expect(foreground.summary.contains("status=foregroundRequired"))

        let interrupted = FakeNDEFReader()
        await interrupted.setOutcome(.interrupted(reason: .background))
        let interruptedOutput = try await tool(service: interrupted).execute(
            .init(),
            context: context()
        )
        #expect(interruptedOutput.summary.contains("status=interrupted"))
        #expect(interruptedOutput.summary.contains("reason=background"))

        let configuration = FakeNDEFReader()
        await configuration.setOutcome(.entitlementMissing)
        let configurationOutput = try await tool(service: configuration).execute(
            .init(),
            context: context()
        )
        #expect(configurationOutput.summary.contains("status=configurationError"))
        #expect(configurationOutput.exitStatus == 78)

        let empty = FakeNDEFReader()
        await empty.setOutcome(.emptyTag)
        let emptyOutput = try await tool(service: empty).execute(
            .init(),
            context: context()
        )
        #expect(emptyOutput.summary.contains("status=emptyTag"))
        #expect(emptyOutput.exitStatus == 0)

        let failed = FakeNDEFReader()
        await failed.setOutcome(.readFailed(code: "tagConnectionLost"))
        let failedOutput = try await tool(service: failed).execute(
            .init(),
            context: context()
        )
        #expect(failedOutput.summary.contains("code=tagConnectionLost"))
        #expect(failedOutput.summary.contains("retryable=true"))
    }

    @Test("Task cancellation resolves as cancelled, not a completed scan")
    func cancellation() async throws {
        let service = FakeNDEFReader()
        await service.setHoldUntilCancelled(true)
        let token = CancellationToken()
        let context = context(cancellation: token)
        let readTool = tool(service: service)
        let task = Task {
            try await readTool.execute(.init(), context: context)
        }
        var started = false
        for _ in 0..<100 {
            if await service.didStart {
                started = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(started)
        token.cancel()
        let output = try await task.value
        #expect(output.exitStatus == 130)
        #expect(output.summary.contains("status=cancelled"))
        #expect(output.summary.contains("source=task"))
    }

    @Test("Owner identity is derived from the trusted ToolContext")
    func ownerIdentityFromContext() async throws {
        let service = FakeNDEFReader()
        await service.setOutcome(.busy)
        let conversation = UUID()
        _ = try await tool(service: service).execute(
            .init(),
            context: context(conversation: conversation)
        )
        let owner = await service.lastOwner
        #expect(owner?.conversationID == conversation)
        #expect(owner?.environmentID == "env-nfc")
        #expect(owner?.runID != nil)
    }
}

private actor FakeNDEFReader: NDEFReading {
    nonisolated let isAvailable: Bool
    private var outcome: NDEFSessionOutcome = .busy
    private(set) var readCount = 0
    private(set) var lastOwner: NDEFSessionOwner?
    private var holdUntilCancelled = false
    private(set) var didStart = false

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    func setOutcome(_ outcome: NDEFSessionOutcome) {
        self.outcome = outcome
    }

    func setHoldUntilCancelled(_ hold: Bool) {
        holdUntilCancelled = hold
    }

    func read(
        owner: NDEFSessionOwner,
        timeout: TimeInterval,
        alertMessage: String,
        cancellation: CancellationToken
    ) async -> NDEFSessionOutcome {
        _ = timeout
        _ = alertMessage
        readCount += 1
        lastOwner = owner
        if holdUntilCancelled {
            didStart = true
            while !cancellation.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return .cancelled(source: .task)
        }
        return outcome
    }
}
#endif
