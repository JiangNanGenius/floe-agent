// FloeAppTests — Shared Documents FileProvider bridge (S5 C4).
//
// PREPARED DEFINITIONS — deliberately NOT executed in this lane.
// The unified qualification run owns execution after the primary adds the
// FloeFileProvider adapter sources and this file to the AppTests target
// (exact membership patch in the lane handoff). No FileProvider domain is
// registered or mounted here; every case runs the real bridge against a
// private temp-root store and synthetic bytes.
//
// Coverage:
// * identifier mapping (root ↔ "root", malformed refused)
// * create: plain, collision (no blind rename), mayAlreadyExist idempotency
//   by digest, package/symlink templates refused
// * modify: rename/move, content replace, combined rename+content in ONE
//   atomic commit, base-version reconcile, failOnConflict
// * base versions: beforeFirstSync (real SDK header contract) applies
//   against the committed CAS base; malformed/garbage fails closed
// * delete: tombstone publish, non-empty folder, unknown-item success,
//   stale-base rejection, malformed-base refusal
// * fetchContents: leased immutable version+byte pairing, digest
//   verification, owned-temp cleanup on failure
// * cancel before commit preserves prior bytes; completion-once gate
// * working-set change batches with same-ID collapse to coherent final
//   state, tombstone deletions, anchor floor expiry
// * post-commit signal intents recorded through the injected seam
// * folder pagination returns stable pages with a terminal nil cursor
// * capabilities truthfully declared

#if canImport(UIKit)
import Foundation
import Testing
import FileProvider
import UniformTypeIdentifiers
import FloeCore
import FloePersistence

// MARK: - Fixtures

private func makeBridgeRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shared-documents-bridge-\(UUID().uuidString)", isDirectory: true)
}

private func makeSourceFile(_ bytes: Data, name: String = "payload.bin") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("shared-documents-bridge-src-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try bytes.write(to: url)
    return url
}

private final class TemplateItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType

    init(
        filename: String,
        parent: NSFileProviderItemIdentifier = .rootContainer,
        type: UTType = .data,
        identifier: NSFileProviderItemIdentifier? = nil
    ) {
        self.itemIdentifier = identifier ?? NSFileProviderItemIdentifier(UUID().uuidString)
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = type
    }
}

private func templateVersions(_ item: SharedDocumentsItem) throws -> NSFileProviderItemVersion {
    // Read the actual public protocol getter. The fixture never invents or
    // repairs version components on behalf of the production provider.
    let publicItem: any NSFileProviderItem = SharedDocumentsFileProviderItem(item: item)
    return try #require(publicItem.itemVersion)
}

/// Records post-commit signal intents injected through the bridge seam.
private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var containers: [SharedDocumentsSignalContainer] = []
    func record(_ container: SharedDocumentsSignalContainer) {
        lock.lock(); containers.append(container); lock.unlock()
    }
    func snapshot() -> [SharedDocumentsSignalContainer] {
        lock.lock(); defer { lock.unlock() }
        return containers
    }
}

private func makeBridge(
    at root: URL,
    recorder: SignalRecorder? = nil,
    materializationRoot: URL? = nil
) throws -> (SharedDocumentsFileProviderBridge, SQLiteSharedDocumentsStore) {
    let store = try SQLiteSharedDocumentsStore(root: root)
    let signals: (@Sendable (SharedDocumentsSignalContainer) -> Void)?
    if let recorder { signals = { recorder.record($0) } }
    else { signals = nil }
    let bridge = SharedDocumentsFileProviderBridge(
        store: store,
        signalProvider: signals,
        materializationRootProvider: { materializationRoot ?? FileManager.default.temporaryDirectory }
    )
    return (bridge, store)
}

// MARK: - Identity / capabilities

@Suite("FileProvider bridge identity")
struct FileProviderBridgeIdentityTests {
    @Test("root identifier round-trips; malformed identifiers are refused")
    func identityMapping() throws {
        #expect(try SharedDocumentsFileProviderIdentity.storeIdentifier(for: .rootContainer) == SharedDocumentsIdentity.rootItemID)
        #expect(SharedDocumentsFileProviderIdentity.providerIdentifier(for: SharedDocumentsIdentity.rootItemID) == .rootContainer)
        for bad in ["../escape", "a/b", ""] {
            #expect(throws: SharedDocumentsError.self) {
                try SharedDocumentsFileProviderIdentity.storeIdentifier(for: NSFileProviderItemIdentifier(bad))
            }
        }
    }

    @Test("capabilities reflect implemented operations only")
    func capabilitiesHonest() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let rootItem = try await bridge.item(for: .rootContainer)
        #expect(rootItem.capabilities.contains(.allowsContentEnumerating))
        #expect(rootItem.capabilities.contains(.allowsAddingSubItems))
        #expect(!rootItem.capabilities.contains(.allowsDeleting))
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "cap.txt", type: .plainText),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("cap".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let caps = try #require(created.item).capabilities
        #expect(caps.contains(.allowsReading))
        #expect(caps.contains(.allowsWriting))
        #expect(caps.contains(.allowsRenaming))
        #expect(caps.contains(.allowsDeleting))
    }
}

// MARK: - Create

@Suite("FileProvider bridge create")
struct FileProviderBridgeCreateTests {
    @Test("create stores committed bytes and reports stable identity")
    func createBasic() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let bytes = Data("created through the bridge".utf8)
        let outcome = try await bridge.create(
            basedOn: TemplateItem(filename: "bridge.txt", type: .plainText),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(bytes),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(outcome.item)
        #expect(item.filename == "bridge.txt")
        #expect(item.itemIdentifier != .rootContainer)
        #expect(item.documentSize == NSNumber(value: bytes.count))
        #expect(item.isUploaded)
        #expect(item.isDownloaded)
        let (url, fetched) = try await bridge.fetchContents(
            for: item.itemIdentifier,
            requestedVersion: nil
        )
        #expect(try Data(contentsOf: url) == bytes)
        #expect(fetched.itemIdentifier == item.itemIdentifier)
    }

    @Test("duplicate create reports a collision error carrying the committed item")
    func createCollision() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let first = try await bridge.create(
            basedOn: TemplateItem(filename: "dup.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("first".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        do {
            _ = try await bridge.create(
                basedOn: TemplateItem(filename: "DUP.txt"),
                fields: [.filename, .parentItemIdentifier, .contents],
                contents: try makeSourceFile(Data("second".utf8)),
                options: [],
                cancellation: SharedDocumentsBridgeCancellation(),
                progress: nil
            )
            Issue.record("collision unexpectedly succeeded")
        } catch SharedDocumentsBridgeError.collision(let existing) {
            #expect(existing.id == first.item?.itemIdentifier.rawValue)
        }
        let mapped = SharedDocumentsFileProviderErrorMapper.map(
            SharedDocumentsBridgeError.collision(existing: SharedDocumentsItem(
                id: "00000000-0000-0000-0000-0000000000AA",
                parentID: SharedDocumentsIdentity.rootItemID,
                name: "dup.txt",
                kind: .file,
                contentVersion: 1,
                metadataVersion: 1,
                byteCount: 5,
                sha256: nil,
                creationDate: Date(),
                modificationDate: Date()
            )),
            identifier: nil
        )
        #expect(mapped.domain == NSFileProviderErrorDomain)
        #expect(mapped.code == -1001) // NSFileProviderErrorFilenameCollision
    }

    @Test("mayAlreadyExist returns the committed item only for identical bytes")
    func createMayAlreadyExist() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let bytes = Data("identical".utf8)
        let first = try await bridge.create(
            basedOn: TemplateItem(filename: "reimport.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(bytes),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let again = try await bridge.create(
            basedOn: TemplateItem(filename: "reimport.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(bytes),
            options: [.mayAlreadyExist],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        #expect(again.item?.itemIdentifier == first.item?.itemIdentifier)
        // Different bytes under mayAlreadyExist is a real collision.
        await #expect(throws: SharedDocumentsBridgeError.self) {
            _ = try await bridge.create(
                basedOn: TemplateItem(filename: "reimport.txt"),
                fields: [.filename, .parentItemIdentifier, .contents],
                contents: try makeSourceFile(Data("different".utf8)),
                options: [.mayAlreadyExist],
                cancellation: SharedDocumentsBridgeCancellation(),
                progress: nil
            )
        }
    }

    @Test("symlink and package templates are refused")
    func createRefusesUnsupported() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let symlinkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await bridge.create(
                basedOn: TemplateItem(filename: "link", type: .symbolicLink),
                fields: [.filename, .parentItemIdentifier, .contents],
                contents: symlinkURL,
                options: [],
                cancellation: SharedDocumentsBridgeCancellation(),
                progress: nil
            )
        }
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await bridge.create(
                basedOn: TemplateItem(filename: "pkg", type: .package),
                fields: [.filename, .parentItemIdentifier],
                contents: nil,
                options: [],
                cancellation: SharedDocumentsBridgeCancellation(),
                progress: nil
            )
        }
    }
}

// MARK: - Modify / delete

@Suite("FileProvider bridge modify and delete")
struct FileProviderBridgeMutationTests {
    @Test("rename and content replace bump the right versions")
    func modifyRenameAndContent() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "edit.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("v1".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        let initialVersion = try templateVersions(stored)
        let renamed = try await bridge.modify(
            TemplateItem(filename: "renamed.txt", parent: .rootContainer, identifier: item.itemIdentifier),
            baseVersion: templateVersions(stored),
            changedFields: [.filename],
            contents: nil,
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        #expect(renamed.item?.filename == "renamed.txt")
        let renamedItem = try #require(renamed.item)
        let renamedVersion = try templateVersions(renamedItem.item)
        #expect(renamedVersion.contentVersion == initialVersion.contentVersion)
        #expect(renamedVersion.metadataVersion != initialVersion.metadataVersion)
        #expect(renamedVersion.contentVersion == Data("c1".utf8))
        #expect(renamedVersion.metadataVersion == Data("m2".utf8))
        let replaced = try await bridge.modify(
            TemplateItem(filename: "renamed.txt", parent: .rootContainer, identifier: item.itemIdentifier),
            baseVersion: templateVersions(try await store.item(id: item.itemIdentifier.rawValue)),
            changedFields: [.contents],
            contents: try makeSourceFile(Data("v2 content".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let final = try #require(replaced.item)
        #expect(final.item.contentVersion == 2)
        #expect(final.item.metadataVersion == 2)
        let finalVersion = try templateVersions(final.item)
        #expect(finalVersion.contentVersion != renamedVersion.contentVersion)
        #expect(finalVersion.contentVersion == Data("c2".utf8))
        #expect(finalVersion.metadataVersion == renamedVersion.metadataVersion)
        #expect(final.versionIdentifier == Data("c2.m2".utf8))
    }

    @Test("stale base version reconciles to the committed state")
    func modifyReconcile() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "stale.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("committed".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        // Retain the real previously published base, then let an actual
        // store writer commit a newer content version before the bridge call.
        let staleBase = try templateVersions(item.item)
        let newerStage = try await store.stageContentFromURL(
            makeSourceFile(Data("newer committed bytes".utf8)), cancellation: nil, progress: nil)
        let newer = try await store.commitReplace(id: item.item.id, stage: newerStage, expected: item.item.versions)
        #expect(newer.contentVersion == 2)
        let outcome = try await bridge.modify(
            TemplateItem(filename: "stale.txt", parent: .rootContainer, identifier: item.itemIdentifier),
            baseVersion: staleBase,
            changedFields: [.filename],
            contents: nil,
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        #expect(outcome.item?.itemIdentifier == item.itemIdentifier)
        #expect(outcome.shouldFetchContent)
        #expect(outcome.item?.item.contentVersion == newer.contentVersion)
        #expect(try await store.item(id: item.item.id) == newer)
        // With failOnConflict the same mismatch is a collision error.
        await #expect(throws: SharedDocumentsBridgeError.self) {
            _ = try await bridge.modify(
                TemplateItem(filename: "stale.txt", parent: .rootContainer, identifier: item.itemIdentifier),
                baseVersion: staleBase,
                changedFields: [.filename],
                contents: nil,
                options: [.failOnConflict],
                cancellation: SharedDocumentsBridgeCancellation(),
                progress: nil
            )
        }
    }

    @Test("delete publishes tombstones; unknown delete is success")
    func deleteFlows() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "gone.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("bye".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        let outcome = try await bridge.delete(
            identifier: item.itemIdentifier,
            baseVersion: templateVersions(stored),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation()
        )
        #expect(outcome.deletedIDs == [item.itemIdentifier.rawValue])
        // Unknown item delete succeeds per the framework contract.
        let unknown = try await bridge.delete(
            identifier: NSFileProviderItemIdentifier(UUID().uuidString),
            baseVersion: NSFileProviderItemVersion(
                contentVersion: Data("c1.m1".utf8),
                metadataVersion: Data("c1.m1".utf8)
            ),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation()
        )
        #expect(unknown.deletedIDs.isEmpty)
    }

    @Test("non-empty folder delete maps to directoryNotEmpty")
    func deleteNonEmptyFolder() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let folder = try await bridge.create(
            basedOn: TemplateItem(filename: "folder", type: .folder),
            fields: [.filename, .parentItemIdentifier],
            contents: nil,
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let folderItem = try #require(folder.item)
        _ = try await bridge.create(
            basedOn: TemplateItem(filename: "child.txt", parent: folderItem.itemIdentifier),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("c".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let stored = try await store.item(id: folderItem.itemIdentifier.rawValue)
        do {
            _ = try await bridge.delete(
                identifier: folderItem.itemIdentifier,
                baseVersion: templateVersions(stored),
                options: [],
                cancellation: SharedDocumentsBridgeCancellation()
            )
            Issue.record("non-empty delete unexpectedly succeeded")
        } catch let error as SharedDocumentsError {
            #expect(error == .folderNotEmpty(folderItem.itemIdentifier.rawValue))
            let mapped = SharedDocumentsFileProviderErrorMapper.map(error, identifier: folderItem.itemIdentifier)
            #expect(mapped.domain == NSFileProviderErrorDomain)
            #expect(mapped.code == -1007) // NSFileProviderErrorDirectoryNotEmpty
        }
        // Recursive option completes and publishes both tombstones.
        let recursive = try await bridge.delete(
            identifier: folderItem.itemIdentifier,
            baseVersion: templateVersions(try await store.item(id: folderItem.itemIdentifier.rawValue)),
            options: [.recursive],
            cancellation: SharedDocumentsBridgeCancellation()
        )
        #expect(recursive.deletedIDs.count == 2)
    }

    @Test("trash reparenting is refused as unsupported")
    func trashUnsupported() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "notrash.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("t".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await bridge.modify(
                TemplateItem(filename: "notrash.txt", parent: .trashContainer, identifier: item.itemIdentifier),
                baseVersion: templateVersions(stored),
                changedFields: [.parentItemIdentifier],
                contents: nil,
                options: [],
                cancellation: SharedDocumentsBridgeCancellation(),
                progress: nil
            )
        }
    }
}

// MARK: - Cancellation / completion-once / enumeration

@Suite("FileProvider bridge cancel and enumeration")
struct FileProviderBridgeCancelAndEnumerationTests {
    @Test("cancel during staging preserves the previously committed bytes")
    func cancelDuringReplace() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let original = Data("keep me".utf8)
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "cancel.me"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(original),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let cancellation = SharedDocumentsBridgeCancellation()
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await bridge.modify(
                TemplateItem(filename: "cancel.me", parent: .rootContainer, identifier: item.itemIdentifier),
                baseVersion: templateVersions(stored),
                changedFields: [.contents],
                contents: try makeSourceFile(Data(String(repeating: "x", count: 4_000_000).utf8)),
                options: [],
                cancellation: cancellation,
                progress: { bytes in if bytes > 0 { cancellation.cancel() } }
            )
        }
        #expect(cancellation.isCancelled())
        let after = try await store.item(id: item.itemIdentifier.rawValue)
        #expect(after.contentVersion == 1)
        let (url, _) = try await bridge.fetchContents(for: item.itemIdentifier, requestedVersion: nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("completion-once gate drops duplicate completions")
    func completionOnce() {
        let gate = SharedDocumentsCallOnce()
        var fired = 0
        gate.complete { fired += 1 }
        gate.complete { fired += 1 }
        #expect(fired == 1)
    }

    @Test("working-set change batches carry coherent per-ID final state and anchor expiry")
    func changeBatchFlows() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let start = try await bridge.currentAnchor()
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "chg.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("1".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        // Create + delete inside ONE window collapse to nothing: the system
        // never saw the item, so the coherent final state is invisibility.
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        _ = try await bridge.delete(
            identifier: item.itemIdentifier,
            baseVersion: templateVersions(stored),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation()
        )
        let batch = try await bridge.changeBatch(anchor: start, limit: 100)
        #expect(batch.updates.isEmpty)
        #expect(batch.deletions.isEmpty)
        #expect(batch.more == false)
        // A delete the system HAS seen (published in an earlier batch) is
        // still published as a tombstone.
        let seen = try await bridge.create(
            basedOn: TemplateItem(filename: "seen.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("2".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let seenItem = try #require(seen.item)
        let firstBatch = try await bridge.changeBatch(anchor: batch.nextAnchor, limit: 100)
        #expect(firstBatch.updates.contains { $0.itemIdentifier.rawValue == seenItem.itemIdentifier.rawValue })
        let seenStored = try await store.item(id: seenItem.itemIdentifier.rawValue)
        _ = try await bridge.delete(
            identifier: seenItem.itemIdentifier,
            baseVersion: templateVersions(seenStored),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation()
        )
        let secondBatch = try await bridge.changeBatch(anchor: firstBatch.nextAnchor, limit: 100)
        #expect(secondBatch.deletions.contains(seenItem.itemIdentifier))
        #expect(!secondBatch.updates.contains { $0.itemIdentifier.rawValue == seenItem.itemIdentifier.rawValue })
        // Prune to move the floor; the old anchor must expire.
        _ = try await store.pruneChanges(olderThan: Date().addingTimeInterval(60))
        do {
            _ = try await bridge.changeBatch(anchor: start, limit: 100)
            Issue.record("expired anchor unexpectedly succeeded")
        } catch let error as SharedDocumentsError {
            let mapped = SharedDocumentsFileProviderErrorMapper.mapChangeEnumerationError(error)
            #expect(mapped.domain == NSFileProviderErrorDomain)
            #expect(mapped.code == -1002) // NSFileProviderErrorSyncAnchorExpired
        }
    }

    @Test("folder pagination returns stable pages with a terminal nil cursor")
    func folderPagination() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        for index in 0..<7 {
            _ = try await bridge.create(
                basedOn: TemplateItem(filename: String(format: "p%02d.txt", index)),
                fields: [.filename, .parentItemIdentifier, .contents],
                contents: try makeSourceFile(Data([UInt8(index)])),
                options: [],
                cancellation: SharedDocumentsBridgeCancellation(),
                progress: nil
            )
        }
        var seen: [String] = []
        var cursor: Data? = nil
        repeat {
            let page = try await bridge.childrenPage(
                parentID: SharedDocumentsIdentity.rootItemID,
                cursorToken: cursor,
                limit: 3
            )
            seen.append(contentsOf: page.items.map(\.filename))
            cursor = page.nextCursorToken
        } while cursor != nil
        #expect(seen.count == 7)
        #expect(seen == seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}

// MARK: - Primary-review closure: base versions, atomic modify, signals,
// MARK - leased fetch, change-batch coherence

@Suite("FileProvider bridge primary-review closure")
struct FileProviderBridgeClosureTests {
    @Test("public independent versions and canonical equal legacy tokens round-trip a complete CAS pair")
    func publicVersionContract() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let created = try await bridge.create(basedOn: TemplateItem(filename: "versions.txt"),
            fields: [.filename, .parentItemIdentifier, .contents], contents: makeSourceFile(Data("v".utf8)),
            options: [], cancellation: SharedDocumentsBridgeCancellation(), progress: nil)
        let item = try #require(created.item)
        let published = try templateVersions(item.item)
        #expect(published.contentVersion == Data("c1".utf8))
        #expect(published.metadataVersion == Data("m1".utf8))
        #expect(SharedDocumentsFileProviderBridge.decodeBaseVersion(published) == .exact(item.item.versions))
        let legacy = try #require(item.versionIdentifier)
        #expect(legacy == Data("c1.m1".utf8))
        #expect(SharedDocumentsFileProviderBridge.decodeBaseVersion(NSFileProviderItemVersion(contentVersion: legacy, metadataVersion: legacy)) == .exact(item.item.versions))
        for (content, metadata) in [
            ("c1", "garbage"), ("garbage", "m1"), ("c1.m1", "c1.m2"),
            ("c1.m1", "m1"), ("c1", "c1.m1"), ("c01", "m1"),
            ("c+1", "m1"), ("c-1", "m1"), ("c1suffix", "m1"),
            ("c1", "m01"), ("c1", "m+1"), ("c1", "m-1"),
            ("c99999999999999999999999999", "m1"), ("c1.m1suffix", "c1.m1suffix")
        ] {
            #expect(SharedDocumentsFileProviderBridge.decodeBaseVersion(NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data(metadata.utf8))) == .malformed)
        }
        let special = NSFileProviderItemVersion.beforeFirstSyncComponent
        #expect(SharedDocumentsFileProviderBridge.decodeBaseVersion(NSFileProviderItemVersion(contentVersion: special, metadataVersion: published.metadataVersion)) == .malformed)
        #expect(SharedDocumentsFileProviderBridge.decodeBaseVersion(NSFileProviderItemVersion(contentVersion: published.contentVersion, metadataVersion: special)) == .malformed)
        // Check over-limit input at the parser boundary, without constructing
        // a framework object that itself forbids components above 128 bytes.
        #expect(SharedDocumentsFileProviderBridge.decodeVersionComponent(Data(("c" + String(repeating: "1", count: 128) + ".m1").utf8)) == nil)
        #expect(SharedDocumentsFileProviderBridge.decodeVersionComponent(Data([0xff, 0xfe])) == nil)
    }

    @Test("malformed base versions fail closed for modify and delete")
    func malformedBaseFailsClosed() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "guarded.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("guarded".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        let garbage = NSFileProviderItemVersion(
            contentVersion: Data("not-a-version".utf8),
            metadataVersion: Data("garbage".utf8)
        )
        await #expect(throws: SharedDocumentsBridgeError.self) {
            _ = try await bridge.modify(
                TemplateItem(filename: "guarded.txt", parent: .rootContainer, identifier: item.itemIdentifier),
                baseVersion: garbage,
                changedFields: [.filename],
                contents: nil,
                options: [],
                cancellation: SharedDocumentsBridgeCancellation(),
                progress: nil
            )
        }
        await #expect(throws: SharedDocumentsBridgeError.self) {
            _ = try await bridge.delete(
                identifier: item.itemIdentifier,
                baseVersion: garbage,
                options: [],
                cancellation: SharedDocumentsBridgeCancellation()
            )
        }
        // Nothing was written or deleted: the corrupt version granted no access.
        #expect(try await store.item(id: item.itemIdentifier.rawValue) == stored)
    }

    @Test("beforeFirstSync base applies against the committed CAS base")
    func beforeFirstSyncApplies() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "fresh.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("one".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let beforeFirstSync = NSFileProviderItemVersion(
            contentVersion: NSFileProviderItemVersion.beforeFirstSyncComponent,
            metadataVersion: NSFileProviderItemVersion.beforeFirstSyncComponent
        )
        let outcome = try await bridge.modify(
            TemplateItem(filename: "fresh.txt", parent: .rootContainer, identifier: item.itemIdentifier),
            baseVersion: beforeFirstSync,
            changedFields: [.contents],
            contents: try makeSourceFile(Data("two".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let final = try #require(outcome.item)
        #expect(final.item.contentVersion == 2)
        #expect(final.item.metadataVersion == 1)
    }

    @Test("combined rename+content modify commits once and signals affected containers")
    func combinedModifyAtomicWithSignals() async throws {
        let root = makeBridgeRoot()
        let recorder = SignalRecorder()
        let (bridge, store) = try makeBridge(at: root, recorder: recorder)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let folderA = try await bridge.create(
            basedOn: TemplateItem(filename: "A", type: .folder),
            fields: [.filename, .parentItemIdentifier],
            contents: nil,
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let folderB = try await bridge.create(
            basedOn: TemplateItem(filename: "B", type: .folder),
            fields: [.filename, .parentItemIdentifier],
            contents: nil,
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let folderAItem = try #require(folderA.item)
        let folderBItem = try #require(folderB.item)
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "move-me.txt", parent: folderAItem.itemIdentifier),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("v1".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let recordCountBeforeModify = recorder.snapshot().count
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        let modified = try await bridge.modify(
            TemplateItem(filename: "moved.txt", parent: folderBItem.itemIdentifier, identifier: item.itemIdentifier),
            baseVersion: templateVersions(stored),
            changedFields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("v2".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let final = try #require(modified.item)
        // ONE atomic commit: both versions bumped exactly once.
        #expect(final.item.contentVersion == 2)
        #expect(final.item.metadataVersion == 2)
        #expect(final.filename == "moved.txt")
        #expect(final.parentItemIdentifier == folderBItem.itemIdentifier)
        // Old parent, new parent and working set were signalled.
        let signals = Array(recorder.snapshot().dropFirst(recordCountBeforeModify))
        #expect(signals.contains(.item(folderAItem.itemIdentifier.rawValue)))
        #expect(signals.contains(.item(folderBItem.itemIdentifier.rawValue)))
        #expect(signals.contains(.workingSet))
    }

    @Test("change batch collapses same-ID rows to the coherent final state")
    func changeBatchCollapse() async throws {
        let root = makeBridgeRoot()
        let (bridge, store) = try makeBridge(at: root)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        // Born and died inside one batch window: invisible to the system.
        let start = try await bridge.currentAnchor()
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "ghost.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("g".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        _ = try await bridge.delete(
            identifier: item.itemIdentifier,
            baseVersion: templateVersions(stored),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation()
        )
        let ghostBatch = try await bridge.changeBatch(anchor: start, limit: 100)
        #expect(!ghostBatch.updates.contains { $0.itemIdentifier.rawValue == item.itemIdentifier.rawValue })
        #expect(!ghostBatch.deletions.contains(item.itemIdentifier))
        // Insert + rename in one window: a single update with the final name.
        let start2 = try await bridge.currentAnchor()
        let kept = try await bridge.create(
            basedOn: TemplateItem(filename: "first.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("k".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let keptItem = try #require(kept.item)
        let keptStored = try await store.item(id: keptItem.itemIdentifier.rawValue)
        _ = try await bridge.modify(
            TemplateItem(filename: "final.txt", parent: .rootContainer, identifier: keptItem.itemIdentifier),
            baseVersion: templateVersions(keptStored),
            changedFields: [.filename],
            contents: nil,
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let keptBatch = try await bridge.changeBatch(anchor: start2, limit: 100)
        let updatesForID = keptBatch.updates.filter { $0.itemIdentifier.rawValue == keptItem.itemIdentifier.rawValue }
        #expect(updatesForID.count == 1)
        #expect(updatesForID.first?.filename == "final.txt")
        #expect(!keptBatch.deletions.contains(keptItem.itemIdentifier))
    }

    @Test("fetchContents pairs the immutable version with the bytes and cleans owned temp")
    func fetchContentsPairingAndCleanup() async throws {
        let root = makeBridgeRoot()
        let materialization = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-documents-materialization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: materialization, withIntermediateDirectories: true)
        let (bridge, store) = try makeBridge(at: root, materializationRoot: materialization)
        defer {
            Task {
                try? await store.close()
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: materialization)
            }
        }
        let payload = Data("exact pairing".utf8)
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "pair.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(payload),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let (url, fetched) = try await bridge.fetchContents(
            for: item.itemIdentifier,
            requestedVersion: nil
        )
        #expect(try Data(contentsOf: url) == payload)
        #expect(fetched.itemIdentifier == item.itemIdentifier)
        // The returned item version describes exactly the returned bytes.
        #expect(fetched.versionIdentifier == Data("c1.m1".utf8))
        // A successful result belongs to the receiver until its bytes have
        // been consumed. The real extension passes this URL to FileProvider;
        // this direct bridge fixture owns and releases its successful copy.
        let successfulCopies = try FileManager.default.contentsOfDirectory(
            at: materialization, includingPropertiesForKeys: nil
        )
        #expect(successfulCopies.map(\.standardizedFileURL) == [url.standardizedFileURL])
        try FileManager.default.removeItem(at: url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: materialization.path).isEmpty)

        // Corrupt the committed bytes: fetch must fail AND remove its temp file.
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        let blob = root.appendingPathComponent("store/blobs/\(stored.id)/v1", isDirectory: false)
        try Data("tampered".utf8).write(to: blob)
        await #expect(throws: SharedDocumentsError.self) {
            _ = try await bridge.fetchContents(for: item.itemIdentifier, requestedVersion: nil)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: materialization,
            includingPropertiesForKeys: nil
        )
        #expect(leftovers.isEmpty)
    }

    @Test("create and delete signal parent and working set through the seam")
    func createAndDeleteSignal() async throws {
        let root = makeBridgeRoot()
        let recorder = SignalRecorder()
        let (bridge, store) = try makeBridge(at: root, recorder: recorder)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: root) } }
        let created = try await bridge.create(
            basedOn: TemplateItem(filename: "signal.txt"),
            fields: [.filename, .parentItemIdentifier, .contents],
            contents: try makeSourceFile(Data("s".utf8)),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation(),
            progress: nil
        )
        let item = try #require(created.item)
        let createSignals = recorder.snapshot()
        #expect(createSignals.contains(.item(SharedDocumentsIdentity.rootItemID)))
        #expect(createSignals.contains(.workingSet))
        let stored = try await store.item(id: item.itemIdentifier.rawValue)
        _ = try await bridge.delete(
            identifier: item.itemIdentifier,
            baseVersion: templateVersions(stored),
            options: [],
            cancellation: SharedDocumentsBridgeCancellation()
        )
        let deleteSignals = Array(recorder.snapshot().dropFirst(createSignals.count))
        #expect(deleteSignals.contains(.item(SharedDocumentsIdentity.rootItemID)))
        #expect(deleteSignals.contains(.workingSet))
    }
}
#endif
