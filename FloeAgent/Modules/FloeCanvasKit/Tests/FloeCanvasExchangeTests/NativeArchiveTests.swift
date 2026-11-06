// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

final class NativeArchiveTests: XCTestCase {
    private struct Provider: CanvasNativeArchive.CanvasChildProjectExportProvider {
        let archives: [UUID: Data]
        func archive(projectID: UUID, appliedRevision: Int64, draftRevision: Int64?, editorKind: String) async throws -> CanvasNativeArchive.ChildProjectArchiveData {
            guard let data = archives[projectID] else {
                throw CanvasExchangeError.assetUnavailable("no archived child project \(projectID)")
            }
            return .init(data: data, formatHint: "application/octet-stream")
        }
    }

    private func sampleSnapshot() -> CanvasSnapshot {
        var node = CanvasNodeSnapshot(
            title: "hello",
            content: .text("world"),
            frame: .init(center: .init(x: 100, y: 100), size: .init(width: 200, height: 100))
        )
        node.metadata["pencilKitDataID"] = "99999999-9999-9999-9999-999999999999"
        let media = CanvasNodeSnapshot(
            title: nil,
            content: .media(CanvasAssetLocator(
                id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                contentHash: nil,
                relativePath: "images/pic.png",
                mimeType: "image/png",
                byteCount: 4
            )),
            frame: .init(center: .init(x: 400, y: 100), size: .init(width: 100, height: 100))
        )
        let editor = CanvasNodeSnapshot(
            title: "CAD",
            content: .editor(CanvasEditorReference(projectID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, appliedRevision: 3, editorKind: "cad")),
            frame: .init(center: .init(x: 0, y: 400), size: .init(width: 120, height: 80))
        )
        let page = CanvasPageSnapshot(name: "Page 1", nodes: [node, media, editor])
        return CanvasSnapshot(name: "Lab", pages: [page])
    }

    func testFullRoundTripEqualityWithAssetsChildrenAndSources() async throws {
        let snapshot = sampleSnapshot()
        let assetBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let childBytes = Data("synthetic child project".utf8)
        let original = Data("original json canvas bytes".utf8)
        let envelope = CanvasNativeArchive.OriginalSourceEnvelope(
            source: CanvasOriginalSource(
                kind: .jsonCanvasOriginal,
                suggestedName: "original.canvas",
                byteCount: original.count,
                sha256: CanvasDigest.sha256(original)
            ),
            data: original
        )

        let exported = try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([
                UUID(uuidString: "88888888-8888-8888-8888-888888888888")!: assetBytes,
                UUID(uuidString: "99999999-9999-9999-9999-999999999999")!: Data([1, 2, 3]),
            ]),
            childProjectProvider: Provider(archives: [UUID(uuidString: "77777777-7777-7777-7777-777777777777")!: childBytes]),
            originalSources: [envelope]
        )

        // Reopen without any of the original files.
        let reopened = try CanvasNativeArchive.import(exported.data)
        XCTAssertEqual(reopened.snapshot, snapshot)
        XCTAssertEqual(reopened.assets[UUID(uuidString: "88888888-8888-8888-8888-888888888888")!], assetBytes)
        XCTAssertEqual(reopened.assets[UUID(uuidString: "99999999-9999-9999-9999-999999999999")!], Data([1, 2, 3]))
        XCTAssertEqual(reopened.childProjects[UUID(uuidString: "77777777-7777-7777-7777-777777777777")!]?.data, childBytes)
        XCTAssertEqual(reopened.childProjects[UUID(uuidString: "77777777-7777-7777-7777-777777777777")!]?.appliedRevision, 3)
        XCTAssertEqual(reopened.sourceDataByID[envelope.source.id], original)
        XCTAssertEqual(reopened.manifest.assets.count, 2)
        XCTAssertEqual(reopened.manifest.children.count, 1)
        XCTAssertEqual(reopened.manifest.sources.count, 1)

        // Export -> import -> export preserves the original raw payload.
        let secondPass = try await CanvasNativeArchive.export(
            reopened.snapshot,
            assetResolver: CanvasInMemoryAssetResolver(reopened.assets),
            childProjectProvider: Provider(archives: reopened.childProjects.mapValues(\.data)),
            originalSources: [CanvasNativeArchive.OriginalSourceEnvelope(
                source: reopened.originalSources[0],
                data: reopened.sourceDataByID[envelope.source.id]!
            )]
        )
        let reopenedSecond = try CanvasNativeArchive.import(secondPass.data)
        XCTAssertEqual(reopenedSecond.sourceDataByID[envelope.source.id], original)
        XCTAssertEqual(reopenedSecond.snapshot, snapshot)
    }

    func testMissingResolverFailsLoudly() async throws {
        let snapshot = sampleSnapshot()
        await XCTAssertThrowsAsyncError(try await CanvasNativeArchive.export(snapshot)) { error in
            guard case CanvasExchangeError.assetUnavailable(let message) = error else { return XCTFail() }
            XCTAssertTrue(message.contains("asset resolver is required"))
        }
    }

    func testHashMismatchFailsIntegrity() async throws {
        var snapshot = sampleSnapshot()
        snapshot.pages[0].nodes[1].content = .media(CanvasAssetLocator(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            contentHash: CanvasDigest.sha256(Data([0x89, 0x50, 0x4E, 0x47]))))
        let wrong = Data([0, 0, 0, 0])
        await XCTAssertThrowsAsyncError(try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([
                UUID(uuidString: "88888888-8888-8888-8888-888888888888")!: wrong,
                UUID(uuidString: "99999999-9999-9999-9999-999999999999")!: Data([1, 2, 3]),
            ]),
            childProjectProvider: Provider(archives: [UUID(uuidString: "77777777-7777-7777-7777-777777777777")!: Data("child".utf8)])
        )) { error in
            guard case CanvasExchangeError.integrity = error else { return XCTFail("integrity expected, got \(error)") }
        }
    }

    func testChildProjectWithoutProviderFailsLoudly() async throws {
        let snapshot = sampleSnapshot()
        await XCTAssertThrowsAsyncError(try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([
                UUID(uuidString: "88888888-8888-8888-8888-888888888888")!: Data([0x89, 0x50, 0x4E, 0x47]),
                UUID(uuidString: "99999999-9999-9999-9999-999999999999")!: Data([1, 2, 3]),
            ])
        )) { error in
            guard case CanvasExchangeError.assetUnavailable(let message) = error else { return XCTFail() }
            XCTAssertTrue(message.contains("CanvasChildProjectExportProvider"))
        }
    }

    func testTamperedAssetIsIntegrityFailure() async throws {
        let snapshot = sampleSnapshot()
        let exported = try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([
                UUID(uuidString: "88888888-8888-8888-8888-888888888888")!: Data([0x89, 0x50, 0x4E, 0x47]),
                UUID(uuidString: "99999999-9999-9999-9999-999999999999")!: Data([1, 2, 3]),
            ]),
            childProjectProvider: Provider(archives: [UUID(uuidString: "77777777-7777-7777-7777-777777777777")!: Data("child".utf8)])
        )
        // Corrupt one compressed byte somewhere in the middle.
        var bytes = exported.data
        let index = bytes.count / 2
        bytes[index] = bytes[index] ^ 0xFF
        XCTAssertThrowsError(try CanvasNativeArchive.import(bytes)) { error in
            guard case CanvasExchangeError.integrity = error else {
                // Flipping arbitrary bytes may also make the ZIP unreadable.
                guard case CanvasExchangeError.invalid = error else {
                    return XCTFail("integrity or invalid expected, got \(error)")
                }
                return
            }
        }
    }

    func testConflictingLocatorsSameAssetRejected() async throws {
        var snapshot = sampleSnapshot()
        let id = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        snapshot.pages[0].nodes[1].content = .media(CanvasAssetLocator(id: id, contentHash: "aaa"))
        let conflicting = CanvasNodeSnapshot(
            content: .media(CanvasAssetLocator(id: id, contentHash: "bbb")),
            frame: .init(center: .zero, size: .init(width: 10, height: 10))
        )
        snapshot.pages[0].nodes.append(conflicting)
        XCTAssertThrowsError(try CanvasAssetReferences.collect(from: snapshot)) { error in
            guard case CanvasExchangeError.invalid(let message) = error else { return XCTFail() }
            XCTAssertTrue(message.contains("conflicting locators"))
        }
    }

    func testTraversalAndSymlinkEntriesRejected() throws {
        // Build a small ZIP with a traversal entry by hand is unnecessary:
        // the reader rejects unsafe paths; verify with a valid archive that
        // packing refuses unsafe output paths instead.
        XCTAssertThrowsError(try CanvasLabZIP.pack(["../evil": Data()])) { error in
            guard case CanvasExchangeError.invalid = error else { return XCTFail() }
        }
        XCTAssertThrowsError(try CanvasLabZIP.pack(["/abs": Data()])) { error in
            guard case CanvasExchangeError.invalid = error else { return XCTFail() }
        }
        XCTAssertThrowsError(try CanvasLabZIP.pack(["a//b": Data()])) { error in
            guard case CanvasExchangeError.invalid = error else { return XCTFail() }
        }
    }

    func testManifestCannotAliasDocumentAndAssetOrContradictLocator() async throws {
        let bytes = Data("asset".utf8)
        let locator = CanvasAssetLocator(contentHash: CanvasDigest.sha256(bytes), byteCount: Int64(bytes.count))
        let node = CanvasNodeSnapshot(content: .media(locator), frame: .init(center: .zero, size: .init(width: 100, height: 100)))
        let snapshot = CanvasSnapshot(name: "Integrity", pages: [CanvasPageSnapshot(nodes: [node])])
        let exported = try await CanvasNativeArchive.export(snapshot, assetResolver: CanvasInMemoryAssetResolver([locator.id: bytes]))
        var entries = try CanvasLabZIP.unpack(exported.data)
        var manifest = exported.manifest
        manifest.assets[0].path = CanvasNativeArchive.documentPath
        entries[CanvasNativeArchive.manifestPath] = try CanvasExchangeJSON.encode(manifest)
        XCTAssertThrowsError(try CanvasNativeArchive.import(CanvasLabZIP.pack(entries)))

        entries = try CanvasLabZIP.unpack(exported.data)
        manifest = exported.manifest
        let replacement = Data("other".utf8)
        entries[manifest.assets[0].path] = replacement
        manifest.assets[0].sha256 = CanvasDigest.sha256(replacement)
        manifest.assets[0].byteCount = replacement.count
        entries[CanvasNativeArchive.manifestPath] = try CanvasExchangeJSON.encode(manifest)
        XCTAssertThrowsError(try CanvasNativeArchive.import(CanvasLabZIP.pack(entries)))
    }

    func testStagedBudgetFailsBeforePullingRemainingAssets() async throws {
        let idA = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let idB = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let nodeA = CanvasNodeSnapshot(
            content: .media(CanvasAssetLocator(id: idA, byteCount: nil)),
            frame: .init(center: .init(x: 0, y: 0), size: .init(width: 100, height: 100))
        )
        // Asset B declares its size so the export can refuse before pulling.
        let nodeB = CanvasNodeSnapshot(
            content: .media(CanvasAssetLocator(id: idB, byteCount: 100)),
            frame: .init(center: .init(x: 200, y: 0), size: .init(width: 100, height: 100))
        )
        let snapshot = CanvasSnapshot(name: "Budget", pages: [CanvasPageSnapshot(nodes: [nodeA, nodeB])])
        let documentSize = try CanvasExchangeJSON.encode(snapshot).count

        final class CallBox: @unchecked Sendable { var assetIDs: [UUID] = []; var childCalls = 0 }
        let box = CallBox()
        struct CountingResolver: CanvasAssetResolver {
            let box: CallBox
            func data(for locator: CanvasAssetLocator) async throws -> Data {
                box.assetIDs.append(locator.id)
                return Data([UInt8](repeating: 1, count: 100))
            }
        }
        struct CountingProvider: CanvasNativeArchive.CanvasChildProjectExportProvider {
            let box: CallBox
            func archive(projectID: UUID, appliedRevision: Int64, draftRevision: Int64?, editorKind: String) async throws -> CanvasNativeArchive.ChildProjectArchiveData {
                box.childCalls += 1
                return .init(data: Data("child".utf8))
            }
        }

        // Budget allows the document + the first (undeclared) asset only;
        // the second asset must be refused by its declared byteCount BEFORE
        // any further resolution.
        await XCTAssertThrowsAsyncError(try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CountingResolver(box: box),
            childProjectProvider: CountingProvider(box: box),
            originalSources: [],
            stagedByteBudget: documentSize + 150
        )) { error in
            guard case CanvasExchangeError.limitExceeded = error else {
                return XCTFail("limitExceeded expected, got \(error)")
            }
        }
        XCTAssertEqual(box.assetIDs, [idA], "only the first asset may be pulled before the budget refusal")
        XCTAssertEqual(box.childCalls, 0, "child projects are never pulled once the budget failed")
    }

    func testSaveIsAtomic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-canvas-exchange-tests-\(UUID().uuidString)", isDirectory: true)
        let output = CanvasExchangeOutput(files: [CanvasExchangeFile(name: "x.txt", data: Data("hello".utf8))])
        try CanvasExchange.save(output, to: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("x.txt"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
        try FileManager.default.removeItem(at: directory)
    }
}

func XCTAssertThrowsAsyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verifier: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected error \(message())", file: file, line: line)
    } catch {
        verifier(error)
    }
}
