import CryptoKit
import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxUtilities
@testable import FloeMacToolbox

private enum TestFailure: Error { case timeout }

@MainActor
private func waitUntil(_ seconds: Double = 5, _ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(seconds))
    while !(await condition()) {
        guard clock.now < deadline else { throw TestFailure.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Suite("Mac checksum", .serialized)
struct MacChecksumTests {
    private let expectations: [ToolboxChecksumAlgorithm: String] = [
        .sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        .sha512: "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        .sha1: "a9993e364706816aba3e25717850c26c9cd0d89d",
        .md5: "900150983cd24fb0d6963f7d28e17f72",
        .crc32: "352441c2",
    ]

    private func root() throws -> URL {
        try MacToolboxTestRoot.unique("checksum")
    }

    private func selection(_ data: Data, name: String, in root: URL) throws -> MacChecksumSelection {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return try MacChecksumSelection(url: url)
    }

    @Test func allFiveAlgorithmsMatchKnownVectorsThroughTheRealFileReader() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for (algorithm, hex) in expectations {
            let selected = try selection(Data("abc".utf8), name: "\(algorithm.rawValue).bin", in: root)
            let value = try await ToolboxFileChecksum.calculate(
                algorithm,
                expectedByteCount: 3,
                read: selected.read
            )
            #expect(value.hexadecimal == hex)
            #expect(value.byteCount == 3)
            #expect(value.matches(hex.uppercased()))
            #expect(!value.matches("not a hash"))
        }
    }

    @Test func emptyFileAndMultiChunkStreamingAreDeterministic() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try selection(Data(), name: "empty.bin", in: root)
        let emptyHash = try await ToolboxFileChecksum.calculate(.sha256, expectedByteCount: 0, read: empty.read)
        #expect(emptyHash.hexadecimal == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        var bytes = Data(count: 200_000)
        for index in bytes.indices { bytes[index] = UInt8((index * 31 + 7) & 0xff) }
        let large = try selection(bytes, name: "large.bin", in: root)
        let streamed = try await ToolboxFileChecksum.calculate(.sha256, expectedByteCount: UInt64(bytes.count), read: large.read)
        let oneShot = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(streamed.hexadecimal == oneShot)
        #expect(streamed.byteCount == UInt64(bytes.count))
    }

    @Test func sizeMismatchAndReaderOverflowFailWithoutAResult() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try selection(Data("abcd".utf8), name: "changed.bin", in: root)
        await #expect(throws: ToolboxError.self) {
            try await ToolboxFileChecksum.calculate(.sha256, expectedByteCount: 3, read: selected.read)
        }
        await #expect(throws: ToolboxError.self) {
            try await ToolboxFileChecksum.calculate(.sha256, maximumBytes: 8, read: { _, _ in
                Data(repeating: 0, count: 10)
            })
        }
    }

    @Test func macModelPublishesTheSelectedFilesDigestAndClearsOnAlgorithmChange() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try selection(Data("abc".utf8), name: "abc.txt", in: root)
        let model = MacHashModel(selectFile: { selected })
        model.selectAndCalculate()
        try await waitUntil { !model.busy }
        #expect(model.result?.hexadecimal == expectations[.sha256])
        #expect(model.title == "abc.txt")
        #expect(model.expectedBytes == 3)
        #expect(model.completedBytes == 3)
        #expect(!model.failed && !model.cancelled)

        model.algorithm = .md5
        #expect(model.result == nil)
        #expect(model.title.isEmpty)
        #expect(!model.busy)
    }

    @Test func failedReplacementCannotRetainThePreviousDigest() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try selection(Data("abc".utf8), name: "first.bin", in: root)
        var calls = 0
        let model = MacHashModel(selectFile: {
            calls += 1
            if calls == 1 { return selected }
            throw ToolboxError.denied
        })
        model.selectAndCalculate()
        try await waitUntil { !model.busy }
        #expect(model.result != nil)
        model.comparison = "retained user input"
        model.selectAndCalculate()
        #expect(model.result == nil && model.title.isEmpty && model.busy)
        try await waitUntil { !model.busy }
        #expect(model.failed)
        #expect(model.result == nil && model.title.isEmpty)
        #expect(model.comparison == "retained user input")
    }

    @Test func cancelledModelNeverPublishesTheLateDigest() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try selection(Data(repeating: 7, count: 1_000_000), name: "large.bin", in: root)
        let model = MacHashModel(selectFile: {
            try await Task.sleep(for: .milliseconds(100))
            return selected
        })
        model.selectAndCalculate()
        model.cancel()
        try await waitUntil { !model.busy }
        #expect(model.cancelled)
        #expect(!model.failed)
        #expect(model.result == nil)
    }

    @Test func directoryIsRejectedAsAFileSelection() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ToolboxError.self) {
            try MacChecksumSelection(url: root)
        }
    }

    @Test func scopeStartsBeforeMetadataAndOpenAndEndsAfterReaderCloses() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.bin")
        try Data("abc".utf8).write(to: file)
        let events = ChecksumAccessEvents()
        let access = MacChecksumFileAccess(
            beginScope: { _ in events.record("begin"); return true },
            endScope: { _ in events.record("end") },
            inspect: { _ in
                events.record("inspect")
                return MacChecksumFileInfo(isRegularFile: true, title: "fixture.bin", byteCount: 3)
            },
            open: { url in events.record("open"); return try FileHandle(forReadingFrom: url) },
            didClose: { events.record("close") }
        )
        var selected: MacChecksumSelection? = try MacChecksumSelection(url: file, access: access)
        var reader: ToolboxByteReader? = selected?.read
        selected = nil
        #expect(events.values == ["begin", "inspect", "open"])
        let bytes = try await reader?(0, 3)
        #expect(bytes == Data("abc".utf8))
        reader = nil
        try await waitUntil { events.values.contains("end") }
        #expect(events.values == ["begin", "inspect", "open", "close", "end"])
    }

    @Test func scopeIsReleasedWhenMetadataOrOpenFails() throws {
        let url = URL(fileURLWithPath: "/not-read-by-this-fixture")
        for failAtOpen in [false, true] {
            let events = ChecksumAccessEvents()
            let access = MacChecksumFileAccess(
                beginScope: { _ in events.record("begin"); return true },
                endScope: { _ in events.record("end") },
                inspect: { _ in
                    events.record("inspect")
                    guard failAtOpen else { throw ToolboxError.denied }
                    return MacChecksumFileInfo(isRegularFile: true, title: "fixture", byteCount: nil)
                },
                open: { _ in events.record("open"); throw ToolboxError.denied },
                didClose: { events.record("close") }
            )
            #expect(throws: ToolboxError.self) { try MacChecksumSelection(url: url, access: access) }
            #expect(events.values == (failAtOpen ? ["begin", "inspect", "open", "end"] : ["begin", "inspect", "end"]))
        }
    }

    @Test func cancellingAnInFlightHashRetainsSourceUntilReaderReturnsThenReleasesIt() async throws {
        let gate = ControlledChecksumRead()
        defer { Task { await gate.release() } }
        var selected: MacChecksumSelection? = MacChecksumSelection(
            title: "synthetic", byteCount: 3,
            read: { _, _ in try await gate.read() }
        )
        weak var weakSelection = selected
        let oneShot = OneShotChecksumSelection(selected)
        selected = nil
        let model = MacHashModel(selectFile: { oneShot.take() })
        model.selectAndCalculate()
        try await waitUntil { await gate.entered }
        model.cancel()
        #expect(model.stopping && model.busy)
        #expect(weakSelection != nil)
        await gate.release()
        try await waitUntil { !model.busy && weakSelection == nil }
        #expect(model.cancelled && !model.failed && model.result == nil)
    }
}

private final class ChecksumAccessEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ event: String) { lock.withLock { storage.append(event) } }
    var values: [String] { lock.withLock { storage } }
}

private actor ControlledChecksumRead {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func read() async throws -> Data {
        entered = true
        if !released {
            await withCheckedContinuation { self.continuation = $0 }
        }
        try Task.checkCancellation()
        return Data("abc".utf8)
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class OneShotChecksumSelection {
    private var value: MacChecksumSelection?
    init(_ value: MacChecksumSelection?) { self.value = value }
    func take() -> MacChecksumSelection? {
        defer { value = nil }
        return value
    }
}
