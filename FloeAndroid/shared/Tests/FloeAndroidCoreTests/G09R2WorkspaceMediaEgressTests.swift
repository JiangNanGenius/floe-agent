// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 closed media-purpose workspace egress — authored source tests.
//
// AUTHORED, NOT EXECUTED (the objective explicitly defers every compiler/
// SwiftPM/native/App run to Main's combined batch). Synthetic bytes only; no
// provider, network, device or APK action.
//
// What these cases pin down:
//   * the closed kind/extension/ceiling table (image 128 MiB / audio 1 GiB /
//     video 8 GiB) and that the GENERIC provider-copy budget is still 1 GiB;
//   * the size refusal is the typed -509 size status, never the generic
//     invalidWorkingCopy/stateConflict -504;
//   * a real pinned-descriptor lease streams exactly the captured bytes,
//     verifies the digest at EOF, rejects out-of-order reads and refuses a
//     mutated/truncated source;
//   * on a real installed generation the host opens the media entry with the
//     exact owner/epoch, returns mode `export-media`, and refuses a wrong
//     owner, a wrong epoch, a non-media kind, and a sparse over-cap file
//     BEFORE reading a single byte;
//   * Root retirement cancellation (the same `cancelG04WorkspaceOperations`
//     call `beginGenerationRetirement` uses) makes the next chunk refuse
//     typed, and close still releases the descriptor + owned-work lease.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeAndroidCore
#if canImport(Darwin)
import Darwin
#endif

final class G09R2WorkspaceMediaEgressTests: XCTestCase {

    // MARK: - Closed table + generic budget

    func testMediaKindCapsAndExtensionTableAreClosed() {
        XCTAssertEqual(G04WorkspaceMediaKind.maximumImageBytes, 128 * 1024 * 1024)
        XCTAssertEqual(G04WorkspaceMediaKind.maximumAudioBytes, Int(Int64(1) << 30))
        XCTAssertEqual(G04WorkspaceMediaKind.maximumVideoBytes, Int(Int64(8) << 30))
        XCTAssertEqual(G04WorkspaceMediaKind.allCases.count, 3)
        // Byte-aligned with the App's `MediaWorkspaceStagingPolicy` sets.
        XCTAssertEqual(G04WorkspaceMediaKind.image.fileExtensions,
                       ["png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif"])
        XCTAssertEqual(G04WorkspaceMediaKind.audio.fileExtensions,
                       ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"])
        XCTAssertEqual(G04WorkspaceMediaKind.video.fileExtensions, ["mp4", "mov", "m4v"])

        XCTAssertEqual(G04WorkspaceMediaKind.kind(forLogicalPath: "Media/clip.MP4"),
                       G04WorkspaceMediaKind.video)
        XCTAssertEqual(G04WorkspaceMediaKind.kind(forLogicalPath: "Media/voice.m4a"),
                       G04WorkspaceMediaKind.audio)
        XCTAssertEqual(G04WorkspaceMediaKind.kind(forLogicalPath: "Media/frame.webp"),
                       G04WorkspaceMediaKind.image)
        XCTAssertNil(G04WorkspaceMediaKind.kind(forLogicalPath: "Media/notes.txt"))
        XCTAssertNil(G04WorkspaceMediaKind.kind(forLogicalPath: "Media/no-extension"))
        XCTAssertNil(G04WorkspaceMediaKind.kind(forLogicalPath: "Media/.mp4"))

        // The generic/Office provider-copy ceiling stays EXACTLY as delivered.
        XCTAssertEqual(G04WorkspaceSourceCoordinator.maximumProviderCopyBytes,
                       Int(Int64(1) << 30))
        // And the chunk grammar the App uses is unchanged.
        XCTAssertEqual(G04SourceHostLimits.maximumChunkBytes, 65_536)
        XCTAssertEqual(G04WorkspaceMediaEgressLease.maximumReadBytes, 65_536)
    }

    func testSizeRefusalIsTheTypedSizeStatusNotWorkingCopyConflict() {
        // The only size refusal in this lane is tooLarge -> -509; a shape
        // refusal keeps -504. The old generic 1 GiB bound now reports the
        // same way instead of collapsing into invalidWorkingCopy.
        XCTAssertEqual(G04WorkspaceSourceHost.errorStatus(
            G04SourceCoordinatorError.tooLarge(limit: 8)), G04SourceHostStatus.sizeExceeded)
        XCTAssertEqual(G04WorkspaceSourceHost.errorStatus(
            G04SourceCoordinatorError.invalidWorkingCopy("notRegularFile")),
                       G04SourceHostStatus.stateConflict)
        XCTAssertEqual(G04WorkspaceSourceHost.errorStatus(
            G04SourceCoordinatorError.digestMismatch(expected: "a", actual: "b")),
                       G04SourceHostStatus.digestMismatch)
    }

    // MARK: - Real pinned-descriptor lease (no generation needed)

    private final class ReleaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func makeLease(_ url: URL, kind: G04WorkspaceMediaKind = .video,
                           cancellation: CancellationToken = CancellationToken(),
                           release: @escaping @Sendable () async -> Void = {})
        throws -> G04WorkspaceMediaEgressLease {
        let descriptor = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var info = stat()
        XCTAssertEqual(fstat(descriptor, &info), 0)
        let identity = G04WorkspaceMediaEgressLease.identity(of: info)
        let digest = try FloeDigest.sha256Hex(ofFileAt: url)
        return G04WorkspaceMediaEgressLease(
            kind: kind, descriptor: descriptor, identity: identity, sha256: digest,
            bytes: Int(identity.size), sourceID: nil, sourceRevision: nil,
            cancellation: cancellation, release: release)
    }

    private func readAll(_ lease: G04WorkspaceMediaEgressLease, total: Int) throws -> Data {
        var page = [UInt8](repeating: 0, count: G04WorkspaceMediaEgressLease.maximumReadBytes)
        var collected = Data()
        var offset: Int64 = 0
        while offset < Int64(total) {
            let count = try page.withUnsafeMutableBytes { raw in
                try lease.read(offset: offset, into: raw.baseAddress!, count: raw.count)
            }
            XCTAssertGreaterThan(count, 0)
            collected.append(contentsOf: page[0..<count])
            offset += Int64(count)
        }
        let eof = try page.withUnsafeMutableBytes { raw in
            try lease.read(offset: offset, into: raw.baseAddress!, count: raw.count)
        }
        XCTAssertEqual(eof, 0)
        return collected
    }

    func testLeaseStreamsExactBytesAndVerifiesDigestAtEof() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g09-media-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let url = root.appendingPathComponent("clip.mp4")
        try payload.write(to: url)
        let probe = ReleaseProbe()
        let lease = try makeLease(url) { probe.record() }
        defer { Task { _ = await lease.close() } }

        XCTAssertEqual(lease.bytes, payload.count)
        XCTAssertEqual(lease.sha256, FloeDigest.sha256Hex(payload))
        let collected = try readAll(lease, total: payload.count)
        XCTAssertEqual(collected, payload)
        let outcome = await lease.close()
        XCTAssertEqual(outcome, .verified)
        XCTAssertEqual(probe.value, 1)
    }

    func testLeaseRefusesOutOfOrderReadsAndReadsAfterClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g09-media-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 7, count: 4_096)
        let url = root.appendingPathComponent("clip.mp4")
        try payload.write(to: url)
        let lease = try makeLease(url)
        var page = [UInt8](repeating: 0, count: 1_024)
        XCTAssertThrowsError(try page.withUnsafeMutableBytes { raw in
            try lease.read(offset: 1_024, into: raw.baseAddress!, count: raw.count)
        })
        let closedOutcome = await lease.close()
        XCTAssertEqual(closedOutcome, .abandoned)
        XCTAssertThrowsError(try page.withUnsafeMutableBytes { raw in
            try lease.read(offset: 0, into: raw.baseAddress!, count: raw.count)
        })
    }

    func testLeaseRefusesMutatedOrTruncatedSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g09-media-mutate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<120_000).map { UInt8($0 % 97) })
        let url = root.appendingPathComponent("clip.mp4")
        try payload.write(to: url)
        let lease = try makeLease(url)
        // Truncate the pinned inode after open: the next read's fstat proof
        // must refuse instead of streaming a different body.
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(payload.count - 16))
        try writer.close()
        var page = [UInt8](repeating: 0, count: G04WorkspaceMediaEgressLease.maximumReadBytes)
        XCTAssertThrowsError(try page.withUnsafeMutableBytes { raw in
            try lease.read(offset: 0, into: raw.baseAddress!, count: raw.count)
        })
        let outcome = await lease.close()
        if case .abandoned = outcome {
            // A size mutation must surface as soon as the next chunk is
            // requested; close itself may report the abandoned body.
        } else if case .digestMismatch = outcome {
            // Also acceptable: the typed mutation verdict was already sticky.
        } else {
            XCTFail("unexpected close outcome \(outcome)")
        }
    }

    func testLeaseRefusesCancellationBeforeAnyChunk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g09-media-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 3, count: 8_192)
        let url = root.appendingPathComponent("clip.mp4")
        try payload.write(to: url)
        let cancellation = CancellationToken()
        let lease = try makeLease(url, cancellation: cancellation)
        cancellation.cancel()
        var page = [UInt8](repeating: 0, count: 1_024)
        XCTAssertThrowsError(try page.withUnsafeMutableBytes { raw in
            try lease.read(offset: 0, into: raw.baseAddress!, count: raw.count)
        })
        let outcome = await lease.close()
        XCTAssertEqual(outcome, .abandoned)
    }

    // MARK: - Installed-generation host lane

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        nonisolated(unsafe) static var value: UInt64 = UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            value &+= 1
            return value
        }
    }

    private final class Boot {
        let epoch: UInt64
        let rootPath: String
        let token: String
        var retired = false
        init(epoch: UInt64, rootPath: String, token: String) {
            self.epoch = epoch; self.rootPath = rootPath; self.token = token
        }
    }

    private enum TestError: Error { case bootstrap, envelope }

    private var tracked: [Boot] = []

    private func bootInstalledGeneration() async throws -> Boot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g09-media-egress-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let token = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted = AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: token,
                                                             epoch: epoch) else {
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, rootPath: root, token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let installed = G02RuntimeComposition.shared.installedComposition,
               installed.epoch == epoch,
               AndroidRuntimeBootstrap.currentPumps()?.storeReady == true,
               G02RuntimeComposition.shared.isExtensionAttached(G02DomainExtensionKey.workspace) {
                return boot
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        guard !boot.retired else { return }
        boot.retired = true
        _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: boot.token)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not close for epoch \(boot.epoch)")
    }

    override func tearDown() async throws {
        let host = G04WorkspaceSourceHost.shared
        host.liveEpochOverrideForTesting = nil
        host.coordinatorOverrideForTesting = nil
        host.stagingRootOverrideForTesting = nil
        for boot in tracked { await shutdownAndAwaitClosed(boot) }
        tracked.removeAll()
        G02RuntimeComposition.shared.resetForTesting()
        try await super.tearDown()
    }

    private func installedCluster() throws -> G02OwnedStoreCluster {
        guard let installed = G02RuntimeComposition.shared.installedComposition else {
            throw TestError.envelope
        }
        return installed.cluster
    }

    private func makeBoundOrdinaryTask() async throws -> (taskID: UUID, workspaceID: UUID) {
        let cluster = try installedCluster()
        let taskID = UUID()
        try await cluster.conversationStore.saveConversation(ConversationRecord(
            id: taskID, title: "Media egress fixture", createdAt: Date(), updatedAt: Date()))
        let record = try await cluster.workspaceStore.ensureWorkspace(conversationID: taskID,
                                                                      title: "Media egress fixture")
        return (taskID, record.id)
    }

    private func taskRoot(_ taskID: UUID) throws -> URL {
        URL(fileURLWithPath: try installedCluster().identity.root.path)
            .appendingPathComponent("Workspace/PrivateTasks/\(taskID.uuidString)")
    }

    private func writeWorkspaceFile(_ relativePath: String, taskID: UUID,
                                    bytes: Data) throws -> URL {
        let url = try taskRoot(taskID).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func sparseWorkspaceFile(_ relativePath: String, taskID: UUID,
                                     size: Int) throws -> URL {
        let url = try taskRoot(taskID).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.synchronize()
        try handle.close()
        return url
    }

    private func reply(_ code: Int32, _ buffer: [CChar]) -> [String: Any]? {
        guard code >= 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes: buffer, count: Int(code))))
            as? [String: Any]
    }

    func testHostMediaEgressStreamsWithExactOwnerAndMode() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let payload = Data((0..<131_072).map { UInt8($0 % 239) })
        _ = try writeWorkspaceFile("media/clip.mp4", taskID: taskID, bytes: payload)

        let ticket = host.egressOpenMedia(epoch: boot.epoch, kindRaw: "video",
                                          taskHex: taskID.uuidString,
                                          workspaceHex: workspaceID.uuidString,
                                          logicalPath: "media/clip.mp4")
        XCTAssertGreaterThan(ticket, 0)
        var buffer = [CChar](repeating: 0, count: 4096)
        let size = host.egressInfo(ticket: ticket, buffer: &buffer, capacity: 4096)
        let info = try XCTUnwrap(reply(size, buffer))
        XCTAssertEqual(info["ok"] as? Int, 1)
        XCTAssertEqual(info["mode"] as? String, "export-media")
        XCTAssertEqual(info["mediaKind"] as? String, "video")
        XCTAssertEqual(info["bytes"] as? Int, payload.count)
        XCTAssertEqual(info["sha256"] as? String, FloeDigest.sha256Hex(payload))
        XCTAssertEqual(info["logicalPath"] as? String, "media/clip.mp4")
        XCTAssertNil(info["recoveryID"])

        var page = [UInt8](repeating: 0, count: G04SourceHostLimits.maximumChunkBytes)
        var collected = Data()
        var offset: Int64 = 0
        while offset < Int64(payload.count) {
            let copied = host.egressRead(ticket: ticket, offset: offset,
                                         buffer: &page, capacity: Int32(page.count))
            XCTAssertGreaterThan(copied, 0)
            collected.append(contentsOf: page[0..<Int(copied)])
            offset += Int64(copied)
        }
        XCTAssertEqual(collected, payload)
        XCTAssertEqual(host.egressRead(ticket: ticket, offset: Int64(payload.count),
                                       buffer: &page, capacity: Int32(page.count)), 0)
        XCTAssertEqual(host.egressClose(ticket: ticket), G04SourceHostStatus.ok)
        // Close is idempotent for the App's finally path.
        XCTAssertEqual(host.egressClose(ticket: ticket), G04SourceHostStatus.ok)
    }

    func testHostMediaEgressRefusesWrongOwnerEpochAndKind() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        _ = try writeWorkspaceFile("media/clip.mp4", taskID: taskID,
                                   bytes: Data(repeating: 1, count: 64))
        let foreignWorkspace = UUID().uuidString
        XCTAssertEqual(host.egressOpenMedia(epoch: boot.epoch, kindRaw: "video",
                                            taskHex: taskID.uuidString,
                                            workspaceHex: foreignWorkspace,
                                            logicalPath: "media/clip.mp4"),
                       Int64(G04SourceHostStatus.identityRefused))
        XCTAssertEqual(host.egressOpenMedia(epoch: boot.epoch &+ 1, kindRaw: "video",
                                            taskHex: taskID.uuidString,
                                            workspaceHex: workspaceID.uuidString,
                                            logicalPath: "media/clip.mp4"),
                       Int64(G04SourceHostStatus.generationFenced))
        // Kind must equal the path's own closed extension before any lookup.
        XCTAssertEqual(host.egressOpenMedia(epoch: boot.epoch, kindRaw: "image",
                                            taskHex: taskID.uuidString,
                                            workspaceHex: workspaceID.uuidString,
                                            logicalPath: "media/clip.mp4"),
                       Int64(G04SourceHostStatus.invalidArguments))
        XCTAssertEqual(host.egressOpenMedia(epoch: boot.epoch, kindRaw: "document",
                                            taskHex: taskID.uuidString,
                                            workspaceHex: workspaceID.uuidString,
                                            logicalPath: "media/clip.mp4"),
                       Int64(G04SourceHostStatus.invalidArguments))
        XCTAssertEqual(host.egressOpenMedia(epoch: boot.epoch, kindRaw: "video",
                                            taskHex: taskID.uuidString,
                                            workspaceHex: workspaceID.uuidString,
                                            logicalPath: "media/notes.txt"),
                       Int64(G04SourceHostStatus.invalidArguments))
    }

    func testHostMediaEgressRefusesSparseOverCapBeforeReading() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        // Sparse files: an 8 GiB+1 body would be impossible to allocate in a
        // test, but the cap is checked from fstat BEFORE the single hash pass,
        // so this refusal is immediate and proves "reject before copy/read".
        _ = try sparseWorkspaceFile("media/huge.mp4", taskID: taskID,
                                    size: G04WorkspaceMediaKind.maximumVideoBytes + 1)
        XCTAssertEqual(host.egressOpenMedia(epoch: boot.epoch, kindRaw: "video",
                                            taskHex: taskID.uuidString,
                                            workspaceHex: workspaceID.uuidString,
                                            logicalPath: "media/huge.mp4"),
                       Int64(G04SourceHostStatus.sizeExceeded))
        _ = try sparseWorkspaceFile("media/huge.png", taskID: taskID,
                                    size: G04WorkspaceMediaKind.maximumImageBytes + 1)
        XCTAssertEqual(host.egressOpenMedia(epoch: boot.epoch, kindRaw: "image",
                                            taskHex: taskID.uuidString,
                                            workspaceHex: workspaceID.uuidString,
                                            logicalPath: "media/huge.png"),
                       Int64(G04SourceHostStatus.sizeExceeded))
        _ = try sparseWorkspaceFile("media/huge.wav", taskID: taskID,
                                    size: G04WorkspaceMediaKind.maximumAudioBytes + 1)
        XCTAssertEqual(host.egressOpenMedia(epoch: boot.epoch, kindRaw: "audio",
                                            taskHex: taskID.uuidString,
                                            workspaceHex: workspaceID.uuidString,
                                            logicalPath: "media/huge.wav"),
                       Int64(G04SourceHostStatus.sizeExceeded))
    }

    func testHostMediaEgressCancellationRefusesAndCloseReleasesTheLease() async throws {
        let boot = try await bootInstalledGeneration()
        let host = G04WorkspaceSourceHost.shared
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        _ = try writeWorkspaceFile("media/clip.mov", taskID: taskID,
                                   bytes: Data(repeating: 9, count: 300_000))
        let ticket = host.egressOpenMedia(epoch: boot.epoch, kindRaw: "video",
                                          taskHex: taskID.uuidString,
                                          workspaceHex: workspaceID.uuidString,
                                          logicalPath: "media/clip.mov")
        XCTAssertGreaterThan(ticket, 0)
        // The exact call `beginGenerationRetirement` uses for every G04
        // operation: real Root retirement cancels this owned-work lease.
        let (domain, _) = try XCTUnwrap(RunDomainFacade.current(epoch: boot.epoch))
        await domain.cancelG04WorkspaceOperations(conversationID: taskID)
        var page = [UInt8](repeating: 0, count: 1024)
        let refused = host.egressRead(ticket: ticket, offset: 0, buffer: &page,
                                      capacity: Int32(page.count))
        XCTAssertLessThan(refused, 0)
        XCTAssertEqual(host.egressClose(ticket: ticket), G04SourceHostStatus.ok)
        // Nothing remains live, and the retired ticket never re-admits reads.
        XCTAssertEqual(host.egressRead(ticket: ticket, offset: 0, buffer: &page,
                                       capacity: Int32(page.count)),
                       G04SourceHostStatus.generationFenced)
    }
}
