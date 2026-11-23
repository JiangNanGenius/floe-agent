// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import FloeDeviceLink
@testable import FloeDeviceSync
import Foundation
import Testing

@Test func workspaceManifestRejectsAmbiguousAndReservedPaths() throws {
    let digest = DeviceWorkspaceDigest.hex(SHA256.hash(data: Data()))
    func file(_ path: String) -> DeviceWorkspaceEntry { .init(file: path, size: 0, digest: digest) }
    for path in ["../a", "/a", "a//b", "C:a", "a\\b", "Mounts/USB/a", "Network/share",
                 ".Git/config", "nested/.ENV.local", "x/test.pem", "Floe Sync Conflicts/x"] {
        #expect(throws: DeviceHistorySyncError.invalidResponse) {
            try DeviceWorkspaceManifest(entries: [file(path)]).validated()
        }
    }
    for (first, second) in [("Demo/a", "demo/b"), ("é.txt", "e\u{0301}.txt"), ("file", "file/child")] {
        #expect(throws: DeviceHistorySyncError.invalidResponse) {
            try DeviceWorkspaceManifest(entries: [file(first), file(second)]).validated()
        }
    }
    let normal = DeviceWorkspaceManifest(entries: [.init(directory: "项目"), file("项目/e\u{0301}.txt")])
    #expect(try normal.validated().entries.count == 2)
    #expect(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test(.timeLimit(.minutes(1)))
func workspaceFilesConvergeAndKeepConcurrentEditsAcrossRealPeers() async throws {
    try await withWorkspaces { left, right, leftRoot, rightRoot, leftAddress, rightAddress, taskID in
        let fm = FileManager.default
        let text = "Subfolder/notes.txt"
        let binary = Data(repeating: 0xA3, count: 1_121_381)
        try fm.createDirectory(at: leftRoot.appending(path: "Subfolder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: leftRoot.appending(path: "empty-folder"), withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: leftRoot.appending(path: text))
        try binary.write(to: leftRoot.appending(path: "asset.bin"))
        try Data().write(to: leftRoot.appending(path: "empty.txt"))
        try Data("local-only".utf8).write(to: leftRoot.appending(path: ".env"))
        try fm.createSymbolicLink(at: leftRoot.appending(path: "symlink"), withDestinationURL: leftRoot.appending(path: ".env"))

        // A peer sharing conversation history is not sharing files until it opts in.
        #expect(try await right.offers(from: leftAddress).first?.workspaceFiles == nil)
        await #expect(throws: DeviceHistorySyncError.notShared) {
            try await right.transferWorkspace(taskID, from: leftAddress) { _ in }
        }
        try await left.replaceShares([rightAddress.endpointID: [taskID]],
                                     workspaces: [rightAddress.endpointID: [taskID: "left"]])
        try await right.replaceShares([leftAddress.endpointID: [taskID]],
                                      workspaces: [leftAddress.endpointID: [taskID: "right"]])
        #expect(try await right.offers(from: leftAddress).first?.workspaceFiles == true)
        try await right.transferWorkspace(taskID, from: leftAddress) { _ in }
        #expect(try Data(contentsOf: rightRoot.appending(path: "asset.bin")) == binary)
        #expect(try Data(contentsOf: rightRoot.appending(path: "empty.txt")).isEmpty)
        #expect(fm.fileExists(atPath: rightRoot.appending(path: "empty-folder").path))
        #expect(!fm.fileExists(atPath: rightRoot.appending(path: ".env").path))
        #expect(!fm.fileExists(atPath: rightRoot.appending(path: "symlink").path))

        // Confirmation recorded the common version on the sender as well.
        try Data("right edit".utf8).write(to: rightRoot.appending(path: text), options: .atomic)
        try await left.transferWorkspace(taskID, from: rightAddress) { _ in }
        #expect(try String(contentsOf: leftRoot.appending(path: text), encoding: .utf8) == "right edit")
        try Data("left edit".utf8).write(to: leftRoot.appending(path: text), options: .atomic)
        try await right.transferWorkspace(taskID, from: leftAddress) { _ in }
        #expect(try String(contentsOf: rightRoot.appending(path: text), encoding: .utf8) == "left edit")

        try Data("mine".utf8).write(to: rightRoot.appending(path: text), options: .atomic)
        let theirs = Data("theirs".utf8)
        try theirs.write(to: leftRoot.appending(path: text), options: .atomic)
        try fm.removeItem(at: leftRoot.appending(path: "asset.bin"))
        let reports = ProgressRecorder()
        for _ in 0..<2 {
            try await right.transferWorkspace(taskID, from: leftAddress) { await reports.set($0) }
            #expect(await reports.last?.conflicts == 1)
            #expect(await reports.last?.savedFiles == 0)
        }
        let copies = rightRoot.appending(path: "Floe Sync Conflicts")
        let digest = DeviceWorkspaceDigest.hex(SHA256.hash(data: theirs))
        #expect(try fm.contentsOfDirectory(atPath: copies.path) == [digest])
        #expect(try Data(contentsOf: copies.appending(path: digest).appending(path: text)) == theirs)
        #expect(try String(contentsOf: rightRoot.appending(path: text), encoding: .utf8) == "mine")
        #expect(try Data(contentsOf: rightRoot.appending(path: "asset.bin")) == binary)
    }
}

@Test(.timeLimit(.minutes(1)))
func workspaceRevocationStopsAnOpenTransferAndRetryKeepsCommittedFiles() async throws {
    try await withWorkspaces { left, right, leftRoot, rightRoot, leftAddress, rightAddress, taskID in
        let shares = [rightAddress.endpointID: Set([taskID])]
        let permitted = [rightAddress.endpointID: [taskID: "left"]]
        let bytes = Data(repeating: 0x7E, count: 490_291)
        try Data("first".utf8).write(to: leftRoot.appending(path: "a.txt"))
        try bytes.write(to: leftRoot.appending(path: "b.bin"))
        try await left.replaceShares(shares, workspaces: permitted)
        await #expect(throws: DeviceHistorySyncError.notShared) {
            try await right.transferWorkspace(taskID, from: leftAddress) { value in
                if value.processed == 1 { try? await left.replaceShares(shares) }
            }
        }
        #expect(try String(contentsOf: rightRoot.appending(path: "a.txt"), encoding: .utf8) == "first")
        #expect(try FileManager.default.contentsOfDirectory(atPath: rightRoot.path) == ["a.txt"])
        #expect(try await right.offers(from: leftAddress).first?.workspaceFiles == nil)
        try await left.replaceShares(shares, workspaces: permitted)
        let reports = ProgressRecorder()
        try await right.transferWorkspace(taskID, from: leftAddress) { await reports.set($0) }
        #expect(await reports.last?.savedFiles == 1)
        #expect(try Data(contentsOf: rightRoot.appending(path: "b.bin")) == bytes)
    }
}

@Test func workspaceStageRejectsCorruptBytesAndChangedLocalBinding() async throws {
    let fixture = FileManager.default.temporaryDirectory.appending(path: "floe-workspace-staging-" + UUID().uuidString)
        .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let root = fixture.appending(path: "root")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binding = WorkspaceBindingFixture()
    let host = DeviceWorkspaceSyncHost(resolve: { _, _ in
        DeviceWorkspaceRoot(scope: "original", url: root, guardCurrent: { try await binding.validate() })
    }, ledgerDirectory: fixture.appending(path: "ledger"))
    let original = Data("valid".utf8)
    let digest = DeviceWorkspaceDigest.hex(SHA256.hash(data: original))
    let manifest = try DeviceWorkspaceManifest(entries: [
        .init(file: "report.txt", size: Int64(original.count), digest: digest)
    ]).validated()
    let taskID = UUID()
    await #expect(throws: DeviceHistorySyncError.invalidResponse) {
        try await host.receive(manifest, from: "peer", taskID: taskID, read: { _, _, _ in Data("other".utf8) },
            confirm: { _ in Issue.record("Corrupt bytes were acknowledged") }, onProgress: { _ in })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    await #expect(throws: DeviceHistorySyncError.notShared) {
        try await host.receive(manifest, from: "peer", taskID: taskID, read: { _, _, _ in
            await binding.change()
            return original
        }, confirm: { _ in Issue.record("Changed binding was acknowledged") }, onProgress: { _ in })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func conversationAndFilesContinueOnTheSameConnection(paged: Bool, revokeFilesAfterHistory: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "floe-combined-sync-" + UUID().uuidString)
        .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbound = directory.appending(path: "outbound")
    let inbound = directory.appending(path: "inbound")
    for root in [outbound, inbound] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let bytes = Data(repeating: 0xA7, count: DeviceWorkspaceManifest.chunkSize + 17)
    try bytes.write(to: outbound.appending(path: "asset.bin"))
    let taskID = UUID()
    let identity = FloeDeviceLinkIdentity.generate()
    let localIdentity = FloeDeviceLinkIdentity.generate()
    let savedKey = localIdentity.privateKeyBytes()
    let shares = [localIdentity.endpointID: Set([taskID])]
    let senderLink = try await FloeDeviceLink.bind(identity: identity, trustedEndpointIDs: [localIdentity.endpointID],
                                                  relay: .disabled, bindAddress: "127.0.0.1:0")
    let history = Data([3])
    let exportPage: @Sendable (UUID, String?, Int64?) async throws -> DeviceHistoryPage = { _, _, _ in
        .init(archive: history, nextCursor: "received", through: 1, hasMore: false)
    }
    let source = DeviceHistorySource(list: { _ in [.init(id: taskID, title: "Fixture")] },
                                     export: { _ in history }, exportPage: paged ? exportPage : nil)
    let sender = DeviceHistorySync(link: senderLink, shares: shares, source: source, workspaceHost: .init(resolve: { _, _ in
        .init(scope: "outbound", url: outbound, guardCurrent: {})
    }, ledgerDirectory: directory.appending(path: "outbound-ledger")), workspaceShares: [localIdentity.endpointID: [taskID: "outbound"]])
    await sender.start()
    let importHistory: @MainActor @Sendable (UUID, Data) async throws -> Int = { id, data in
        #expect(id == taskID && data == history)
        if revokeFilesAfterHistory { try await sender.replaceShares(shares) }
        // The authenticated connection can finish, but the peer refuses any new dial.
        try senderLink.replaceTrustedEndpointIDs([])
        return 1
    }
    let destination: DeviceHistoryPageDestination? = paged ? .init(cursor: { _, _ in nil }, commit: { peerID, id, data, cursor in
        #expect(peerID == identity.endpointID && cursor == "received")
        return try await importHistory(id, data)
    }) : nil
    let receiver = DeviceHistorySyncCenter(settingsURL: directory.appending(path: "settings.json"),
        identityStorage: .init(load: { savedKey }, save: { _ in Issue.record("Unexpected replacement identity") }),
        source: .init(list: { _ in [] }, export: { _ in Data() }), localTasks: { [] }, importHistory: { id, data in
            #expect(!paged, "A paged peer should be imported through the page destination")
            return try await importHistory(id, data)
        }, pagedHistory: destination, workspaceHost: .init(resolve: { _, _ in
            .init(scope: "inbound", url: inbound, guardCurrent: {})
        }, ledgerDirectory: directory.appending(path: "inbound-ledger")))
    await receiver.activate()
    await receiver.setEnabled(true)
    await receiver.pair(.init(address: senderLink.address()), named: "Fixture")
    await receiver.receive(taskID, from: identity.endpointID, includeWorkspace: true)

    #expect(receiver.status == .received(1))
    #expect(receiver.busy == false)
    if revokeFilesAfterHistory {
        #expect(receiver.workspaceResult == .interrupted(nil, .noLongerShared))
        #expect(!FileManager.default.fileExists(atPath: inbound.appending(path: "asset.bin").path))
    } else {
        if case .received(let report) = receiver.workspaceResult {
            #expect(report.savedFiles == 1)
        } else {
            Issue.record("Both phases must finish over the already authenticated connection")
        }
        #expect((try? Data(contentsOf: inbound.appending(path: "asset.bin"))) == bytes)
    }
    await receiver.pause()
    await sender.stop()
}

private actor WorkspaceBindingFixture {
    private var current = true
    func change() { current = false }
    func validate() throws {
        guard current else { throw DeviceHistorySyncError.notShared }
    }
}

private actor ProgressRecorder {
    private(set) var last: DeviceWorkspaceReceiveProgress?
    func set(_ value: DeviceWorkspaceReceiveProgress) { last = value }
}

private func withWorkspaces(
    body: (DeviceHistorySync, DeviceHistorySync, URL, URL, FloeDeviceLinkAddress, FloeDeviceLinkAddress, UUID) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "floe-workspace-link-" + UUID().uuidString)
        .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let leftRoot = directory.appending(path: "left")
    let rightRoot = directory.appending(path: "right")
    try FileManager.default.createDirectory(at: leftRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rightRoot, withIntermediateDirectories: true)
    let taskID = UUID()
    let first = FloeDeviceLinkIdentity.generate(), second = FloeDeviceLinkIdentity.generate()
    let leftLink = try await FloeDeviceLink.bind(identity: first, trustedEndpointIDs: [second.endpointID],
                                                relay: .disabled, bindAddress: "127.0.0.1:0")
    let rightLink = try await FloeDeviceLink.bind(identity: second, trustedEndpointIDs: [first.endpointID],
                                                 relay: .disabled, bindAddress: "127.0.0.1:0")
    let source = DeviceHistorySource(list: { _ in [.init(id: taskID, title: "Fixture")] }, export: { _ in Data([3]) })
    func workspace(root: URL, scope: String) -> DeviceWorkspaceSyncHost {
        DeviceWorkspaceSyncHost(resolve: { id, _ in
            guard id == taskID else { throw DeviceHistorySyncError.notShared }
            return DeviceWorkspaceRoot(scope: scope, url: root, guardCurrent: {})
        }, ledgerDirectory: directory.appending(path: scope + "-ledger"))
    }
    let left = DeviceHistorySync(link: leftLink, shares: [second.endpointID: [taskID]], source: source,
                                 workspaceHost: workspace(root: leftRoot, scope: "left"))
    let right = DeviceHistorySync(link: rightLink, shares: [first.endpointID: [taskID]], source: source,
                                  workspaceHost: workspace(root: rightRoot, scope: "right"))
    await left.start()
    await right.start()
    do {
        try await body(left, right, leftRoot, rightRoot, leftLink.address(), rightLink.address(), taskID)
    } catch {
        await left.stop()
        await right.stop()
        throw error
    }
    await left.stop()
    await right.stop()
}
