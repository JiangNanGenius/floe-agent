// SPDX-License-Identifier: MPL-2.0
//
// C05 SFTP subsystem listing tests (authored; not run by this source lane).
//
// These are deterministic protocol tests against the real bounded SFTP v3
// decoder in FloeSSH. The fake byte transport speaks the server side of the
// SFTP subsystem; no SSH server, network, device or remote helper program is
// involved. They cover:
//   * the wire requests are INIT / OPENDIR / READDIR / CLOSE only, with no
//     shell, exec or sftp-server text anywhere in the stream;
//   * one entry more than maxEntries is returned (page truncation signal);
//   * the server handle is CLOSEd on the success path;
//   * fragmented responses work;
//   * an oversized frame is rejected before its body is buffered;
//   * the received-byte budget bounds one listing;
//   * a silent server times out, and cancellation is reported as cancelled.

import Foundation
import Testing
@testable import FloeSSH

@Suite("SFTP subsystem bounded listing")
struct BoundedSFTPSubsystemListingTests {
    // MARK: - Fake server

    private struct Entry: Sendable {
        var name: String
        var size: UInt32
        var mode: UInt32
        var modified: UInt32
    }

    private final class FakeSFTPServer: BoundedSFTPByteTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let entries: [Entry]
        private let batchSize: Int
        private let fragment: Int
        private var nextEntry = 0
        private var pending = Data()
        private var requests: [Data] = []
        private var reads = 0
        private var closeRequests = 0
        private var openRequests = 0
        private var readDirRequests = 0

        init(entries: [Entry], batchSize: Int, fragment: Int = 4096) {
            self.entries = entries
            self.batchSize = max(1, batchSize)
            self.fragment = max(1, fragment)
        }

        var observedRequests: [Data] {
            withLocked { requests }
        }

        var observedReads: Int {
            withLocked { reads }
        }

        var observedCloseRequests: Int {
            withLocked { closeRequests }
        }

        var observedOpenRequests: Int {
            withLocked { openRequests }
        }

        var observedReadDirRequests: Int {
            withLocked { readDirRequests }
        }

        private func withLocked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func write(_ data: Data) async throws {
            withLocked {
                requests.append(data)
                respondLocked(to: data)
            }
        }

        func read() async throws -> Data? {
            withLocked {
                reads += 1
                guard !pending.isEmpty else { return nil }
                let count = min(fragment, pending.count)
                let chunk = Data(pending.prefix(count))
                pending.removeSubrange(0..<count)
                return chunk
            }
        }

        func close() async {}

        private func respondLocked(to frame: Data) {
            guard frame.count >= 5 else { return }
            let type = frame[frame.startIndex + 4]
            switch type {
            case 1: // SSH_FXP_INIT
                pending.append(Self.frame(type: 2, body: Self.uint32(3)))
            case 11: // SSH_FXP_OPENDIR
                openRequests += 1
                let id = Self.requestID(frame)
                pending.append(Self.handleResponse(id: id, handle: Data("h1".utf8)))
            case 12: // SSH_FXP_READDIR
                readDirRequests += 1
                let id = Self.requestID(frame)
                if nextEntry >= entries.count {
                    pending.append(Self.statusResponse(id: id, code: 1, message: "EOF"))
                } else {
                    let end = min(entries.count, nextEntry + batchSize)
                    let batch = Array(entries[nextEntry..<end])
                    nextEntry = end
                    pending.append(Self.nameResponse(id: id, entries: batch))
                }
            case 4: // SSH_FXP_CLOSE
                closeRequests += 1
                let id = Self.requestID(frame)
                pending.append(Self.statusResponse(id: id, code: 0, message: "OK"))
            default:
                break
            }
        }

        private static func requestID(_ frame: Data) -> UInt32 {
            guard frame.count >= 9 else { return 0 }
            let start = frame.startIndex + 5
            return frame[start..<start + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }

        private static func frame(type: UInt8, body: Data) -> Data {
            var payload = Data([type])
            payload.append(body)
            var result = uint32(UInt32(payload.count))
            result.append(payload)
            return result
        }

        private static func uint32(_ value: UInt32) -> Data {
            var big = value.bigEndian
            return Data(bytes: &big, count: 4)
        }

        private static func uint64(_ value: UInt64) -> Data {
            var big = value.bigEndian
            return Data(bytes: &big, count: 8)
        }

        private static func string(_ value: String) -> Data {
            let bytes = Data(value.utf8)
            var result = uint32(UInt32(bytes.count))
            result.append(bytes)
            return result
        }

        private static func handleResponse(id: UInt32, handle: Data) -> Data {
            var body = uint32(id)
            body.append(string(String(decoding: handle, as: UTF8.self)))
            return frame(type: 102, body: body)
        }

        private static func statusResponse(id: UInt32, code: UInt32, message: String) -> Data {
            var body = uint32(id)
            body.append(uint32(code))
            body.append(string(message))
            body.append(string(""))
            return frame(type: 101, body: body)
        }

        private static func nameResponse(id: UInt32, entries: [Entry]) -> Data {
            var body = uint32(id)
            body.append(uint32(UInt32(entries.count)))
            for entry in entries {
                body.append(string(entry.name))
                body.append(string("-rw-r--r-- 1 floe floe \(entry.size) \(entry.name)"))
                // size | permissions | access/modification time
                body.append(uint32(0x0000_000D))
                body.append(uint64(UInt64(entry.size)))
                body.append(uint32(entry.mode))
                body.append(uint32(entry.modified - 1))
                body.append(uint32(entry.modified))
            }
            return frame(type: 104, body: body)
        }
    }

    /// A channel that opens but never sends an SFTP reply. `read()` is
    /// cancellation-aware so the session's timeout/cancel paths are
    /// deterministic.
    private final class SilentSFTPServer: BoundedSFTPByteTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Data?, Never>?
        private var closed = false
        private var writes = 0

        var observedWrites: Int {
            withLocked { writes }
        }

        private func withLocked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func write(_ data: Data) async throws {
            withLocked { writes += 1 }
        }

        func read() async throws -> Data? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let alreadyFinished: Bool = withLocked {
                        if closed || Task.isCancelled { return true }
                        waiter = continuation
                        return false
                    }
                    if alreadyFinished {
                        continuation.resume(returning: nil)
                    }
                }
            } onCancel: {
                let pending: CheckedContinuation<Data?, Never>? = withLocked {
                    let value = waiter
                    waiter = nil
                    return value
                }
                pending?.resume(returning: nil)
            }
        }

        func close() async {
            let pending: CheckedContinuation<Data?, Never>? = withLocked {
                closed = true
                let value = waiter
                waiter = nil
                return value
            }
            pending?.resume(returning: nil)
        }
    }

    /// Sends a valid VERSION and then a frame header that declares a body
    /// larger than the injected cap, with no body bytes at all.
    private final class OversizedFrameServer: BoundedSFTPByteTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sentVersion = false
        private var reads = 0

        var observedReads: Int {
            withLocked { reads }
        }

        private func withLocked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func write(_ data: Data) async throws {}

        func read() async throws -> Data? {
            withLocked {
                reads += 1
                if !sentVersion {
                    sentVersion = true
                    var payload = Data([UInt8(2)])
                    var version = UInt32(3).bigEndian
                    payload.append(Data(bytes: &version, count: 4))
                    var length = UInt32(payload.count).bigEndian
                    var result = Data(bytes: &length, count: 4)
                    result.append(payload)
                    return result
                }
                var length = UInt32(4_096).bigEndian
                return Data(bytes: &length, count: 4)
            }
        }

        func close() async {}
    }

    // MARK: - Tests

    @Test("A bounded page uses only SFTP subsystem frames and closes the handle")
    func boundedPage() async throws {
        let entries = (0..<10).map {
            Entry(name: "file-\($0).txt", size: UInt32($0 * 10), mode: 0o100644, modified: 1_700_000_000 + UInt32($0))
        }
        let server = FakeSFTPServer(entries: entries, batchSize: 3, fragment: 7)
        let session = BoundedSFTPSubsystemListSession(transport: server)
        let page = try await session.list(path: "/home/test", maxEntries: 5)

        #expect(page.count == 6)
        #expect(page.map(\.name) == ["file-0.txt", "file-1.txt", "file-2.txt", "file-3.txt", "file-4.txt", "file-5.txt"])
        #expect(page[0].attributes.size == 0)
        #expect(page[5].attributes.size == 50)
        #expect(page[0].attributes.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(server.observedOpenRequests == 1)
        #expect(server.observedReadDirRequests == 2)
        #expect(server.observedCloseRequests == 1)
        #expect(server.observedReads > 0)

        let types = server.observedRequests.compactMap { $0.count >= 5 ? $0[$0.startIndex + 4] : nil }
        #expect(types.first == 1) // INIT
        #expect(Set(types).isSubset(of: Set([1, 4, 11, 12])))
        #expect(types.contains(11))
        #expect(types.contains(12))
        #expect(types.contains(4))

        let streamText = server.observedRequests
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        #expect(!streamText.contains("sftp-server"))
        #expect(!streamText.contains("/bin/sh"))
        #expect(!streamText.contains("sh -c"))
        #expect(!streamText.contains("exec"))
    }

    @Test("EOF ends the page without inventing entries")
    func eofEndsPage() async throws {
        let server = FakeSFTPServer(
            entries: [
                Entry(name: "a", size: 1, mode: 0o100644, modified: 1_700_000_001),
                Entry(name: "dir", size: 0, mode: 0o040755, modified: 1_700_000_002),
            ],
            batchSize: 10
        )
        let page = try await BoundedSFTPSubsystemListSession(transport: server)
            .list(path: "/", maxEntries: 100)

        #expect(page.count == 2)
        #expect(page[1].attributes.isDirectory)
        #expect(page[0].attributes.isDirectory == false)
        #expect(server.observedCloseRequests == 1)
        #expect(server.observedReadDirRequests == 2)
    }

    @Test("An oversized frame is rejected before its body is buffered")
    func oversizedFrameRejected() async throws {
        let server = OversizedFrameServer()
        let session = BoundedSFTPSubsystemListSession(
            transport: server,
            maximumFrameBytes: 128
        )
        do {
            _ = try await session.list(path: "/", maxEntries: 10)
            Issue.record("Expected protocolFailure")
        } catch let error as SSHSFTPError {
            #expect(error == .protocolFailure)
        }
        #expect(server.observedReads == 2)
    }

    @Test("The received-byte budget bounds one listing")
    func byteBudget() async throws {
        let entries = (0..<100).map {
            Entry(name: "entry-\($0)", size: UInt32($0), mode: 0o100644, modified: 1_700_000_000)
        }
        let server = FakeSFTPServer(entries: entries, batchSize: 1)
        let session = BoundedSFTPSubsystemListSession(
            transport: server,
            maximumListingBytes: 200
        )
        do {
            _ = try await session.list(path: "/", maxEntries: 100)
            Issue.record("Expected protocolFailure")
        } catch let error as SSHSFTPError {
            #expect(error == .protocolFailure)
        }
        #expect(server.observedReadDirRequests > 1)
    }

    @Test("A silent server times out")
    func silentServerTimesOut() async throws {
        let server = SilentSFTPServer()
        let session = BoundedSFTPSubsystemListSession(
            transport: server,
            packetTimeoutNanoseconds: 50_000_000
        )
        do {
            _ = try await session.list(path: "/", maxEntries: 10)
            Issue.record("Expected timeout")
        } catch let error as SSHSFTPError {
            #expect(error == .timeout)
        }
        #expect(server.observedWrites == 1)
    }

    @Test("Cancellation is reported without a partial page")
    func cancellation() async throws {
        let server = SilentSFTPServer()
        let session = BoundedSFTPSubsystemListSession(
            transport: server,
            packetTimeoutNanoseconds: 10_000_000_000
        )
        let task = Task {
            try await session.list(path: "/", maxEntries: 10)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as SSHSFTPError {
            #expect(error == .cancelled)
        }
    }

    @Test("The SFTP listing path has no exec/helper dependency")
    func noHelperDependency() throws {
        // Tests/FloeSSHTests/<this file> -> package root is three levels up.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/FloeSSH/SSHSFTPService.swift"),
            encoding: .utf8
        )
        #expect(source.contains("openSFTPSubsystemChannel"))
        #expect(!source.contains("withExec"))
        #expect(!source.contains("sftp-server"))
        #expect(!source.contains("helperCommand"))
        #expect(!source.contains("command -v"))
    }
}
