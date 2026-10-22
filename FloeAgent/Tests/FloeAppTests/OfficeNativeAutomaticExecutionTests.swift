// FloeAppTests — actual App-level Office automatic copy execution.
//
// This is the App integration acceptance for the authorized Office path: a
// frozen proposal + baseline + runtime-issued authorization runs the REAL
// pinned engine through the canonical App service host
// (`OfficeCommandCenter.applyAutomatic` → `OfficeAutomaticExecutor` with
// `OfficeServiceNativeSessionFactory.makeDefault()`) — no UI clicks, no
// fixture engine. The workbook is a REAL Office package that the pinned engine
// previously opened and saved (promo fixture origin, copied into the test
// bundle); a minimal synthetic package is not engine-loadable.
//
// Verified here:
//   * the original workbook bytes are unchanged and the published copy is a
//     NEW file with a matching receipt digest;
//   * a representative explicit command (Excel row insert) really lands in the
//     reopened package (row count read back by the bounded OOXML reader);
//   * exact Excel sort and AutoFilter persist the requested worksheet/range
//     through the real engine and survive engine reopen;
//   * `excel.recalculate` verifies persisted cached values through
//     `OfficeFormulaVerifier` on the reopened copy;
//   * an existing different output is refused without touching it;
//   * an authorization that is not bound to `document.office.edit`/`apply` is
//     refused before the engine is touched.
//
// The suite is serialized: the pinned engine is ONE shared runtime, and the
// production service serializes its automatic sessions with
// `OfficeAutomaticExecutionGate` (bounded, cancellation-aware, quarantined
// after any unacknowledged close).
//
// Resource provenance: `office-native-real-budget.xlsx` is a synthetic Floe
// promo fixture (origin: `Local/Artifacts/floe-promo-en/raw/office-fixtures/Workshop-Budget.xlsx`,
// produced by the promo-content run). It contains only generic English budget
// labels (Workshop Budget/Item/Quantity/Unit price/Amount/Venue/Materials/
// Refreshments/Supplies/Reserve/Total) and numbers — no personal data, no
// credentials and no third-party content, so it is safe to redistribute as a
// bundled test fixture. sha256 d528d356a062065d0d626927ca78403f1ed492796810e73934db91f3362f40a7.

#if canImport(UIKit) && canImport(FloeOfficeNative)
import Foundation
import Testing
import ZIPFoundation
import FloeCore
import FloeDocuments
import FloeExecution
import FloePersistence
import FloeTools
@testable import FloeApp

private final class OfficeNativeTestBundleToken {}

@Suite("FloeApp.OfficeNativeAutomaticExecution", .serialized)
struct OfficeNativeAutomaticExecutionTests {
    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: OfficeNativeTestBundleToken.self)
        guard let url = bundle.url(forResource: "office-native-real-budget", withExtension: "xlsx") else {
            throw FloeError.notFound("bundled Office fixture office-native-real-budget.xlsx")
        }
        return try Data(contentsOf: url)
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Real runtime-issued authority: issued by the shared store and consumed
    /// for the exact call, then turned into the executor's authorization.
    private func authorization(
        binding: RuntimeAuthorityBinding,
        approvalGrantID: UUID = UUID()
    ) async throws -> OfficeAutomaticAuthorization {
        let evidence = RuntimeAuthorityEvidence(
            runID: binding.runID,
            taskID: binding.taskID,
            environmentBinding: binding.environmentBinding,
            canonicalTarget: binding.canonicalTarget,
            toolName: binding.toolName,
            operation: binding.operation,
            operationID: binding.operationID,
            idempotencyKey: binding.idempotencyKey,
            baseRevision: binding.baseRevision,
            payloadDigest: binding.payloadDigest,
            approvalGrantID: approvalGrantID
        )
        let authority = await RuntimeAuthorityStore.shared.issue(evidence)
        let verdict = await RuntimeAuthorityStore.shared.consume(authority, binding: binding)
        guard verdict.isValid else {
            throw FloeError.validationFailed("test authority not valid: \(verdict.failureReason ?? "unknown")")
        }
        return OfficeAutomaticAuthorization(
            runID: binding.runID,
            taskID: binding.taskID,
            operationID: binding.operationID,
            idempotencyKey: binding.idempotencyKey,
            approvalGrantID: approvalGrantID,
            binding: binding,
            origin: .approvedToolCall
        )
    }

    private func binding(document: String, root: URL, toolName: String = "document.office.edit",
                         operation: String = "apply") -> RuntimeAuthorityBinding {
        RuntimeAuthorityBinding(
            runID: UUID(),
            taskID: UUID(),
            environmentBinding: "test",
            canonicalTarget: "file:" + root.appendingPathComponent(document).path,
            toolName: toolName,
            operation: operation,
            operationID: "call-\(UUID().uuidString.prefix(8))",
            idempotencyKey: "key-\(UUID().uuidString.prefix(8))",
            baseRevision: nil,
            payloadDigest: String(repeating: "b", count: 64)
        )
    }

    private func access(_ root: URL) -> OfficeCommandAccess {
        OfficeCommandAccess(environmentID: "test", workspacePath: root.path,
                            ownerKind: "workspace", ownerID: nil, conversationID: nil)
    }

    private func proposal(document: String, sha: String,
                          commands: [OfficeEngineCommand]) throws -> OfficeCommandProposal {
        OfficeCommandProposal(
            documentID: document,
            format: "xlsx",
            baseSHA256: sha,
            summary: "App automatic copy acceptance",
            commandsJSON: try OfficeCommandCodec.encode(commands),
            expectations: OfficeCommandCodec.expectations(commands)
        )
    }

    private func stageSource(_ root: URL) throws -> (url: URL, sha: String) {
        let source = root.appendingPathComponent("native-budget.xlsx")
        try fixtureData().write(to: source)
        return (source, try FloeDigest.sha256Hex(ofFileAt: source))
    }

    @Test("authorized automatic copy runs the real engine, publishes a verified copy and preserves the original")
    @MainActor
    func automaticCopyUsesRealEngine() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, originalSHA) = try stageSource(root)

        // Representative explicit command: insert one row. The executor's own
        // saved-package verification re-reads the reopened package and requires
        // the row-count delta, so a no-op engine command fails here instead of
        // being reported as applied.
        let before = try OfficeOutputSnapshot.capture(url: source)
        let originalRows = before.sheetRowCounts.first ?? 0
        let center = OfficeCommandCenter()
        let commands: [OfficeEngineCommand] = [.excelInsertRows(count: 1, at: "A5")]
        let receipt = try await center.applyAutomatic(
            proposal: try proposal(document: "native-budget.xlsx", sha: originalSHA, commands: commands),
            authorization: try await authorization(binding: binding(document: "native-budget.xlsx", root: root)),
            relativeOutput: "native-budget-verified.xlsx",
            requestID: "app-native-copy",
            access: access(root)
        )

        // Original bytes untouched; the published copy is a real verified file.
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == originalSHA)
        let output = root.appendingPathComponent(receipt.outputRelativePath)
        let outputSHA = try FloeDigest.sha256Hex(ofFileAt: output)
        #expect(receipt.saved)
        #expect(outputSHA == receipt.outputSHA256)
        #expect(receipt.sourceUnchanged)

        // Representative command effect read back from the reopened package.
        let snapshot = try OfficeOutputSnapshot.capture(url: output)
        #expect(snapshot.sheetRowCounts.first == originalRows + 1,
                "inserted row not present in the reopened package: \(snapshot.sheetRowCounts) (before \(originalRows))")
        #expect(!receipt.verified.isEmpty, "the receipt must carry the verified facts")
    }


    private func packageMember(_ url: URL, _ member: String) throws -> Data {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try #require(archive[member])
        try #require(entry.uncompressedSize <= 16 * 1_024 * 1_024)
        var bytes = Data()
        _ = try archive.extract(entry) { bytes.append($0) }
        return bytes
    }

    /// Derive only an isolated data-only copy of the real engine-loadable
    /// budget package. Exact sort rejects formulas and merges anywhere on the
    /// worksheet. Keep every other package member byte-for-byte; evaluate the
    /// six existing budget formulas to their actual values and unmerge A1:D1.
    /// The bundled fixture and the staged original are never rewritten.
    private func stageSortableSource(_ root: URL, original: URL) throws -> URL {
        let member = "xl/worksheets/sheet1.xml"
        var xml = String(decoding: try packageMember(original, member), as: UTF8.self)
        let replacements = [
            (#"<mergeCells count="1"><mergeCell ref="A1:D1"/></mergeCells>"#, ""),
            ("<f>B3*C3</f><v></v>", "<v>600</v>"),
            ("<f>B4*C4</f><v></v>", "<v>300</v>"),
            ("<f>B5*C5</f><v></v>", "<v>250</v>"),
            ("<f>B6*C6</f><v></v>", "<v>200</v>"),
            ("<f>B7*C7</f><v></v>", "<v>150</v>"),
            ("<f>SUM(D3:D7)</f><v></v>", "<v>1500</v>")
        ]
        for (before, after) in replacements {
            try #require(xml.components(separatedBy: before).count == 2,
                         "real budget fixture changed; review the bounded derivation")
            xml = xml.replacingOccurrences(of: before, with: after)
        }
        try #require(!xml.contains("<f>") && !xml.contains("<mergeCells"))
        let source = root.appendingPathComponent("native-budget-sortable.xlsx")
        let input = try Archive(url: original, accessMode: .read)
        let output = try Archive(url: source, accessMode: .create)
        for entry in input where entry.type == .file {
            let bytes: Data
            if entry.path == member { bytes = Data(xml.utf8) }
            else { bytes = try packageMember(original, entry.path) }
            try output.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(bytes.count),
                                compressionMethod: .deflate) { position, size in
                bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return source
    }

    /// Bounded diagnostic payload for this exact native qualification. Kept
    /// in Caches until the primary exports it; never hidden in the disposable
    /// workspace. This also runs for throws and soft Testing expectations.
    private func preserveExactSortEvidence(_ root: URL) throws {
        let cache = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let destination = cache.appendingPathComponent("FloeQualification/OfficeNativeExactSort", isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = ["native-budget.xlsx", "native-budget-sortable.xlsx", "native-budget-exact-sort.xlsx",
                     "exact-sort-receipt.json", "exact-sort-saved-sheet.xml",
                     "exact-sort-structural-cells.json", "exact-sort-snapshot-cells.json"]
        for name in names {
            let file = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try #require(size <= 2 * 1_024 * 1_024, "unexpectedly large exact-sort evidence member")
            try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(name))
        }
        print("OFFICE_EXACT_SORT_EVIDENCE " + destination.path)
    }

    @Test("exact sort uses the real native engine and persists the requested numeric rectangle")
    @MainActor
    func exactSortUsesRealEngine() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            do { try preserveExactSortEvidence(root) }
            catch { Issue.record(error, "could not retain exact-sort qualification artifacts") }
        }
        let (original, originalSHA) = try stageSource(root)
        let originalBytes = try Data(contentsOf: original)
        #expect(originalSHA == "d528d356a062065d0d626927ca78403f1ed492796810e73934db91f3362f40a7")
        let source = try stageSortableSource(root, original: original)
        let sourceBytes = try Data(contentsOf: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let originalPackage = try Archive(url: original, accessMode: .read)
        let derivedPackage = try Archive(url: source, accessMode: .read)
        #expect(Set(originalPackage.map(\.path)) == Set(derivedPackage.map(\.path)))
        for entry in originalPackage where entry.type == .file && entry.path != "xl/worksheets/sheet1.xml" {
            #expect(try packageMember(source, entry.path) == packageMember(original, entry.path))
        }
        let manifest = try OfficeExplicitTargets.read(url: source)
        try #require(manifest.sheets.count == 1)
        let target = try #require(manifest.sheets.first)
        #expect(target.member == "xl/worksheets/sheet1.xml")
        #expect(target.sheetName == "Budget")
        #expect(target.sheetIndex == 0)
        #expect(manifest.baseSHA256 == sourceSHA)
        let before = try OfficeOutputSnapshot.capture(url: source)
        #expect(before.formulaCells.isEmpty)
        let beforeCells = try #require(before.cachedCellsBySheet[target.member])
        #expect((3...7).compactMap { beforeCells["C\($0)"].flatMap { Double($0.value) } }
                == [600, 15, 12.5, 200, 150])

        // No inferred header: all five rows are data. The first column of
        // C3:D7 is the unique numeric key; D carries the associated amount.
        let commands: [OfficeEngineCommand] = [
            .explicit(.excelSort(target, range: "C3:D7", ascending: false))
        ]
        let authorityBinding = binding(document: source.lastPathComponent, root: root)
        let receipt = try await OfficeCommandCenter().applyAutomatic(
            proposal: try proposal(document: source.lastPathComponent, sha: manifest.baseSHA256,
                                   commands: commands),
            authorization: try await authorization(binding: authorityBinding),
            relativeOutput: "native-budget-exact-sort.xlsx",
            requestID: "app-native-exact-sort", access: access(root))
        let output = root.appendingPathComponent(receipt.outputRelativePath)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("exact-sort-receipt.json"))
        // Independent structure read: a self-closing B8/C8 must never absorb
        // D8's value. Keep the original snapshot/outside-range assertion below.
        let actualXML = try packageMember(output, target.member)
        try actualXML.write(to: root.appendingPathComponent("exact-sort-saved-sheet.xml"))
        let collector = OfficeNativeCellBoundaryCollector()
        let parser = XMLParser(data: actualXML)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        try #require(parser.parse(), "saved exact-sort worksheet must parse as XML")
        try JSONEncoder().encode(collector.cells).write(
            to: root.appendingPathComponent("exact-sort-structural-cells.json"))
        #expect(collector.cells["D8"]?["formula"] == "")
        #expect(collector.cells["D8"]?["value"].flatMap(Double.init) == 1500,
                "independent structural read of D8 outside C3:D7")
        let after = try OfficeOutputSnapshot.capture(url: output)
        let cells = try #require(after.cachedCellsBySheet[target.member])
        try JSONEncoder().encode(cells).write(to: root.appendingPathComponent("exact-sort-snapshot-cells.json"))
        let expected: [[Double]] = [[600, 600], [200, 200], [150, 150], [15, 300], [12.5, 250]]
        for (offset, pair) in expected.enumerated() {
            for (column, value) in zip(["C", "D"], pair) {
                let cell = try #require(cells["\(column)\(offset + 3)"])
                #expect(cell.type == .number)
                #expect(Double(cell.value) == value)
            }
        }
        #expect(after.sheetNameByMember[target.member] == "Budget")
        #expect(after.sheetNamesInOrder == ["Budget"])
        #expect(after.firstSheetColumnA == before.firstSheetColumnA)
        #expect(cells["B3"] == beforeCells["B3"])
        #expect(cells["D8"] == beforeCells["D8"])
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try FloeDigest.sha256Hex(ofFileAt: original) == originalSHA)
        #expect(receipt.saved && receipt.sourceUnchanged && !receipt.replay)
        #expect(receipt.baseSHA256 == manifest.baseSHA256)
        #expect(receipt.sourceSHA256 == manifest.baseSHA256)
        #expect(receipt.outputSHA256 == after.sha256)
        #expect(receipt.commands == ["excel.exactSort"])
        #expect(receipt.operationID == authorityBinding.operationID)
        #expect(receipt.engineReopen == "engine-opened")
        #expect(!receipt.sessionEngine.isEmpty)
        #expect(receipt.verified.contains("saved exact target verified: \(target.member):sort:C3:D7"))
    }

    @Test("exact AutoFilter uses the real native engine and persists its exact worksheet range")
    @MainActor
    func exactAutoFilterUsesRealEngine() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, originalSHA) = try stageSource(root)
        let originalBytes = try Data(contentsOf: source)
        let manifest = try OfficeExplicitTargets.read(url: source)
        try #require(manifest.sheets.count == 1)
        let target = try #require(manifest.sheets.first)
        #expect(target.member == "xl/worksheets/sheet1.xml")
        #expect(target.sheetName == "Budget")
        #expect(target.sheetIndex == 0)
        #expect(originalSHA == "d528d356a062065d0d626927ca78403f1ed492796810e73934db91f3362f40a7")
        let before = try OfficeOutputSnapshot.capture(url: source)
        #expect(!before.hasAutoFilter)
        let commands: [OfficeEngineCommand] = [
            .explicit(.excelAutoFilter(target, range: "B2:C7"))
        ]
        let authorityBinding = binding(document: source.lastPathComponent, root: root)
        let receipt = try await OfficeCommandCenter().applyAutomatic(
            proposal: try proposal(document: source.lastPathComponent, sha: originalSHA, commands: commands),
            authorization: try await authorization(binding: authorityBinding),
            relativeOutput: "native-budget-exact-filter.xlsx",
            requestID: "app-native-exact-filter", access: access(root))
        let output = root.appendingPathComponent(receipt.outputRelativePath)
        let after = try OfficeOutputSnapshot.capture(url: output)
        let collector = OfficeNativeAutoFilterCollector()
        let parser = XMLParser(data: try packageMember(output, target.member))
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        try #require(parser.parse(), "saved worksheet must parse as XML")
        #expect(collector.references == ["B2:C7"])
        #expect(after.hasAutoFilter)
        #expect(after.sheetNameByMember[target.member] == "Budget")
        #expect(after.sheetNamesInOrder == ["Budget"])
        #expect(try Data(contentsOf: source) == originalBytes)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == originalSHA)
        #expect(receipt.saved && receipt.sourceUnchanged && !receipt.replay)
        #expect(receipt.baseSHA256 == originalSHA && receipt.sourceSHA256 == originalSHA)
        #expect(receipt.outputSHA256 == after.sha256)
        #expect(receipt.commands == ["excel.exactAutoFilter"])
        #expect(receipt.operationID == authorityBinding.operationID)
        #expect(receipt.engineReopen == "engine-opened")
        #expect(!receipt.sessionEngine.isEmpty)
        #expect(receipt.verified.contains("saved exact target verified: \(target.member):filter"))
    }

    @Test("excel.recalculate verifies the real engine's persisted cached values on the reopened copy")
    @MainActor
    func recalculationIsVerifiedByRealEngine() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, originalSHA) = try stageSource(root)

        let center = OfficeCommandCenter()
        let commands: [OfficeEngineCommand] = [.excelRecalculate]
        let receipt = try await center.applyAutomatic(
            proposal: try proposal(document: "native-budget.xlsx", sha: originalSHA, commands: commands),
            authorization: try await authorization(binding: binding(document: "native-budget.xlsx", root: root)),
            relativeOutput: "native-budget-recalculated.xlsx",
            requestID: "app-native-recalc",
            access: access(root)
        )

        #expect(receipt.saved)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == originalSHA)
        let output = root.appendingPathComponent(receipt.outputRelativePath)
        let snapshot = try OfficeOutputSnapshot.capture(url: output)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.isClean, "formula verification: \(report)")
        #expect(receipt.formulaSummary?.isEmpty == false,
                "the receipt must carry the measured formula summary")
    }

    @Test("an existing different output is refused without touching it")
    @MainActor
    func existingOutputConflictIsRefused() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, originalSHA) = try stageSource(root)
        let existingBytes = Data("existing user bytes".utf8)
        let existing = root.appendingPathComponent("native-budget-conflict.xlsx")
        try existingBytes.write(to: existing)

        let center = OfficeCommandCenter()
        await #expect(throws: (any Error).self) {
            _ = try await center.applyAutomatic(
                proposal: try proposal(document: "native-budget.xlsx", sha: originalSHA,
                                       commands: [.excelInsertRows(count: 1, at: "A5")]),
                authorization: try await authorization(binding: binding(document: "native-budget.xlsx", root: root)),
                relativeOutput: "native-budget-conflict.xlsx",
                requestID: "app-native-conflict",
                access: access(root)
            )
        }
        #expect(try Data(contentsOf: existing) == existingBytes)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == originalSHA)
    }

    @Test("an authorization not bound to document.office.edit apply is refused")
    @MainActor
    func mismatchedAuthorizationIsRefused() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, originalSHA) = try stageSource(root)

        let center = OfficeCommandCenter()
        await #expect(throws: (any Error).self) {
            _ = try await center.applyAutomatic(
                proposal: try proposal(document: "native-budget.xlsx", sha: originalSHA,
                                       commands: [.excelInsertRows(count: 1, at: "A5")]),
                // A jobs.submit binding must not authorize an Office apply.
                authorization: try await authorization(
                    binding: binding(document: "native-budget.xlsx", root: root,
                                     toolName: "jobs.submit", operation: "job.submit")),
                relativeOutput: "native-budget-mismatch.xlsx",
                requestID: "app-native-mismatch",
                access: access(root)
            )
        }
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == originalSHA)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("native-budget-mismatch.xlsx").path))
    }

    // MARK: - Service-lease behavior (same shared engine runtime)

    @Test("the service lease wait is bounded and honors cancellation")
    @MainActor
    func leaseWaitIsBoundedAndCancellable() async {
        let gate = OfficeAutomaticExecutionGate.shared
        await gate.resetForTesting()
        #expect(await gate.acquire(cancellation: nil, timeout: 1) == .acquired)

        // A second waiter cannot acquire while the first holds the lease, and
        // it leaves at its safe pre-effect boundary instead of queueing forever.
        #expect(await gate.acquire(cancellation: nil, timeout: 0.3) == .timedOut)

        let cancelled = CancellationToken()
        cancelled.cancel()
        #expect(await gate.acquire(cancellation: cancelled, timeout: 1) == .cancelledBeforeStart)

        await gate.release(closeAcknowledged: true)
        #expect(await gate.acquire(cancellation: nil, timeout: 1) == .acquired)
        await gate.release(closeAcknowledged: true)
        await gate.resetForTesting()
    }

    @Test("Task cancellation ends a queued lease wait immediately")
    @MainActor
    func taskCancellationEndsLeaseWait() async {
        let gate = OfficeAutomaticExecutionGate.shared
        await gate.resetForTesting()
        #expect(await gate.acquire(cancellation: nil, timeout: 1) == .acquired)
        let waiter = Task { await gate.acquire(cancellation: nil, timeout: 30) }
        // Give the waiter time to queue, then cancel the waiting Task: the
        // acquire must return at once instead of spinning to its deadline.
        try? await Task.sleep(nanoseconds: 250_000_000)
        waiter.cancel()
        let outcome = await waiter.value
        #expect(outcome == .cancelledBeforeStart)
        await gate.release(closeAcknowledged: true)
        await gate.resetForTesting()
    }

    @Test("an unacknowledged close quarantines the gate and refuses new shared-engine work")
    @MainActor
    func unacknowledgedCloseQuarantines() async {
        let gate = OfficeAutomaticExecutionGate.shared
        await gate.resetForTesting()
        #expect(await gate.acquire(cancellation: nil, timeout: 1) == .acquired)
        await gate.release(closeAcknowledged: false, failureReason: "close timed out")

        guard case .hostQuarantined(let reason) = await gate.acquire(cancellation: nil, timeout: 1) else {
            Issue.record("a quarantined gate must refuse new work")
            await gate.resetForTesting()
            return
        }
        #expect(!reason.isEmpty)
        await gate.resetForTesting()
    }
}


/// Test-only structural reader preserving each actual c-element boundary,
/// including self-closing empty cells. No engine or production parser shim.
private final class OfficeNativeCellBoundaryCollector: NSObject, XMLParserDelegate {
    private(set) var cells: [String: [String: String]] = [:]
    private var reference: String?
    private var type = ""
    private var value = ""
    private var formula = ""
    private var collecting: String?
    private let sheetNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard namespaceURI == sheetNS else { return }
        if elementName == "c" {
            reference = attributes["r"]; type = attributes["t"] ?? "n"
            value = ""; formula = ""; collecting = nil
        } else if reference != nil, elementName == "v" || elementName == "f" {
            collecting = elementName
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting == "v" { value += string }
        if collecting == "f" { formula += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard namespaceURI == sheetNS else { return }
        if elementName == "v" || elementName == "f" { collecting = nil }
        if elementName == "c", let reference {
            cells[reference] = ["type": type, "value": value, "formula": formula]
            self.reference = nil
        }
    }
}

/// Independent read-back of the exact filter ref, rather than the workbook-
/// wide `hasAutoFilter` flag (which could pass for a filter on another range).
private final class OfficeNativeAutoFilterCollector: NSObject, XMLParserDelegate {
    private(set) var references: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        if elementName == "autoFilter",
           namespaceURI == "http://schemas.openxmlformats.org/spreadsheetml/2006/main" {
            references.append(attributeDict["ref"] ?? "")
        }
    }
}

// MARK: - Real Office enum through the real BackgroundJobService

/// The real `BackgroundJobService` receiving the REAL
/// `OfficeAutomaticExecutionError` family through the EXACT App adapter
/// mapping (`NativeJobAppAdapters.officeSafetyFailure`) — the concrete
/// regression this suite exists for. The executor failures come from real
/// production code paths:
///
///   * `.cancelled` — `OfficeAutomaticExecutor.execute` with a cancelled token
///     (its safe pre-effect boundary).
///   * `.sourceChanged` — the executor's real CAS check against a mismatched
///     approved base revision (no engine session is opened).
///   * `.sessionCloseUnacknowledged` — the executor's real close-ack path over
///     a stub engine boundary; the pinned engine's own close behavior is
///     covered by the real-engine suite above (which cannot be made to fail
///     its close deterministically).
///
/// A wholesale `error is any UnsafeResourceStateError` check would mislabel
/// the first two as failed retained-staging runs; only the shared contract's
/// discriminant may decide.
@Suite("FloeApp.OfficeJobSafetyDiscriminant", .serialized)
@MainActor
struct OfficeJobSafetyDiscriminantTests {
    enum FailureMode {
        case cleanCancellation
        case safeSourceChanged
        case unsafeClose
    }

    private func stageSource(_ root: URL) throws {
        let bundle = Bundle(for: OfficeNativeTestBundleToken.self)
        guard let fixture = bundle.url(forResource: "office-native-real-budget", withExtension: "xlsx") else {
            throw FloeError.notFound("bundled Office fixture office-native-real-budget.xlsx")
        }
        try Data(contentsOf: fixture).write(to: root.appendingPathComponent("native-budget.xlsx"))
    }

    private func makeService(mode: FailureMode, root: URL) async throws
        -> (service: BackgroundJobService, runID: UUID) {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Office safety discriminant",
            createdAt: Date(), updatedAt: Date()))
        let runID = UUID()
        try await environment.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: "running",
            goal: "office safety discriminant", startedAt: Date(), endedAt: nil))
        // The service verifies that the target exists in the registry even
        // though the adapter owns the prepared operation.
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(descriptor: ToolCatalog.Descriptor(
            name: "document.office.edit", toolDescription: "stub office runner",
            parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true,
            effect: .mutating, executionBoundary: .any
        )) { _, _ in ToolExecutionOutput(summary: "stub", fullOutputSHA256: "stub") })
        let adapter = NativeJobServiceAdapter(
            targetTool: "document.office.edit",
            adaptedActions: ["apply"],
            requiresRuntimeAuthorization: false,
            prepare: { request in
                OfficeSafetyHarnessOperation(operationID: request.operationID, mode: mode,
                                             root: root, document: "native-budget.xlsx")
            })
        let service = BackgroundJobService(
            store: BackgroundJobStore(database: environment.database),
            registry: registry, policy: .default,
            adapters: ["document.office.edit": adapter])
        return (service, runID)
    }

    private func runToTerminal(mode: FailureMode, cancelWhileRunning: Bool) async throws -> BackgroundJob {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try stageSource(root)
        let (service, runID) = try await makeService(mode: mode, root: root)
        let job = try await service.submit(
            runID: runID, toolCallID: "office-safety-\(UUID().uuidString.prefix(8))",
            targetTool: "document.office.edit",
            payloadJSON: Data(#"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#.utf8),
            scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
            submissionSource: .nativeService)
        if cancelWhileRunning {
            let runningDeadline = Date().addingTimeInterval(5)
            while Date() < runningDeadline,
                  (try? await service.job(id: job.id))?.state != .running {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            _ = try await service.cancel(id: job.id)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let current = try? await service.job(id: job.id), current.state.isTerminal {
                return current
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FloeError.validationFailed("the office safety job never reached a terminal state")
    }

    @Test("a clean Office cancellation with a cancelled job token stays cancelled")
    func cleanCancellationStaysCancelled() async throws {
        let terminal = try await runToTerminal(mode: .cleanCancellation, cancelWhileRunning: true)
        #expect(terminal.state == .cancelled,
                "a clean Office cancellation must not be downgraded to an unsafe failure")
        #expect(terminal.lastError?.contains("Unsafe resource state") != true)
        #expect(terminal.lastError?.contains("staging was cleaned") == true)
    }

    @Test("an ordinary safe Office failure fails without any unsafe/staging claim")
    func ordinarySafeFailureHasNoUnsafeClaim() async throws {
        let terminal = try await runToTerminal(mode: .safeSourceChanged, cancelWhileRunning: false)
        #expect(terminal.state == .failed)
        #expect(terminal.lastError?.contains("Unsafe resource state") != true)
        #expect(terminal.lastError?.contains("Staging was retained") != true)
        // The ordinary failure keeps its own identity.
        #expect(terminal.lastError?.contains("sourceChanged") == true)
    }

    @Test("an unacknowledged Office close with a cancelled job token fails with retained truth")
    func unsafeCloseOutranksCancellation() async throws {
        let terminal = try await runToTerminal(mode: .unsafeClose, cancelWhileRunning: true)
        #expect(terminal.state == .failed,
                "an unacknowledged close must outrank the cancellation request")
        #expect(terminal.lastError?.contains("Unsafe resource state") == true)
        #expect(terminal.lastError?.contains("Staging was retained") == true)
        #expect(terminal.lastError?.contains("staging was cleaned") != true)
    }
}

/// Prepared-operation harness: runs REAL `OfficeAutomaticExecutor` code and
/// routes its failure through the exact App adapter mapping.
private struct OfficeSafetyHarnessOperation: NativeJobPreparedOperation {
    let operationID: String
    let mode: OfficeJobSafetyDiscriminantTests.FailureMode
    let root: URL
    let document: String
    var frozenRevision: String? = nil
    var serviceLabel: String { "office-safety-harness" }

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        if mode != .safeSourceChanged {
            // The adapter contract: leave at the safe pre-effect boundary once
            // the job requests cancellation (the real operation forwards the
            // token into the executor).
            let deadline = Date().addingTimeInterval(10)
            while !hooks.isCancellationRequested(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let source = root.appendingPathComponent(document)
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)
        let commands: [OfficeEngineCommand] = [.excelInsertRows(count: 1, at: "A5")]
        let proposal = OfficeCommandProposal(
            documentID: document,
            format: "xlsx",
            baseSHA256: mode == .safeSourceChanged ? String(repeating: "0", count: 64) : sha,
            summary: "job safety discriminant",
            commandsJSON: try OfficeCommandCodec.encode(commands),
            expectations: OfficeCommandCodec.expectations(commands))
        let binding = RuntimeAuthorityBinding(
            runID: UUID(), taskID: UUID(), environmentBinding: "test",
            canonicalTarget: "file:" + source.path,
            toolName: "document.office.edit", operation: "apply",
            operationID: operationID, idempotencyKey: "key-\(operationID)",
            baseRevision: nil, payloadDigest: String(repeating: "c", count: 64))
        let authorization = OfficeAutomaticAuthorization(
            runID: binding.runID, taskID: binding.taskID, operationID: binding.operationID,
            idempotencyKey: binding.idempotencyKey, approvalGrantID: UUID(),
            binding: binding, origin: .approvedToolCall)
        let access = OfficeCommandAccess(environmentID: "test", workspacePath: root.path,
                                         ownerKind: "workspace", ownerID: nil, conversationID: nil)
        let factory: any OfficeServiceEngineSessionFactory
        switch mode {
        case .unsafeClose:
            factory = OfficeUnsafeCloseStubFactory(closeError: OfficeStubCloseFailure())
        default:
            factory = OfficeNeverOpenedStubFactory()
        }
        let token: CancellationToken?
        if mode == .cleanCancellation {
            let cancelled = CancellationToken()
            cancelled.cancel()
            token = cancelled
        } else {
            token = nil
        }
        do {
            _ = try await OfficeAutomaticExecutor(factory: factory).execute(
                proposal: proposal, authorization: authorization,
                relativeOutput: "native-budget-job.xlsx", requestID: "req-\(operationID)",
                access: access, cancellation: token)
        } catch {
            // EXACT production mapping applied by the real App Office adapter.
            if let safety = NativeJobAppAdapters.officeSafetyFailure(from: error) { throw safety }
            throw error
        }
        throw FloeError.validationFailed("the harness expected the executor to fail")
    }
}

/// Stub engine boundary for the deterministic unacknowledged-close failure.
/// The REAL pinned engine's close behavior is exercised by the automatic-copy
/// suite above; no engine is loaded here.
private struct OfficeUnsafeCloseStubFactory: OfficeServiceEngineSessionFactory {
    let closeError: Error

    func openServiceSession(workingCopyURL: URL, format: OfficeDocumentFormat,
                            originalURL: URL,
                            access: OfficeCommandAccess) async throws -> any OfficeServiceEngineSession {
        OfficeUnsafeCloseStubSession(workingCopyURL: workingCopyURL, closeError: closeError)
    }
}

private final class OfficeUnsafeCloseStubSession: OfficeServiceEngineSession, @unchecked Sendable {
    let workingCopyURL: URL
    let engineLabel = "discriminant-stub-engine"
    private let closeError: Error

    init(workingCopyURL: URL, closeError: Error) {
        self.workingCopyURL = workingCopyURL
        self.closeError = closeError
    }

    func status() async throws -> OfficeServiceSessionStatus {
        OfficeServiceSessionStatus(editable: true)
    }

    func apply(commands: [OfficeEngineCommand], batchID: String) async throws {}
    func save() async throws {}
    func close() async throws { throw closeError }
}

private struct OfficeStubCloseFailure: LocalizedError {
    var errorDescription: String? { "stub engine did not acknowledge the close" }
}

/// Used by modes that must fail before any session is opened; reaching it is a
/// harness bug.
private struct OfficeNeverOpenedStubFactory: OfficeServiceEngineSessionFactory {
    func openServiceSession(workingCopyURL: URL, format: OfficeDocumentFormat,
                            originalURL: URL,
                            access: OfficeCommandAccess) async throws -> any OfficeServiceEngineSession {
        throw FloeError.validationFailed("this mode must fail before opening an engine session")
    }
}
#endif
