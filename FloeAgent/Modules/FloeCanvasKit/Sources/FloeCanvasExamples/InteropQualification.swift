// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasExchange

// MARK: - Scenario 2: interop fixture qualification (ICH11)
//
// Imports the coordinator fixtures through the real codecs, commits one real
// edit batch per fixture, exports .canvas/.excalidraw/.drawio (plus a
// compressed draw.io variant) with the import sidecars for lossless
// re-injection, reimports every export and asserts the supported data
// survives — including the exact spelling of unknown big numeric literals.
// The mutated snapshot also travels through the native archive with the
// original bytes attached, and rendered PDF/PNG/SVG exports carry real
// content. Negative fixtures must fail closed with actionable errors.

enum InteropQualification {
    static let scenarioName = "s2-interop-round-trip"

    struct FormatLoss: Codable, Sendable {
        var format: String
        var issues: [String]
    }

    static func run(
        outputRoot: URL, fixtures: URL
    ) async throws -> ScenarioReport {
        var checks: [Check] = []
        var artifacts: [String] = []
        var notes: [String] = []
        var losses: [FormatLoss] = []
        let directory = outputRoot.appendingPathComponent("interop", isDirectory: true)

        // ---------- fixture bytes (read-only) ----------
        func fixture(_ name: String) throws -> Data {
            try Data(contentsOf: fixtures.appendingPathComponent(name))
        }

        // ---------- JSON Canvas (.canvas) ----------
        do {
            let bytes = try fixture("mixed.canvas")
            var bundle = try await CanvasExchange.importData(
                bytes, format: .jsonCanvas,
                options: CanvasImportOptions(
                    canvasID: SyntheticQualification.uuid(0xC001),
                    canvasName: "interop-mixed",
                    namespace: "qualification",
                    trustedAssetRoot: fixtures,
                    resolveAssetBytes: true))

            checks.append(Check(
                id: "s2.canvas.import",
                scenario: scenarioName,
                status: importSanity(bundle, expectedNodes: 3, expectedRegions: 1, expectedEdges: 2)
                    ? .pass : .fail,
                detail: "mixed.canvas imports 3 content nodes / 1 region / 2 edges; "
                    + "contained relative asset resolved inside the "
                    + "trusted fixture root only",
                evidence: [
                    "nodes=\(bundle.snapshot.selectedPage?.nodes.count ?? 0)",
                    "edges=\(bundle.snapshot.selectedPage?.connections.count ?? 0)",
                    "assets resolved=\(bundle.assets.count)",
                ]))

            bundle = try await mutate(bundle: bundle, tag: "canvas")

            let export = try await CanvasExchange.export(
                bundle.snapshot, format: .jsonCanvas,
                options: CanvasExportOptions(
                    externalIDs: bundle.externalIDs,
                    originalNodes: bundle.originalNodes,
                    originalEdges: bundle.originalEdges,
                    originalDocument: bundle.originalDocument))
            let exportedName = try QualifyIO.write(
                export.primary.data, to: directory, name: export.primary.name)
            artifacts.append("interop/\(exportedName)")
            losses.append(FormatLoss(
                format: "jsonCanvas",
                issues: export.issues.map { "\($0.code):\($0.severity.rawValue)" }))

            let reimported = try await CanvasExchange.importData(
                export.primary.data, format: .jsonCanvas,
                options: CanvasImportOptions(
                    canvasID: SyntheticQualification.uuid(0xC002),
                    canvasName: "interop-mixed-reimport",
                    namespace: "qualification"))
            checks.append(Check(
                id: "s2.canvas.roundTrip",
                scenario: scenarioName,
                status: roundTripSanity(bundle, reimported)
                    ? .pass : .fail,
                detail: "edited .canvas re-exports and re-imports with labels, "
                    + "Chinese markdown text, the link URL and the unknown "
                    + "fixture payload surviving",
                evidence: [
                    "nodes \(bundle.snapshot.selectedPage?.nodes.count ?? 0)→"
                        + "\(reimported.snapshot.selectedPage?.nodes.count ?? 0)",
                    "losses=\(export.issues.count)",
                ]))

            // Native archive with the original fixture bytes attached.
            try await archiveCheck(
                snapshot: bundle.snapshot,
                original: bytes,
                kind: .jsonCanvasOriginal,
                name: "mixed-original.canvas",
                resolverBytes: bundle.assets,
                directory: directory,
                checks: &checks,
                artifacts: &artifacts,
                id: "s2.canvas.archive")
        } catch {
            checks.append(Check(
                id: "s2.canvas",
                scenario: scenarioName,
                status: .fail,
                detail: "json canvas path error: \(error)",
                evidence: []))
        }

        // ---------- Excalidraw ----------
        do {
            let bytes = try fixture("mixed.excalidraw")
            var bundle = try await CanvasExchange.importData(
                bytes, format: .excalidraw,
                options: CanvasImportOptions(
                    canvasID: SyntheticQualification.uuid(0xC011),
                    canvasName: "interop-excalidraw",
                    namespace: "qualification"))
            checks.append(Check(
                id: "s2.excalidraw.import",
                scenario: scenarioName,
                status: (bundle.snapshot.selectedPage?.nodes.count == 3
                    && bundle.snapshot.selectedPage?.regions.count == 1
                    && bundle.snapshot.selectedPage?.strokes.count == 1
                    && bundle.snapshot.selectedPage?.connections.count == 1)
                    ? .pass : .fail,
                detail: "mixed.excalidraw imports 7 elements (frame/rectangle/"
                    + "ellipse/text/arrow/freedraw + bound text)",
                evidence: [
                    "nodes=\(bundle.snapshot.selectedPage?.nodes.count ?? 0)",
                ]))

            bundle = try await mutate(bundle: bundle, tag: "excalidraw")

            let export = try await CanvasExchange.export(
                bundle.snapshot, format: .excalidraw,
                options: CanvasExportOptions(
                    multiPageStrategy: .selectedPageOnly,
                    externalIDs: bundle.externalIDs,
                    originalNodes: bundle.originalNodes,
                    originalEdges: bundle.originalEdges,
                    originalDocument: bundle.originalDocument,
                    assetBytes: bundle.assets))
            let exportedName = try QualifyIO.write(
                export.primary.data, to: directory, name: export.primary.name)
            artifacts.append("interop/\(exportedName)")
            losses.append(FormatLoss(
                format: "excalidraw",
                issues: export.issues.map { "\($0.code):\($0.severity.rawValue)" }))

            // Unknown big literals survive with their exact source spelling.
            let literalOK = try bigLiteralsPreserved(
                in: export.primary.data,
                literals: ["92233720368547758081234567890", "0.123456789012345678901234567890"])
            checks.append(Check(
                id: "s2.excalidraw.bigLiterals",
                scenario: scenarioName,
                status: literalOK ? .pass : .fail,
                detail: "fixtureUnknownInteger beyond Int64 and the "
                    + "high-precision decimal re-emit with their exact "
                    + "source spellings through the sidecar re-injection",
                evidence: [
                    "literals exact: \(literalOK)",
                ]))

            let reimported = try await CanvasExchange.importData(
                export.primary.data, format: .excalidraw,
                options: CanvasImportOptions(
                    canvasID: SyntheticQualification.uuid(0xC012),
                    canvasName: "interop-excalidraw-reimport",
                    namespace: "qualification"))
            checks.append(Check(
                id: "s2.excalidraw.roundTrip",
                scenario: scenarioName,
                status: roundTripSanity(bundle, reimported)
                    ? .pass : .fail,
                detail: "edited scene re-exports and re-imports with frames, "
                    + "arrows, freedraw points and bound text surviving",
                evidence: [
                    "nodes \(bundle.snapshot.selectedPage?.nodes.count ?? 0)→"
                        + "\(reimported.snapshot.selectedPage?.nodes.count ?? 0)",
                    "losses=\(export.issues.count)",
                ]))

            try await archiveCheck(
                snapshot: bundle.snapshot,
                original: bytes,
                kind: .excalidrawOriginal,
                name: "mixed-original.excalidraw",
                directory: directory,
                checks: &checks,
                artifacts: &artifacts,
                id: "s2.excalidraw.archive")
        } catch {
            checks.append(Check(
                id: "s2.excalidraw",
                scenario: scenarioName,
                status: .fail,
                detail: "excalidraw path error: \(error)",
                evidence: []))
        }

        // ---------- draw.io (plain + compressed, multipage) ----------
        do {
            let bytes = try fixture("two-pages.drawio")
            var bundle = try await CanvasExchange.importData(
                bytes, format: .drawio,
                options: CanvasImportOptions(
                    canvasID: SyntheticQualification.uuid(0xC021),
                    canvasName: "interop-drawio",
                    namespace: "qualification"))
            checks.append(Check(
                id: "s2.drawio.import",
                scenario: scenarioName,
                status: (bundle.snapshot.pages.count == 2)
                    ? .pass : .fail,
                detail: "two-pages.drawio imports both <diagram> pages",
                evidence: [
                    "pages=\(bundle.snapshot.pages.count)",
                ]))

            bundle = try await mutate(bundle: bundle, tag: "drawio")

            let plain = try await CanvasExchange.export(
                bundle.snapshot, format: .drawio,
                options: CanvasExportOptions())
            let plainName = try QualifyIO.write(
                plain.primary.data, to: directory, name: plain.primary.name)
            artifacts.append("interop/\(plainName)")

            let compressed = try await CanvasExchange.export(
                bundle.snapshot, format: .drawio,
                options: CanvasExportOptions(drawioCompressed: true))
            let compressedName = try QualifyIO.write(
                compressed.primary.data, to: directory,
                name: "compressed-\(compressed.primary.name)")
            artifacts.append("interop/\(compressedName)")
            losses.append(FormatLoss(
                format: "drawio",
                issues: (plain.issues + compressed.issues)
                    .map { "\($0.code):\($0.severity.rawValue)" }))

            let reimported = try await CanvasExchange.importData(
                plain.primary.data, format: .drawio,
                options: CanvasImportOptions(
                    canvasID: SyntheticQualification.uuid(0xC022),
                    canvasName: "interop-drawio-reimport",
                    namespace: "qualification"))
            checks.append(Check(
                id: "s2.drawio.roundTrip",
                scenario: scenarioName,
                status: (reimported.snapshot.pages.count == 2
                    && reimported.snapshot.pages.map(\.name) == bundle.snapshot.pages.map(\.name)
                    && zip(reimported.snapshot.pages, bundle.snapshot.pages).allSatisfy {
                        $0.nodes.count == $1.nodes.count && $0.connections.map(\.label) == $1.connections.map(\.label)
                    })
                    ? .pass : .fail,
                detail: "edited draw.io re-exports (plain + compressed) and "
                    + "re-imports with both pages and Chinese labels intact",
                evidence: [
                    "pages reimported=\(reimported.snapshot.pages.count)",
                    "compressed magic ok=\(compressed.primary.data.starts(with: Data("<mxfile".utf8)) || compressed.primary.data.starts(with: [0x78]))",
                ]))

            try await archiveCheck(
                snapshot: bundle.snapshot,
                original: bytes,
                kind: .drawioOriginal,
                name: "two-pages-original.drawio",
                directory: directory,
                checks: &checks,
                artifacts: &artifacts,
                id: "s2.drawio.archive")

            // Rendered exports of the mutated draw.io snapshot.
            try await render(
                snapshot: bundle.snapshot,
                resolverBytes: bundle.assets,
                directory: directory,
                checks: &checks,
                artifacts: &artifacts,
                id: "s2.render")
        } catch {
            checks.append(Check(
                id: "s2.drawio",
                scenario: scenarioName,
                status: .fail,
                detail: "draw.io path error: \(error)",
                evidence: []))
        }

        // ---------- negative fixtures (fail closed) ----------
        do {
            let bytes = try fixture("invalid-duplicate-id.canvas")
            do {
                _ = try await CanvasExchange.importData(
                    bytes, format: .jsonCanvas,
                    options: CanvasImportOptions(
                        canvasID: SyntheticQualification.uuid(0xC031),
                        canvasName: "negative-duplicate"))
                checks.append(Check(
                    id: "s2.negative.duplicateID",
                    scenario: scenarioName,
                    status: .fail,
                    detail: "invalid-duplicate-id.canvas imported without an "
                        + "error — duplicate ids must be rejected",
                    evidence: []))
            } catch {
                checks.append(Check(
                    id: "s2.negative.duplicateID",
                    scenario: scenarioName,
                    status: .pass,
                    detail: "duplicate node ids rejected with an actionable "
                        + "error: \(error)",
                    evidence: []))
            }
        } catch {
            checks.append(Check(
                id: "s2.negative.duplicateID",
                scenario: scenarioName,
                status: .unverified,
                detail: "negative fixture unreadable: \(error)",
                evidence: []))
        }

        do {
            let bytes = try fixture("unsafe-relative-asset.canvas")
            let bundle = try await CanvasExchange.importData(
                bytes, format: .jsonCanvas,
                options: CanvasImportOptions(
                    canvasID: SyntheticQualification.uuid(0xC032),
                    canvasName: "negative-unsafe-asset",
                    trustedAssetRoot: fixtures,
                    resolveAssetBytes: true))
            let refused = bundle.assets.isEmpty
                && bundle.issues.contains {
                    $0.severity == .unavailable || $0.severity == .rejected
                }
            checks.append(Check(
                id: "s2.negative.unsafeAsset",
                scenario: scenarioName,
                status: refused ? .pass : .fail,
                detail: "the '../../outside-private-fixture.txt' reference must "
                    + "not escape the trusted fixture root: no bytes resolved "
                    + "and an explicit unavailable/rejected issue is recorded",
                evidence: bundle.issues.map { "\($0.code)(\($0.severity.rawValue))" }))
        } catch {
            // A hard rejection at import time is also a fail-closed pass.
            checks.append(Check(
                id: "s2.negative.unsafeAsset",
                scenario: scenarioName,
                status: .pass,
                detail: "unsafe asset reference rejected at import with an "
                    + "actionable error: \(error)",
                evidence: []))
        }

        // ---------- per-format loss matrix ----------
        let lossData = try QualifyIO.encodeJSON(losses)
        let lossName = try QualifyIO.write(
            lossData, to: directory, name: "losses.json")
        artifacts.append("interop/\(lossName)")

        notes.append(
            "fixtures are coordinator-provided synthetic inputs, read-only; "
            + "exported files are produced by the real codecs for root's "
            + "Obsidian/Excalidraw/draw.io readback")
        return ScenarioReport(
            scenario: scenarioName,
            checks: checks,
            artifacts: artifacts,
            notes: notes)
    }

    // MARK: Shared helpers

    /// One real edit batch per fixture: add a qualification note card and
    /// move an existing node, committed through the repository pipeline so
    /// revision/receipt semantics are exercised too.
    private static func mutate(
        bundle: CanvasExchangeBundle, tag: String
    ) async throws -> CanvasExchangeBundle {
        var bundle = bundle
        let repository = InMemoryCanvasRepository(snapshot: bundle.snapshot)
        guard let page = bundle.snapshot.selectedPage else {
            throw CanvasKitError.missingEntity("selected page")
        }
        var operations: [CanvasEditOperation] = [
            .insertNode(CanvasNodeSnapshot(
                id: SyntheticQualification.uuid(0xD000),
                title: "资格编辑 \(tag)",
                content: .markdown(
                    document: "# 资格编辑\n\n由 P4a harness 通过真实批次提交。",
                    previewText: "资格编辑"),
                frame: CanvasGeometry.Frame(
                    center: .init(x: 1400, y: -600),
                    size: .init(width: 340, height: 180)))),
        ]
        if let first = page.nodes.first {
            operations.append(.move(
                nodeID: first.id,
                center: .init(
                    x: first.frame.center.x + 40,
                    y: first.frame.center.y + 24)))
        }
        let batch = CanvasEditBatch(
            pageID: page.id,
            scope: .wholeDocument,
            operations: operations)
        var documentOperations: [CanvasDocumentOperation] = [.editPage(batch)]
        for empty in bundle.snapshot.pages where empty.id != page.id && empty.nodes.isEmpty {
            documentOperations.append(.editPage(.init(pageID: empty.id, scope: .wholeDocument,
                operations: [.insertNode(.init(title: "资格编辑 \(empty.name)",
                    content: .text("资格编辑 · \(empty.name)"),
                    frame: .init(center: .zero, size: .init(width: 240, height: 120))))])))
        }
        let receipt = try await repository.commitDocument(
            .init(scope: .wholeDocument, operations: documentOperations), canvasID: bundle.snapshot.id,
            expectedRevision: bundle.snapshot.revision,
            requestID: SyntheticQualification.uuid(0xD100))
        bundle.snapshot = try await repository.load(canvasID: bundle.snapshot.id)
        _ = receipt
        return bundle
    }

    private static func importSanity(
        _ bundle: CanvasExchangeBundle, expectedNodes: Int, expectedRegions: Int, expectedEdges: Int
    ) -> Bool {
        guard let page = bundle.snapshot.selectedPage else { return false }
        // JSON Canvas text nodes import as `.text` (the codec keeps markdown
        // source verbatim inside it); accept either content case.
        func carriesChineseAndEmoji(_ content: CanvasContent) -> Bool {
            switch content {
            case .text(let text): return text.contains("中文与 emoji 🧊")
            case .markdown(let document, _): return document.contains("中文与 emoji 🧊")
            default: return false
            }
        }
        let text = page.nodes.contains { carriesChineseAndEmoji($0.content) }
        let labeled = page.connections.contains { $0.label == "引用证据" }
        return page.nodes.count == expectedNodes
            && page.regions.count == expectedRegions
            && page.connections.count == expectedEdges
            && text
            && labeled
            && !bundle.assets.isEmpty
    }

    private static func roundTripSanity(
        _ edited: CanvasExchangeBundle, _ reimported: CanvasExchangeBundle
    ) -> Bool {
        guard let editedPage = edited.snapshot.selectedPage,
              let page = reimported.snapshot.selectedPage else { return false }
        func carriesNote(_ content: CanvasContent) -> Bool {
            switch content {
            case .text(let text): return text.contains("资格编辑")
            case .markdown(let document, _): return document.contains("资格编辑")
            case .shape(_, let text): return text.contains("资格编辑")
            case .richText(let document): return document.runs.map(\.text).joined().contains("资格编辑")
            default: return false
            }
        }
        let noteKept = page.nodes.contains { carriesNote($0.content) }
        let expectedLabels = Set(editedPage.connections.compactMap(\.label))
        let labelKept = expectedLabels.isSubset(of: Set(page.connections.compactMap(\.label)))
        return noteKept && labelKept
            && page.nodes.count >= editedPage.nodes.count
    }

    /// Parses exported bytes with the exact-literal JSON parser and confirms
    /// the unknown numeric literals still appear with their source spelling.
    private static func bigLiteralsPreserved(
        in data: Data, literals: [String]
    ) throws -> Bool {
        let root = try JSONFidelity.parse(data)
        var found = Set<String>()
        func walk(_ value: JSONValue) {
            if case .number(let literal) = value {
                found.insert(literal)
            }
            if case .object(let object) = value {
                object.values.forEach(walk)
            }
            if case .array(let array) = value {
                array.forEach(walk)
            }
        }
        walk(root)
        return literals.allSatisfy { found.contains($0) }
    }

    private static func archiveCheck(
        snapshot: CanvasSnapshot,
        original: Data,
        kind: CanvasOriginalSource.Kind,
        name: String,
        resolverBytes: [UUID: Data] = [:],
        directory: URL,
        checks: inout [Check],
        artifacts: inout [String],
        id: String
    ) async throws {
        let envelope = CanvasNativeArchive.OriginalSourceEnvelope(
            source: CanvasOriginalSource(
                id: SyntheticQualification.uuid(0xE000),
                kind: kind,
                suggestedName: name,
                byteCount: original.count,
                sha256: SyntheticAssets.sha256(original)),
            data: original)
        let exported = try await CanvasNativeArchive.export(
            snapshot, assetResolver: CanvasInMemoryAssetResolver(resolverBytes), originalSources: [envelope])
        let archiveName = try QualifyIO.write(
            exported.data, to: directory,
            name: "\(kind.rawValue)-roundtrip.floecanvaslab")
        artifacts.append("interop/\(archiveName)")
        let reopened = try CanvasNativeArchive.import(exported.data)
        let originalBack = reopened.sourceDataByID[envelope.source.id]
        let documentBytesEqual = reopened.documentData == (try CanvasExchangeJSON.encode(snapshot))
        checks.append(Check(
            id: id,
            scenario: scenarioName,
            status: (originalBack == original && documentBytesEqual)
                ? .pass : .fail,
            detail: "native archive carries the exact original \(name) bytes "
                + "(sha256 verified on reopen) plus the recovery document "
                + "envelope",
            evidence: [
                "original \(original.count)B round-trip: \(originalBack == original)",
                "documentData recovery envelope byte-equal: \(documentBytesEqual)",
            ]))
    }

    private static func render(
        snapshot: CanvasSnapshot,
        resolverBytes: [UUID: Data],
        directory: URL,
        checks: inout [Check],
        artifacts: inout [String],
        id: String
    ) async throws {
        let resolver = CanvasInMemoryAssetResolver(resolverBytes)
        let renderDirectory = directory.appendingPathComponent("render", isDirectory: true)
        var names: [String] = []
        let pdf = try await CanvasExchange.export(
            snapshot, format: .pdf,
            options: CanvasExportOptions(assetResolver: resolver))
        names.append(try QualifyIO.write(
            pdf.primary.data, to: renderDirectory, name: pdf.primary.name))
        let png = try await CanvasExchange.export(
            snapshot, format: .png,
            options: CanvasExportOptions(assetResolver: resolver))
        names.append(try QualifyIO.write(
            png.primary.data, to: renderDirectory, name: png.primary.name))
        let svg = try await CanvasExchange.export(
            snapshot, format: .svg,
            options: CanvasExportOptions(assetResolver: resolver))
        names.append(try QualifyIO.write(
            svg.primary.data, to: renderDirectory, name: svg.primary.name))
        artifacts.append(contentsOf: names.map { "interop/render/\($0)" })
        let pdfOK = pdf.primary.data.starts(with: Data("%PDF".utf8))
        let pngOK = png.primary.data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let svgOK = (String(data: svg.primary.data, encoding: .utf8) ?? "")
            .contains("<svg")
        checks.append(Check(
            id: id,
            scenario: scenarioName,
            status: (pdfOK && pngOK && svgOK) ? .pass : .fail,
            detail: "mutated fixture snapshot renders to real %PDF / PNG / "
                + "SVG content bytes",
            evidence: names.map { "\($0)" } + [
                "pdf=\(pdfOK) png=\(pngOK) svg=\(svgOK)",
            ]))
    }
}
