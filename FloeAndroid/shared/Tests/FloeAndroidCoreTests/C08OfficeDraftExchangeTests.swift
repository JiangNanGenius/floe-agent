import XCTest
@testable import FloeAndroidCore
import FloeAndroidDataExchange

/// Authored NOTRUN regression source for C08 retained Office recovery content.
/// Main runs the focused XCTest filter after the unified build.
final class C08OfficeDraftExchangeTests: XCTestCase {
    private var root: URL!
    private var workingRoot: URL!
    private var outputsRoot: URL!
    private var restoredRoot: URL!
    private var workRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "c08-office-draft-\(UUID().uuidString)", isDirectory: true)
        workingRoot = root.appendingPathComponent("working", isDirectory: true)
        outputsRoot = root.appendingPathComponent("outputs", isDirectory: true)
        restoredRoot = root.appendingPathComponent("restored", isDirectory: true)
        workRoot = root.appendingPathComponent("work", isDirectory: true)
        for directory in [workingRoot!, outputsRoot!, restoredRoot!, workRoot!] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func record(
        root: C08OfficeDraftCaptureRequest.Root,
        path: String,
        kind: C07OfficeDraftKind,
        bytes: Int64,
        sha256: String,
        format: String = "docx",
        displayName: String = "Quarterly report.docx"
    ) -> C08OfficeDraftCaptureRequest.Record {
        C08OfficeDraftCaptureRequest.Record(
            root: root, relativePath: path, kind: kind,
            displayName: displayName, format: format,
            byteCount: bytes, sha256: sha256,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    /// Working/export dedupe: identical bytes are carried once, preferring
    /// the module-verified export provenance.
    func testIdenticalWorkingAndVerifiedExportAreCarriedOnce() throws {
        let bytes = Data("PK\u{3}\u{4}verified-docx".utf8)
        let sha = C07Digest.sha256(bytes)
        let session = UUID().uuidString
        try write(bytes, to: workingRoot
            .appendingPathComponent(session)
            .appendingPathComponent("document.docx"))
        try write(bytes, to: outputsRoot
            .appendingPathComponent("7")
            .appendingPathComponent("op-1.docx"))
        let request = C08OfficeDraftCaptureRequest(records: [
            record(root: .outputs, path: "7/op-1.docx",
                   kind: .verifiedOutput, bytes: Int64(bytes.count), sha256: sha),
            record(root: .working, path: "\(session)/document.docx",
                   kind: .workingCopy, bytes: Int64(bytes.count), sha256: sha),
        ])
        var omissions = C07OmissionCollector()
        var counts = C07OwnedDataCounts()
        var warnings: [String] = []
        let captured = try C08OfficeDraftExchange.capture(
            request: request, workingRoot: workingRoot,
            outputsRoot: outputsRoot, restoredRoot: restoredRoot,
            workRoot: workRoot,
            omissions: &omissions, counts: &counts, warnings: &warnings)
        let section = try XCTUnwrap(captured)
        XCTAssertEqual(section.catalog.records.count, 1)
        XCTAssertEqual(try XCTUnwrap(section.catalog.records.first).kind, .verifiedOutput)
        XCTAssertEqual(section.section.deduplicated ?? -1, 1)
        XCTAssertEqual(counts.officeDrafts ?? -1, 1)
        XCTAssertEqual(counts.officeDraftBytes ?? -1, Int64(bytes.count))
        XCTAssertEqual(omissions.items.count, 0)
    }

    /// Missing and concurrently changed sources are explicit counted
    /// omissions, never a silent empty package or a mixed snapshot.
    func testMissingAndChangedSourcesBecomeCountedOmissions() throws {
        let bytes = Data("PK\u{3}\u{4}current-bytes".utf8)
        let sha = C07Digest.sha256(bytes)
        let session = UUID().uuidString
        try write(Data("different-length".utf8), to: workingRoot
            .appendingPathComponent(session)
            .appendingPathComponent("document.docx"))
        let request = C08OfficeDraftCaptureRequest(records: [
            record(root: .working, path: "\(session)/document.docx",
                   kind: .workingCopy, bytes: Int64(bytes.count), sha256: sha),
            record(root: .outputs, path: "3/missing-1.docx",
                   kind: .verifiedOutput, bytes: Int64(bytes.count), sha256: sha),
        ])
        var omissions = C07OmissionCollector()
        var counts = C07OwnedDataCounts()
        var warnings: [String] = []
        let captured = try C08OfficeDraftExchange.capture(
            request: request, workingRoot: workingRoot,
            outputsRoot: outputsRoot, restoredRoot: restoredRoot,
            workRoot: workRoot,
            omissions: &omissions, counts: &counts, warnings: &warnings)
        XCTAssertNil(captured)
        XCTAssertEqual(omissions.items.count, 2)
        XCTAssertEqual(Set(omissions.items.map(\.reason)),
                       Set(["changedDuringCapture", "missing"]))
        XCTAssertEqual(counts.officeDrafts ?? -1, 0)
    }

    /// An unsafe path identity is refused before any read; it may not become
    /// new authority just because the journal claimed it.
    func testUnsafeRelativePathIsAnExplicitOmission() throws {
        let request = C08OfficeDraftCaptureRequest(records: [
            record(root: .working, path: "../outside/document.docx",
                   kind: .workingCopy, bytes: 4,
                   sha256: String(repeating: "a", count: 64)),
        ])
        var omissions = C07OmissionCollector()
        var counts = C07OwnedDataCounts()
        var warnings: [String] = []
        XCTAssertNil(try C08OfficeDraftExchange.capture(
            request: request, workingRoot: workingRoot,
            outputsRoot: outputsRoot, restoredRoot: restoredRoot,
            workRoot: workRoot,
            omissions: &omissions, counts: &counts, warnings: &warnings))
        XCTAssertEqual(omissions.items.first?.reason ?? "", "untrusted")
    }

    /// The package section is descriptive data only: exact bounded keys, no
    /// candidate/session/task/root/native-generation/URI/grant token.
    func testMetadataCarriesNoAuthorityOrSecretIdentity() throws {
        let bytes = Data("PK\u{3}\u{4}content".utf8)
        let sha = C07Digest.sha256(bytes)
        let session = UUID().uuidString
        try write(bytes, to: workingRoot
            .appendingPathComponent(session)
            .appendingPathComponent("document.docx"))
        let request = C08OfficeDraftCaptureRequest(records: [
            record(root: .working, path: "\(session)/document.docx",
                   kind: .workingCopy, bytes: Int64(bytes.count), sha256: sha,
                   displayName: "C:\\Users\\alice\\Q3 report.docx"),
        ])
        var omissions = C07OmissionCollector()
        var counts = C07OwnedDataCounts()
        var warnings: [String] = []
        let captured = try XCTUnwrap(try C08OfficeDraftExchange.capture(
            request: request, workingRoot: workingRoot,
            outputsRoot: outputsRoot, restoredRoot: restoredRoot,
            workRoot: workRoot,
            omissions: &omissions, counts: &counts, warnings: &warnings))
        let data = try Data(contentsOf: captured.metadataURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["records"]))
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let keys = Set(try XCTUnwrap(records.first).keys)
        XCTAssertEqual(keys, Set([
            "entry", "kind", "displayName", "format", "byteCount",
            "sha256", "createdAt", "updatedAt", "ownership",
        ]))
        let encoded = String(decoding: data, as: UTF8.self)
        for forbidden in [
            session, "Users", "candidate", "sessionToken", "taskId",
            "workspaceId", "nativeEpoch", "generation", "destination",
            "grant", "originalUri",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
        let record = try XCTUnwrap(captured.catalog.records.first)
        XCTAssertFalse(record.displayName.contains("\\"))
        XCTAssertEqual(record.ownership, "appOwnedOfficeRecovery")
        XCTAssertNoThrow(try captured.section.validate())
        XCTAssertNoThrow(try captured.catalog.validate())
    }

    /// Restore allocates fresh IDs/files, writes a durable read-only manifest
    /// and never touches an existing directory or a recovery journal.
    func testRestoreCreatesFreshDocumentsAndManifest() throws {
        let bytes = Data("PK\u{3}\u{4}restore-me".utf8)
        let sha = C07Digest.sha256(bytes)
        let session = UUID().uuidString
        try write(bytes, to: workingRoot
            .appendingPathComponent(session)
            .appendingPathComponent("document.docx"))
        var omissions = C07OmissionCollector()
        var counts = C07OwnedDataCounts()
        var warnings: [String] = []
        let captured = try XCTUnwrap(try C08OfficeDraftExchange.capture(
            request: C08OfficeDraftCaptureRequest(records: [
                record(root: .working, path: "\(session)/document.docx",
                       kind: .workingCopy, bytes: Int64(bytes.count),
                       sha256: sha),
            ]),
            workingRoot: workingRoot, outputsRoot: outputsRoot,
            restoredRoot: restoredRoot, workRoot: workRoot,
            omissions: &omissions, counts: &counts,
            warnings: &warnings))
        let restoreID = UUID()
        let restoreRoot = root.appendingPathComponent(
            "restored/\(restoreID.uuidString)", isDirectory: true)
        let documentID = UUID()
        let entry = C07OfficeDraftPlanEntry(
            documentID: documentID,
            sourceEntry: try XCTUnwrap(captured.catalog.records.first?.entry),
            displayName: "Restored report.docx",
            format: "docx", kind: .workingCopy,
            byteCount: Int64(bytes.count), sha256: sha)
        let committed = try C08OfficeDraftExchange.commitRestoredDocuments(
            entries: [entry], staged: C07StagedOfficeDraftSection(
                section: captured.section, catalog: captured.catalog,
                metadataURL: captured.metadataURL, contents: captured.contents),
            restoreRoot: restoreRoot, restoreID: restoreID)
        XCTAssertEqual(committed.count, 1)
        XCTAssertNotEqual(documentID.uuidString, session)
        let restored = restoreRoot.appendingPathComponent(
            "\(documentID.uuidString).docx")
        XCTAssertEqual(try Data(contentsOf: restored), bytes)
        let manifestData = try Data(contentsOf: restoreRoot
            .appendingPathComponent("manifest.json"))
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifestObject["schema"] as? String ?? "",
                       "floe.office-restored/1")
        let documents = try XCTUnwrap(
            manifestObject["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.first?["documentID"] as? String ?? "",
                       documentID.uuidString)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workRoot
                .appendingPathComponent("recovery-journal.json").path))

        // The consumer-visible marker is written only after the owned-data
        // commit succeeds.
        try C08OfficeDraftExchange.markRestoreCommitted(
            restoreRoot: restoreRoot, restoreID: restoreID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoreRoot
            .appendingPathComponent("complete.json").path))

        // An existing restore directory is a collision, never an overwrite.
        XCTAssertThrowsError(try C08OfficeDraftExchange.commitRestoredDocuments(
            entries: [entry],
            staged: C07StagedOfficeDraftSection(
                section: captured.section, catalog: captured.catalog,
                metadataURL: captured.metadataURL, contents: captured.contents),
            restoreRoot: restoreRoot, restoreID: restoreID))
    }

    /// A document created by an earlier restore is persisted user content and
    /// must enter a later full backup instead of silently disappearing.
    func testPreviouslyRestoredDocumentIsCarriedAgain() throws {
        let restoreID = UUID()
        let documentID = UUID()
        let bytes = Data("PK\u{3}\u{4}restored-copy".utf8)
        let sha = C07Digest.sha256(bytes)
        try write(bytes, to: restoredRoot
            .appendingPathComponent(restoreID.uuidString)
            .appendingPathComponent("\(documentID.uuidString).docx"))
        let request = C08OfficeDraftCaptureRequest(records: [
            record(root: .restored,
                   path: "\(restoreID.uuidString)/\(documentID.uuidString).docx",
                   kind: .verifiedOutput, bytes: Int64(bytes.count), sha256: sha),
        ])
        var omissions = C07OmissionCollector()
        var counts = C07OwnedDataCounts()
        var warnings: [String] = []
        let captured = try XCTUnwrap(try C08OfficeDraftExchange.capture(
            request: request, workingRoot: workingRoot,
            outputsRoot: outputsRoot, restoredRoot: restoredRoot,
            workRoot: workRoot, omissions: &omissions,
            counts: &counts, warnings: &warnings))
        XCTAssertEqual(captured.catalog.records.count, 1)
        XCTAssertEqual(try XCTUnwrap(captured.catalog.records.first).kind, .verifiedOutput)
        XCTAssertTrue(captured.catalog.records.first?.entry
            .hasPrefix("artifacts/office-drafts/") == true)
        XCTAssertEqual(omissions.items.count, 0)
    }

    /// Old plans and manifests without the optional Office section still
    /// decode; only a plan that actually carries it restores documents.
    func testOldArchiveWithoutOfficeSectionStillDecodes() throws {
        let plan = C07OwnedDataRestorePlanFile(
            restoreID: UUID(), idMap: C07IDMap(),
            artifactRoots: [], attachmentPaths: [:], workspaceIDs: [],
            counts: C07OwnedDataCounts(), warnings: [])
        let decoded = try C07OwnedDataRestorePlanFile.decode(plan.encoded())
        XCTAssertNil(decoded.officeDrafts)

        var tables: [C07OwnedTableRecord] = []
        for name in C07OwnedDataPolicy.mandatoryTableNames(forSchema: 52).sorted() {
            tables.append(C07OwnedTableRecord(
                name: name, entry: c07OwnedTableEntry(name), rowCount: 0,
                byteCount: 0, sha256: String(repeating: "a", count: 64)))
        }
        let manifest = C07OwnedDataManifest(
            sourceAppSchemaVersion: 52, tables: tables,
            workspaceCount: 0, workspaceByteCount: 0,
            workspaceSHA256: String(repeating: "b", count: 64),
            counts: C07OwnedDataCounts(),
            excluded: C07ScopePolicy.excluded,
            linuxCheckpointPort: "unavailable")
        XCTAssertNil(manifest.officeDrafts)
        XCTAssertNoThrow(try C07OwnedDataManifest.decode(
            manifest.encoded()).validate())
    }
}
