// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

/// Native-archive closure for reusable flow template definitions: reachable
/// definitions embed transitively (never the whole host registry), typed
/// asset references inside template variables and predicate operands embed,
/// corrupt/missing/wrong-version/duplicate definitions fail integrity, and
/// recovery is data-only — never execution.
final class FlowTemplateArchiveTests: XCTestCase {
    private let templateA = UUID(uuidString: "aaaaaaaa-0000-0000-0000-00000000000a")!
    private let templateB = UUID(uuidString: "bbbbbbbb-0000-0000-0000-00000000000b")!
    private let templateC = UUID(uuidString: "cccccccc-0000-0000-0000-00000000000c")!
    private let templateAsset = UUID(uuidString: "dddddddd-0000-0000-0000-00000000000d")!
    private let predicateAsset = UUID(uuidString: "eeeeeeee-0000-0000-0000-00000000000e")!

    /// Template B: carries its asset only through typed flow values — one
    /// variable initial and one predicate operand literal.
    private func definitionB() -> CanvasNativeArchive.FlowTemplateDefinition {
        let variable = FlowVariable(
            id: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000555")!,
            name: "source",
            dataType: .asset,
            ownerNodeID: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000111")!,
            initial: .asset(CanvasAssetLocator(id: templateAsset, mimeType: "image/png", byteCount: 3))
        )
        let condition = FlowNode(
            id: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000222")!,
            kind: .condition,
            name: "gate",
            branches: [
                FlowConditionBranch(
                    id: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000666")!,
                    predicate: .comparison(
                        .isEmpty,
                        lhs: .literal(.asset(CanvasAssetLocator(id: predicateAsset, mimeType: "image/png", byteCount: 3))),
                        rhs: .literal(.bool(false))
                    ),
                    outputPortID: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000333")!
                )
            ]
        )
        let graph = FlowGraph(
            id: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000444")!,
            nodes: [condition],
            variables: [variable]
        )
        return CanvasNativeArchive.FlowTemplateDefinition(
            id: templateB,
            version: 1,
            name: "B",
            graph: graph
        )
    }

    /// Template A: references B; also exercises raw unknown numeric
    /// parameters (exact literal spelling must survive).
    private func definitionA() -> CanvasNativeArchive.FlowTemplateDefinition {
        let useB = FlowNode(
            id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000111")!,
            kind: .subgraph,
            name: "useB",
            parameters: ["big": .number("92233720368547758081234567890"), "precise": .number("0.123456789012345678901234567890")],
            subgraphTemplateID: templateB
        )
        let graph = FlowGraph(
            id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000222")!,
            nodes: [useB]
        )
        return CanvasNativeArchive.FlowTemplateDefinition(
            id: templateA,
            version: 2,
            name: "A",
            graph: graph
        )
    }

    /// Snapshot whose page graph references template A through a subgraph
    /// node (registered via `group.id`, the second registration point).
    private func snapshotReferencingA() -> CanvasSnapshot {
        var group = FlowGroupDescriptor(id: templateA, version: 2, name: "A")
        group.exposedPorts = [FlowPort(name: "out", dataType: .asset, direction: .output)]
        let node = FlowNode(
            id: UUID(uuidString: "77777777-0000-0000-0000-000000000111")!,
            kind: .subgraph,
            name: "runA",
            group: group
        )
        let graph = FlowGraph(
            id: UUID(uuidString: "77777777-0000-0000-0000-000000000222")!,
            nodes: [node]
        )
        let page = CanvasPageSnapshot(name: "P", nodes: [], flowGraphs: [graph])
        return CanvasSnapshot(name: "T", pages: [page])
    }

    func testNestedTemplateDependenciesAndAssetsRoundTripWithoutHostRegistry() async throws {
        let snapshot = snapshotReferencingA()
        let registry = [definitionA(), definitionB(), CanvasNativeArchive.FlowTemplateDefinition(
            id: templateC,
            version: 1,
            name: "unrelated",
            graph: FlowGraph(id: UUID(uuidString: "cccccccc-0000-0000-0000-000000000111")!)
        )]
        let assetBytes = Data([0x89, 0x50, 0x4E])
        let predicateBytes = Data([0x47, 0x0D, 0x0A])

        let exported = try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([templateAsset: assetBytes, predicateAsset: predicateBytes]),
            flowTemplates: registry
        )
        // Only reachable definitions embed — the unrelated registry entry
        // must not leak into the archive.
        XCTAssertEqual(exported.manifest.flowTemplates.map(\.id), [templateA, templateB])
        XCTAssertEqual(exported.issues, [])

        // Reopen with NO host registry: definitions verify from the archive.
        let reopened = try CanvasNativeArchive.import(exported.data)
        XCTAssertEqual(Set(reopened.flowTemplates.map(\.id)), [templateA, templateB])
        let recoveredA = try XCTUnwrap(reopened.flowTemplates.first(where: { $0.id == templateA }))
        let recoveredB = try XCTUnwrap(reopened.flowTemplates.first(where: { $0.id == templateB }))
        XCTAssertEqual(recoveredA, definitionA())
        XCTAssertEqual(recoveredB, definitionB())
        XCTAssertEqual(reopened.assets[templateAsset], assetBytes, "template variable asset embeds")
        XCTAssertEqual(reopened.assets[predicateAsset], predicateBytes, "template predicate operand asset embeds")

        // Raw unknown numeric literals in template parameters keep their
        // exact spelling.
        let useB = try XCTUnwrap(recoveredA.graph.nodes.first)
        XCTAssertEqual(useB.parameters["big"]?.numberLiteral, "92233720368547758081234567890")
        XCTAssertEqual(useB.parameters["precise"]?.numberLiteral, "0.123456789012345678901234567890")
    }

    func testMissingReferencedTemplateFailsCompleteExport() async throws {
        let snapshot = snapshotReferencingA()
        await XCTAssertThrowsAsyncError(try await CanvasNativeArchive.export(snapshot, flowTemplates: [])) { error in
            guard case CanvasExchangeError.invalid(let message) = error else {
                return XCTFail("invalid expected, got \(error)")
            }
            XCTAssertTrue(message.contains(templateA.uuidString), "the failure names the missing template")
        }
    }

    func testMissingTemplateEntryFailsImportAsIncomplete() async throws {
        let snapshot = snapshotReferencingA()
        let exported = try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([templateAsset: Data([1, 2, 3]), predicateAsset: Data([1, 2, 3])]),
            flowTemplates: [definitionA(), definitionB()]
        )
        var entries = try CanvasLabZIP.unpack(exported.data)
        var manifest = exported.manifest
        manifest.flowTemplates.removeAll { $0.id == templateB }
        entries[CanvasNativeArchive.manifestPath] = try CanvasExchangeJSON.encode(manifest)
        XCTAssertThrowsError(try CanvasNativeArchive.import(CanvasLabZIP.pack(entries))) { error in
            guard case CanvasExchangeError.integrity(let message) = error else {
                return XCTFail("integrity expected, got \(error)")
            }
            XCTAssertTrue(message.contains("flow template"), "incomplete template closure is an integrity failure")
        }
    }

    func testCorruptTemplateBytesFailIntegrity() async throws {
        let snapshot = snapshotReferencingA()
        let exported = try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([templateAsset: Data([1, 2, 3]), predicateAsset: Data([1, 2, 3])]),
            flowTemplates: [definitionA(), definitionB()]
        )
        var entries = try CanvasLabZIP.unpack(exported.data)
        let path = exported.manifest.flowTemplates.first { $0.id == templateA }!.path
        var bytes = entries[path]!
        bytes[0] = bytes[0] ^ 0xFF
        entries[path] = bytes
        XCTAssertThrowsError(try CanvasNativeArchive.import(CanvasLabZIP.pack(entries))) { error in
            guard case CanvasExchangeError.integrity = error else {
                return XCTFail("integrity expected, got \(error)")
            }
        }
    }

    func testWrongVersionTemplateFailsIntegrity() async throws {
        let snapshot = snapshotReferencingA()
        let exported = try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([templateAsset: Data([1, 2, 3]), predicateAsset: Data([1, 2, 3])]),
            flowTemplates: [definitionA(), definitionB()]
        )
        var entries = try CanvasLabZIP.unpack(exported.data)
        var manifest = exported.manifest
        let index = manifest.flowTemplates.firstIndex { $0.id == templateA }!
        manifest.flowTemplates[index].version = 99
        entries[CanvasNativeArchive.manifestPath] = try CanvasExchangeJSON.encode(manifest)
        XCTAssertThrowsError(try CanvasNativeArchive.import(CanvasLabZIP.pack(entries))) { error in
            guard case CanvasExchangeError.integrity(let message) = error else {
                return XCTFail("integrity expected, got \(error)")
            }
            XCTAssertTrue(message.contains("version"), "a manifest/file version mismatch is an integrity failure")
        }
    }

    func testDuplicateTemplateInManifestFailsIntegrity() async throws {
        let snapshot = snapshotReferencingA()
        let exported = try await CanvasNativeArchive.export(
            snapshot,
            assetResolver: CanvasInMemoryAssetResolver([templateAsset: Data([1, 2, 3]), predicateAsset: Data([1, 2, 3])]),
            flowTemplates: [definitionA(), definitionB()]
        )
        var entries = try CanvasLabZIP.unpack(exported.data)
        var manifest = exported.manifest
        manifest.flowTemplates.append(manifest.flowTemplates.first { $0.id == templateA }!)
        entries[CanvasNativeArchive.manifestPath] = try CanvasExchangeJSON.encode(manifest)
        XCTAssertThrowsError(try CanvasNativeArchive.import(CanvasLabZIP.pack(entries))) { error in
            guard case CanvasExchangeError.integrity = error else {
                return XCTFail("integrity expected, got \(error)")
            }
        }
    }

    func testRecursiveReferenceAndUnconfiguredDraftReportedHonestly() async throws {
        // Cyclic pair: X <-> Y. Both embed completely; the export reports
        // the recursion as a data-only observation.
        let templateX = UUID(uuidString: "abababab-0000-0000-0000-000000000099")!
        let templateY = UUID(uuidString: "cdcdcdcd-0000-0000-0000-000000000099")!
        let nodeX = FlowNode(kind: .subgraph, name: "useY", subgraphTemplateID: templateY)
        let nodeY = FlowNode(kind: .subgraph, name: "useX", subgraphTemplateID: templateX)
        let defX = CanvasNativeArchive.FlowTemplateDefinition(id: templateX, version: 1, name: "X", graph: FlowGraph(nodes: [nodeX]))
        let defY = CanvasNativeArchive.FlowTemplateDefinition(id: templateY, version: 1, name: "Y", graph: FlowGraph(nodes: [nodeY]))

        // A draft subgraph node references nothing at all.
        let draft = FlowNode(kind: .subgraph, name: "draft")
        let pageGraph = FlowGraph(nodes: [nodeX, draft])
        let page = CanvasPageSnapshot(name: "P", nodes: [], flowGraphs: [pageGraph])
        let snapshot = CanvasSnapshot(name: "C", pages: [page])

        let exported = try await CanvasNativeArchive.export(snapshot, flowTemplates: [defX, defY])
        XCTAssertEqual(Set(exported.manifest.flowTemplates.map(\.id)), [templateX, templateY])
        XCTAssertTrue(exported.issues.contains(where: { $0.code == "flowTemplate.recursiveReference" }))
        XCTAssertTrue(exported.issues.contains(where: { $0.code == "flowTemplate.unconfiguredDraft" }))

        // Data is still complete: reopening recovers both cyclic definitions.
        let reopened = try CanvasNativeArchive.import(exported.data)
        XCTAssertEqual(Set(reopened.flowTemplates.map(\.id)), [templateX, templateY])
    }

    func testImportNeverExecutesTemplateGraphs() async throws {
        // A template graph containing a custom-script node imports as pure
        // data: no resolver, no child provider, no runtime of any kind.
        let script = FlowNode(
            kind: .customScript,
            name: "script",
            script: FlowScriptDescriptor(language: "bash", sourceHash: "abc123", entryPoint: "main")
        )
        let def = CanvasNativeArchive.FlowTemplateDefinition(
            id: templateA,
            version: 1,
            name: "scripted",
            graph: FlowGraph(nodes: [script])
        )
        let user = FlowNode(kind: .subgraph, name: "use", subgraphTemplateID: templateA)
        let page = CanvasPageSnapshot(name: "P", nodes: [], flowGraphs: [FlowGraph(nodes: [user])])
        let snapshot = CanvasSnapshot(name: "S", pages: [page])

        let exported = try await CanvasNativeArchive.export(snapshot, flowTemplates: [def])
        let reopened = try CanvasNativeArchive.import(exported.data)
        let recovered = try XCTUnwrap(reopened.flowTemplates.first)
        XCTAssertEqual(recovered.graph.nodes.first?.kind, .customScript)
        XCTAssertEqual(recovered.graph.nodes.first?.script?.sourceHash, "abc123")
    }

    func testOldArchiveWithoutTemplatesStaysValid() async throws {
        let snapshot = CanvasSnapshot(name: "Legacy", pages: [CanvasPageSnapshot(name: "P")])
        let exported = try await CanvasNativeArchive.export(snapshot)
        XCTAssertEqual(exported.manifest.flowTemplates, [])
        let reopened = try CanvasNativeArchive.import(exported.data)
        XCTAssertEqual(reopened.snapshot, snapshot)
        XCTAssertEqual(reopened.flowTemplates, [])
    }

    func testFacadeBundleCarriesVerifiedTemplates() async throws {
        let snapshot = snapshotReferencingA()
        let assetBytes = Data([0x89, 0x50, 0x4E])
        let predicateBytes = Data([0x47, 0x0D, 0x0A])
        let output = try await CanvasExchange.export(
            snapshot,
            format: .floecanvaslab,
            options: .init(
                assetResolver: CanvasInMemoryAssetResolver([templateAsset: assetBytes, predicateAsset: predicateBytes]),
                flowTemplates: [definitionA(), definitionB()]
            )
        )
        let bundle = try await CanvasExchange.importData(output.primary.data, format: .floecanvaslab)
        XCTAssertEqual(Set(bundle.flowTemplates.map(\.id)), [templateA, templateB])
        XCTAssertEqual(bundle.assets[templateAsset], assetBytes)
        XCTAssertEqual(bundle.assets[predicateAsset], predicateBytes)
    }
}
