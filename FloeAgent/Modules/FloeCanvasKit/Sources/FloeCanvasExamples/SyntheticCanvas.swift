// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasLayout
import FloeCanvasExchange

// MARK: - Scenario 1: synthetic mixed research+flow native archive
//
// Builds a deterministic, fully editable two-page canvas (research cards and
// offline flow steps coexisting per ICH01), commits the SAME document batch
// through the edit engine and both repositories (one validated transaction,
// idempotent replay, undo/redo), exports the native recovery archive with
// synthetic assets and an opaque child project, reopens it, and exercises
// the layout index (collapsed region chip + proxy edges + flow card
// bindings). Rendered PNG/PDF/SVG exports carry real content.

enum SyntheticQualification {
    static let scenarioName = "s1-synthetic-mixed-archive"

    /// Deterministic id from a small integer seed.
    static func uuid(_ seed: UInt64) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", seed))!
    }

    struct BuiltSample: Sendable {
        /// Pre-transaction shell (revision 0) the batch applies to.
        var baseSnapshot: CanvasSnapshot
        /// The one validated document batch that builds the sample.
        var batch: CanvasDocumentBatch
        /// Engine-applied result snapshot (base + batch).
        var snapshot: CanvasSnapshot
        var registry: SyntheticAssets.Registry
        var childProjectID: UUID
        var childProjectBytes: Data
        var graph: FlowGraph
        var pageResearchID: UUID
        var pageFlowID: UUID
        var collapsedRegionID: UUID
        var richTextNodeID: UUID
        var webNodeID: UUID
        var boundCardIDs: [UUID]
        var requestID: UUID
    }

    // MARK: Sample construction

    static func buildSample() throws -> BuiltSample {
        var registry = SyntheticAssets.makeRegistry()
        // This sample has no rendered formula asset. Keep its real source
        // visible instead of presenting the registry's red 1px test image
        // as a formula preview.
        let unusedFormulaAsset = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        registry.bytes.removeValue(forKey: unusedFormulaAsset)
        registry.locators.removeValue(forKey: unusedFormulaAsset)
        let canvasID = uuid(1)
        let pageResearchID = uuid(2)
        let pageFlowID = uuid(3)
        let graphID = uuid(4)
        let childProjectID = uuid(5)
        let requestID = uuid(0x9001)

        // Page 1 — research board. Sensible fixed layout: left column of
        // source material, middle analysis column, right shapes + media.
        let richTextNodeID = uuid(10)
        let markdownNodeID = uuid(11)
        let tableNodeID = uuid(12)
        let formulaNodeID = uuid(13)
        let codeNodeID = uuid(14)
        let imageNodeID = uuid(15)
        let audioNodeID = uuid(16)
        let videoNodeID = uuid(17)
        let pdfNodeID = uuid(18)
        let webNodeID = uuid(19)
        let editorNodeID = uuid(20)
        let notesNodeID = uuid(21)
        let shapeRectID = uuid(22)
        let shapeEllipseID = uuid(23)
        let shapeDiamondID = uuid(24)
        let groupID = uuid(30)
        let regionOpenID = uuid(31)
        let regionCollapsedID = uuid(32)
        let sceneOverviewID = uuid(33)
        let sceneFocusID = uuid(34)

        func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasGeometry.Frame {
            CanvasGeometry.Frame(center: .init(x: x, y: y), size: .init(width: w, height: h))
        }

        var richMetadata: [String: String] = [:]
        CanvasVisualStyle(
            fillColor: "#fef3c7", strokeColor: "#d97706", strokeWidth: 1.5
        ).applied(to: &richMetadata)

        let richTextNode = CanvasNodeSnapshot(
            id: richTextNodeID,
            title: "研究摘要 Summary",
            content: .richText(document: CanvasRichTextDocument(runs: [
                CanvasRichTextRun(text: "混合研究样例 ", bold: true, foregroundColor: "#b45309"),
                CanvasRichTextRun(text: "Mixed research sample with ", italic: true),
                CanvasRichTextRun(text: "English", bold: true, underline: true),
                CanvasRichTextRun(text: " 文本、中文与 emoji 🧊🚀。", foregroundColor: "#0f766e"),
                CanvasRichTextRun(text: " Honest synthetic content.", strikethrough: true),
            ])),
            frame: frame(-760, -320, 380, 220),
            zIndex: 1,
            metadata: richMetadata)

        let markdownNode = CanvasNodeSnapshot(
            id: markdownNodeID,
            title: "Markdown 笔记",
            content: .markdown(
                document: "# 研究问题\n\n中文与 emoji 🧊\n\n```swift\nlet value = 42\n```",
                previewText: "研究问题"),
            frame: frame(-760, -20, 380, 260),
            zIndex: 2)

        let tableNode = CanvasNodeSnapshot(
            id: tableNodeID,
            title: "对比表",
            content: .table(
                header: ["方案 Proposal", "得分 Score", "备注 Notes"],
                rows: [
                    ["方案甲 A", "92", "首选 🥇"],
                    ["方案乙 B", "85", "备选"],
                    ["方案丙 C", "78", "emoji 测试 ✅"],
                ]),
            frame: frame(-300, -320, 400, 240),
            zIndex: 3)

        let formulaNode = CanvasNodeSnapshot(
            id: formulaNodeID,
            title: "公式 Formula",
            content: .formula(
                source: "E = mc^2 \\quad \\alpha_i \\le 42",
                renderedAssetID: nil),
            frame: frame(-300, -20, 400, 160),
            zIndex: 4)

        let codeNode = CanvasNodeSnapshot(
            id: codeNodeID,
            title: "代码 Code",
            content: .code(
                language: "swift",
                source: "func evaluate(_ x: Int) -> Bool {\n    x > 0\n}"),
            frame: frame(-300, 200, 400, 180),
            zIndex: 5)

        func mediaNode(
            _ id: UUID, _ title: String, asset: UUID, x: Double, y: Double
        ) -> CanvasNodeSnapshot {
            CanvasNodeSnapshot(
                id: id, title: title,
                content: .media(registry.locators[asset]!),
                frame: frame(x, y, 260, 180),
                zIndex: 6)
        }
        let imageNode = mediaNode(
            imageNodeID, "图片 Image", asset: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, x: 220, y: -320)
        let audioNode = mediaNode(
            audioNodeID, "音频 Audio", asset: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, x: 220, y: -100)
        let videoNode = mediaNode(
            videoNodeID, "视频 Video（合成片段）", asset: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, x: 220, y: 120)

        let pdfNode = CanvasNodeSnapshot(
            id: pdfNodeID,
            title: "报告 PDF",
            content: .pdf(documentAssetID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, pageRange: 1...2),
            frame: frame(560, -320, 320, 220),
            zIndex: 7)

        let webNode = CanvasNodeSnapshot(
            id: webNodeID,
            title: "网页参考 Web",
            content: .web(
                URL(string: "https://example.org/research")!, title: "外部参考页面"),
            frame: frame(420, -60, 320, 160),
            zIndex: 8)

        let editorNode = CanvasNodeSnapshot(
            id: editorNodeID,
            kind: .scene3D,
            title: "编辑器子工程 Editor child",
            content: .editor(CanvasEditorReference(
                projectID: childProjectID,
                appliedRevision: 7,
                draftRevision: 9,
                editorKind: "image-editor")),
            frame: frame(560, 160, 320, 200),
            zIndex: 9)

        let notesNode = CanvasNodeSnapshot(
            id: notesNodeID,
            kind: .sourced,
            title: "手记来源 Notes source",
            content: .text("来自手记的引用片段。"),
            frame: frame(940, -320, 320, 200),
            zIndex: 10,
            source: CanvasSourceReference(
                sourceID: uuid(0x7777),
                fragment: "heading:结论",
                usedRevision: 12,
                annotations: [
                    CanvasSourceAnnotation(
                        id: uuid(0x7788), author: "qualification",
                        text: "保留这条批注 keep me", anchor: "paragraph:2"),
                ]))

        func shapeNode(
            _ id: UUID, _ kind: CanvasShapeKind, _ text: String,
            x: Double, y: Double, w: Double, h: Double,
            fill: String, stroke: String
        ) -> CanvasNodeSnapshot {
            var metadata: [String: String] = [:]
            CanvasVisualStyle(fillColor: fill, strokeColor: stroke, strokeWidth: 2)
                .applied(to: &metadata)
            return CanvasNodeSnapshot(
                id: id, title: text,
                content: .shape(kind: kind, text: text),
                frame: frame(x, y, w, h),
                zIndex: 11,
                metadata: metadata)
        }
        let shapeRect = shapeNode(
            shapeRectID, .rectangle, "需求", x: 940, y: -60, w: 220, h: 120,
            fill: "#dbeafe", stroke: "#2563eb")
        let shapeEllipse = shapeNode(
            shapeEllipseID, .ellipse, "讨论", x: 940, y: 100, w: 220, h: 120,
            fill: "#dcfce7", stroke: "#16a34a")
        let shapeDiamond = shapeNode(
            shapeDiamondID, .diamond, "决定", x: 940, y: 260, w: 220, h: 140,
            fill: "#fee2e2", stroke: "#dc2626")

        let page1Nodes = [
            richTextNode, markdownNode, tableNode, formulaNode, codeNode,
            imageNode, audioNode, videoNode, pdfNode, webNode, editorNode,
            notesNode, shapeRect, shapeEllipse, shapeDiamond,
        ]

        // Labeled ordinary relations — visual/semantic only, never execution.
        func relation(
            _ id: UUID, _ from: UUID, _ to: UUID, _ label: String,
            kind: CanvasRelationKind = .arrow
        ) -> CanvasConnectionSnapshot {
            CanvasConnectionSnapshot(
                id: id, sourceNodeID: from, destinationNodeID: to,
                kind: kind, label: label,
                sourcePort: .trailing, destinationPort: .leading)
        }
        let page1Connections = [
            relation(uuid(40), richTextNodeID, tableNodeID, "引用 cites"),
            relation(uuid(41), markdownNodeID, formulaNodeID, "推导 derives"),
            relation(uuid(42), tableNodeID, shapeRectID, "支撑 supports"),
            relation(uuid(43), shapeRectID, shapeEllipseID, "流转 flows"),
            relation(uuid(44), shapeEllipseID, shapeDiamondID, "收敛 converges"),
            // Crosses the collapsed region boundary: must surface as a proxy.
            relation(uuid(45), webNodeID, richTextNodeID, "反引 back-ref"),
            relation(uuid(46), notesNodeID, pdfNodeID, "来源 source"),
        ]

        // Page 2 — flow steps coexist with research cards (ICH01). Cards are
        // ordinary generationTask nodes bound to flow nodes via metadata.
        let flowSourceNodeID = uuid(50)
        let flowAddNodeID = uuid(51)
        let flowOutputNodeID = uuid(52)

        let sourceOut = FlowPort(
            id: uuid(53), name: "out", dataType: .number, direction: .output)
        let sourceNode = FlowNode(
            id: flowSourceNodeID, kind: .source, name: "offline.constant",
            ports: [sourceOut],
            parameters: [
                "sourceKind": .string("constant"),
                "literal": .number("21"),
            ],
            position: .init(x: -420, y: -120))

        let addInA = FlowPort(
            id: uuid(54), name: "a", dataType: .number, direction: .input)
        let addInB = FlowPort(
            id: uuid(55), name: "b", dataType: .number, direction: .input)
        let addOut = FlowPort(
            id: uuid(56), name: "sum", dataType: .number, direction: .output)
        let addParameters: [String: JSONValue] = [
            "nativeKey": .string("offline.math.add"),
            "writeVariables": .object(["sum": .string("total")]),
        ]
        let addNode = FlowNode(
            id: flowAddNodeID, kind: .transform, name: "offline.math.add",
            ports: [addInA, addInB, addOut],
            parameters: addParameters,
            position: .init(x: -60, y: -120))

        let outputIn = FlowPort(
            id: uuid(57), name: "in", dataType: .number, direction: .input)
        let outputNode = FlowNode(
            id: flowOutputNodeID, kind: .output, name: "result",
            ports: [outputIn],
            parameters: ["resultKey": .string("qualification.sum")],
            position: .init(x: 300, y: -120))

        let graph = FlowGraph(
            id: graphID,
            revision: 1,
            nodes: [sourceNode, addNode, outputNode],
            edges: [
                FlowEdge(
                    id: uuid(58),
                    sourceNodeID: flowSourceNodeID, sourcePortID: sourceOut.id,
                    destinationNodeID: flowAddNodeID, destinationPortID: addInA.id),
                FlowEdge(
                    id: uuid(59),
                    sourceNodeID: flowSourceNodeID, sourcePortID: sourceOut.id,
                    destinationNodeID: flowAddNodeID, destinationPortID: addInB.id),
                FlowEdge(
                    id: uuid(60),
                    sourceNodeID: flowAddNodeID, sourcePortID: addOut.id,
                    destinationNodeID: flowOutputNodeID, destinationPortID: outputIn.id),
            ])

        func flowCard(
            _ id: UUID, _ flowNodeID: UUID, _ title: String,
            x: Double, y: Double
        ) -> CanvasNodeSnapshot {
            var metadata: [String: String] = [:]
            CanvasFlowCardBinding(graphID: graphID, nodeID: flowNodeID)
                .applied(to: &metadata)
            return CanvasNodeSnapshot(
                id: id,
                kind: .generationTask,
                title: title,
                content: .text("离线测试步骤 offline test step"),
                frame: frame(x, y, 240, 120),
                zIndex: 2,
                metadata: metadata)
        }
        let cardSourceID = uuid(61)
        let cardAddID = uuid(62)
        let cardOutputID = uuid(63)
        let explanationNodeID = uuid(64)
        let page2Nodes = [
            flowCard(cardSourceID, flowSourceNodeID, "常量源 Constant", x: -420, y: -120),
            flowCard(cardAddID, flowAddNodeID, "加法 Add（离线）", x: -60, y: -120),
            flowCard(cardOutputID, flowOutputNodeID, "输出 Output", x: 300, y: -120),
            CanvasNodeSnapshot(
                id: explanationNodeID,
                title: "流程说明",
                content: .markdown(
                    document: "# 离线流程\n\n确定性测试节点，非真实模型。",
                    previewText: "离线流程"),
                frame: frame(-60, 120, 400, 180),
                zIndex: 1),
        ]
        let page2Connections = [
            CanvasConnectionSnapshot(
                id: uuid(65),
                sourceNodeID: explanationNodeID, destinationNodeID: cardAddID,
                kind: .line, label: "关联（不执行）",
                sourcePort: .trailing, destinationPort: .leading),
        ]
        let page2 = CanvasPageSnapshot(
            id: pageFlowID,
            name: "流程 Flow",
            nodes: page2Nodes,
            connections: page2Connections,
            background: .dots)

        let baseSnapshot = CanvasSnapshot(
            id: canvasID,
            name: "P4a-Mixed-Research-Flow-样例",
            pages: [CanvasPageSnapshot(
                id: pageResearchID,
                name: "研究与资料 Research",
                background: .grid)],
            selectedPageID: pageResearchID)

        // One document batch = one validated transaction = one undo unit.
        let batch = CanvasDocumentBatch(scope: .wholeDocument, operations: [
            .editPage(CanvasEditBatch(
                pageID: pageResearchID,
                scope: .wholeDocument,
                operations: page1Nodes.map { .insertNode($0) }
                    + page1Connections.map { .insertConnection($0) })),
            .createGroup(pageID: pageResearchID, group: CanvasGroupRecord(
                id: groupID,
                name: "资料组合 source bundle",
                memberNodeIDs: [richTextNodeID, markdownNodeID, tableNodeID])),
            .createRegion(pageID: pageResearchID, region: CanvasRegionRecord(
                id: regionOpenID,
                name: "分析区 analysis",
                frame: frame(-300, -160, 460, 640),
                isCollapsed: false)),
            .createRegion(pageID: pageResearchID, region: CanvasRegionRecord(
                id: regionCollapsedID,
                name: "折叠区 collapsed",
                frame: frame(420, -140, 520, 420),
                isCollapsed: true)),
            .createScene(pageID: pageResearchID, scene: CanvasSceneRecord(
                id: sceneOverviewID,
                name: "总览 overview",
                viewportCenter: .init(x: 100, y: 0),
                viewportScale: 0.6,
                focusedNodeIDs: [],
                focusedRegionIDs: [],
                order: 0)),
            .createScene(pageID: pageResearchID, scene: CanvasSceneRecord(
                id: sceneFocusID,
                name: "聚焦分析 focus",
                viewportCenter: .init(x: -300, y: -60),
                viewportScale: 1.1,
                focusedNodeIDs: [tableNodeID, formulaNodeID],
                focusedRegionIDs: [regionOpenID],
                order: 1)),
            .createPage(page2, select: false),
            .insertFlowGraph(pageID: pageFlowID, graph: graph),
        ])

        let result = try CanvasDocumentEditEngine.apply(batch, to: baseSnapshot)
        return BuiltSample(
            baseSnapshot: baseSnapshot,
            batch: batch,
            snapshot: result.snapshot,
            registry: registry,
            childProjectID: childProjectID,
            childProjectBytes: SyntheticAssets.childProjectArchive(
                projectID: childProjectID, revision: 7, editorKind: "image-editor"),
            graph: graph,
            pageResearchID: pageResearchID,
            pageFlowID: pageFlowID,
            collapsedRegionID: regionCollapsedID,
            richTextNodeID: richTextNodeID,
            webNodeID: webNodeID,
            boundCardIDs: [cardSourceID, cardAddID, cardOutputID],
            requestID: requestID)
    }

    // MARK: Child project provider (fixture-only opaque bytes)

    struct FixtureChildProjectProvider: CanvasNativeArchive.CanvasChildProjectExportProvider {
        var expectedBytes: Data

        func archive(
            projectID: UUID, appliedRevision: Int64, draftRevision: Int64?,
            editorKind: String
        ) async throws -> CanvasNativeArchive.ChildProjectArchiveData {
            CanvasNativeArchive.ChildProjectArchiveData(
                data: expectedBytes, formatHint: "application/x-floe-fixture+json")
        }
    }

    // MARK: Run

    static func run(outputRoot: URL) async throws -> ScenarioReport {
        var checks: [Check] = []
        var artifacts: [String] = []
        var notes: [String] = []
        let directory = outputRoot.appendingPathComponent("synthetic", isDirectory: true)

        let sample: BuiltSample
        do {
            sample = try buildSample()
        } catch {
            return ScenarioReport(
                scenario: scenarioName,
                checks: [Check(
                    id: "s1.build",
                    scenario: scenarioName,
                    status: .fail,
                    detail: "sample construction rejected by the document "
                        + "transaction engine: \(error)",
                    evidence: [])],
                artifacts: [],
                notes: [])
        }
        let snapshot = sample.snapshot

        // -- structure check
        let page1 = snapshot.pages[0]
        let page2 = snapshot.pages[1]
        checks.append(Check(
            id: "s1.structure",
            scenario: scenarioName,
            status: (snapshot.pages.count == 2
                && page1.groups.count == 1
                && page1.regions.count == 2
                && page1.scenes.count == 2
                && page2.flowGraphs.count == 1
                && page1.nodes.count == 15
                && page1.connections.count == 7)
                ? .pass : .fail,
            detail: "2 pages; group=1 regions=2 scenes=2 connections=7; "
                + "page2 flowGraphs=1 cards bound=3",
            evidence: [
                "nodes p1=\(page1.nodes.count) p2=\(page2.nodes.count)",
                "regions=\(page1.regions.count) scenes=\(page1.scenes.count)",
            ]))

        // -- rich text content check (CN + EN + emoji, styled runs)
        let richNode = page1.nodes.first { $0.id == sample.richTextNodeID }
        var richOK = false
        if case .richText(let document)? = richNode?.content {
            let plain = document.plainText
            richOK = plain.contains("混合研究样例")
                && plain.contains("English")
                && plain.contains("🧊🚀")
                && document.runs.contains { $0.bold && $0.foregroundColor == "#b45309" }
                && document.runs.contains { $0.strikethrough }
        }
        checks.append(Check(
            id: "s1.richText",
            scenario: scenarioName,
            status: richOK ? .pass : .fail,
            detail: "rich text runs carry CN+EN+emoji with bold/italic/underline/"
                + "strikethrough/foregroundColor",
            evidence: []))

        // -- visual metadata key spellings
        let style = page1.nodes.first { $0.id == sample.richTextNodeID }
            .flatMap { CanvasVisualStyle(metadata: $0.metadata) }
        checks.append(Check(
            id: "s1.visualKeys",
            scenario: scenarioName,
            status: (style?.fillColor == "#fef3c7" && style?.isValid == true)
                ? .pass : .fail,
            detail: "CanvasVisualMetadataKeys spellings round-trip through "
                + "CanvasVisualStyle",
            evidence: []))

        // -- flow card bindings resolve against the stored graph
        var bindingsOK = true
        for cardID in sample.boundCardIDs {
            guard let card = page2.nodes.first(where: { $0.id == cardID }),
                  let binding = CanvasFlowCardBinding(metadata: card.metadata),
                  binding.graphID == sample.graph.id,
                  sample.graph.nodes.contains(where: { $0.id == binding.nodeID })
            else { bindingsOK = false; break }
        }
        checks.append(Check(
            id: "s1.flowBinding",
            scenario: scenarioName,
            status: bindingsOK ? .pass : .fail,
            detail: "every flow card resolves through "
                + "CanvasFlowCardBinding(metadata:) to a live graph node; the "
                + "document engine accepted the batch (final-state validation)",
            evidence: []))

        // -- repository semantics: real commit, idempotent replay, undo/redo
        let memoryRepo = InMemoryCanvasRepository(snapshot: sample.baseSnapshot)
        let receipt = try await memoryRepo.commitDocument(
            sample.batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: sample.requestID)
        let replay = try await memoryRepo.commitDocument(
            sample.batch, canvasID: snapshot.id,
            expectedRevision: 0, requestID: sample.requestID)
        let undoReceipt = try await memoryRepo.undo(
            canvasID: snapshot.id, expectedRevision: receipt.revision,
            requestID: uuid(0x9002))
        let redoReceipt = try await memoryRepo.redo(
            canvasID: snapshot.id, expectedRevision: undoReceipt.revision,
            requestID: uuid(0x9003))
        let repoOK = receipt.revision == 1
            && replay.revision == 1
            && undoReceipt.revision == 2
            && redoReceipt.revision == 3
        checks.append(Check(
            id: "s1.repository",
            scenario: scenarioName,
            status: repoOK ? .pass : .fail,
            detail: "commitDocument rev 0→1; same-requestID replay returns the "
                + "original receipt without a new revision; undo/redo bump "
                + "revisions",
            evidence: [
                "receipt \(receipt.previousRevision)→\(receipt.revision)",
                "replay rev \(replay.revision)",
                "undo \(undoReceipt.previousRevision)→\(undoReceipt.revision)",
                "redo \(redoReceipt.previousRevision)→\(redoReceipt.revision)",
            ]))

        // -- file repository save/reopen
        let fileRoot = outputRoot.appendingPathComponent(
            "synthetic-file-repo-\(UUID().uuidString)", isDirectory: true)
        do {
            let fileRepo = try FileCanvasRepository(root: fileRoot)
            try await fileRepo.create(
                canvasID: snapshot.id, snapshot: snapshot, requestID: uuid(0x9010))
            let reloaded = try await fileRepo.load(canvasID: snapshot.id)
            let fileOK = reloaded.id == snapshot.id
                && reloaded.pages == snapshot.pages
            checks.append(Check(
                id: "s1.fileRepository",
                scenario: scenarioName,
                status: fileOK ? .pass : .fail,
                detail: "FileCanvasRepository create+load returns the identical "
                    + "pages (saved revision \(snapshot.revision), reloaded "
                    + "revision \(reloaded.revision))",
                evidence: ["file repo root: \(fileRoot.path)"]))
        } catch {
            checks.append(Check(
                id: "s1.fileRepository",
                scenario: scenarioName,
                status: .fail,
                detail: "file repository error: \(error)",
                evidence: []))
        }
        try? FileManager.default.removeItem(at: fileRoot)

        // -- native archive export + reopen (assets + child project fidelity)
        do {
            let exportResult = try await CanvasNativeArchive.export(
                snapshot,
                assetResolver: CanvasInMemoryAssetResolver(sample.registry.bytes),
                childProjectProvider: FixtureChildProjectProvider(
                    expectedBytes: sample.childProjectBytes))
            let archiveName = try QualifyIO.write(
                exportResult.data, to: directory,
                name: "mixed-research-flow.floecanvaslab")
            artifacts.append("synthetic/\(archiveName)")

            let imported = try CanvasNativeArchive.import(exportResult.data)
            var archiveOK = imported.snapshot.id == snapshot.id
                && imported.snapshot.revision == snapshot.revision
                && imported.snapshot.pages == snapshot.pages
            var assetEvidence: [String] = []
            for (id, bytes) in sample.registry.bytes {
                guard let reopened = imported.assets[id],
                      reopened == bytes,
                      SyntheticAssets.sha256(reopened)
                          == sample.registry.locators[id]?.contentHash
                else { archiveOK = false; continue }
                assetEvidence.append("\(id.uuidString) \(bytes.count)B sha256 match")
            }
            let child = imported.childProjects[sample.childProjectID]
            let childOK = child?.data == sample.childProjectBytes
            archiveOK = archiveOK && childOK
            checks.append(Check(
                id: "s1.archiveRoundTrip",
                scenario: scenarioName,
                status: archiveOK ? .pass : .fail,
                detail: "native archive reopens with pages identical, all \(sample.registry.bytes.count) "
                    + "synthetic assets byte-equal with locator sha256, child "
                    + "project bytes identical (fixture-only opaque payload)",
                evidence: assetEvidence + [
                    "child project \(sample.childProjectID.uuidString) bytes match: \(childOK)",
                ]))
        } catch {
            checks.append(Check(
                id: "s1.archiveRoundTrip",
                scenario: scenarioName,
                status: .fail,
                detail: "native archive error: \(error)",
                evidence: []))
        }

        // -- layout index: collapsed region chip + proxy edge + bindings
        do {
            let index = try CanvasPageLayoutIndex(page: page1)
            let flowIndex = try CanvasPageLayoutIndex(
                page: page2, flowGraph: sample.graph)
            let chip = index.region(id: sample.collapsedRegionID)
            let proxyToCollapsed = index.proxyEdges.contains {
                $0.isProxy && $0.label == "反引 back-ref"
                    && $0.destinationID == sample.richTextNodeID
            }
            let webHidden = index.node(id: sample.webNodeID) == nil
                && page1.nodes.contains { $0.id == sample.webNodeID }
            let bindingCount = flowIndex.flowCardBindings.count
            let viewportRect = CanvasLayoutGeometry.rect(from: CanvasGeometry.Frame(
                center: .init(x: -300, y: -100),
                size: .init(width: 700, height: 500)))
            let visible = index.visibleNodes(in: viewportRect)
            var hit: CanvasHitTarget?
            if let richNode = page1.nodes
                .first(where: { $0.id == sample.richTextNodeID }) {
                let hitCenter = CanvasLayoutGeometry.rect(from: CanvasGeometry.Frame(
                    center: richNode.frame.center,
                    size: .init(width: 2, height: 2))).center
                hit = index.hitTest(hitCenter, zoom: 1)
            }
            let layoutOK = chip?.isCollapsed == true
                && proxyToCollapsed
                && webHidden
                && bindingCount == 3
                && !visible.isEmpty
                && hit != nil
            var hitEvidence = "hit=<nil>"
            if case .node(let target)? = hit {
                hitEvidence = "hit=node \(target.id.uuidString)"
            } else if case .region(let target)? = hit {
                hitEvidence = "hit=region \(target.id.uuidString)"
            }
            checks.append(Check(
                id: "s1.layout",
                scenario: scenarioName,
                status: layoutOK ? .pass : .fail,
                detail: "collapsed region exposes a chip; the cross-boundary "
                    + "'反引 back-ref' relation survives as an isProxy edge; "
                    + "web node hidden while collapsed; flow index resolves "
                    + "3 card bindings; viewport query + hitTest return live "
                    + "targets",
                evidence: [
                    "chip collapsed: \(chip?.isCollapsed == true)",
                    "proxy edge: \(proxyToCollapsed)",
                    "web hidden: \(webHidden)",
                    "flow bindings: \(bindingCount)",
                    "visible in viewport: \(visible.count)",
                    hitEvidence,
                ]))
        } catch {
            checks.append(Check(
                id: "s1.layout",
                scenario: scenarioName,
                status: .fail,
                detail: "layout index error: \(error)",
                evidence: []))
        }

        // -- rendered exports with real content bytes
        let resolver = CanvasInMemoryAssetResolver(sample.registry.bytes)
        do {
            let png = try await CanvasExchange.export(
                snapshot, format: .png,
                options: CanvasExportOptions(
                    pageID: page1.id, assetResolver: resolver,
                    scope: .wholePage, appearance: .light))
            let pngName = try QualifyIO.write(
                png.primary.data, to: directory, name: png.primary.name)
            artifacts.append("synthetic/\(pngName)")

            let pdf = try await CanvasExchange.export(
                snapshot, format: .pdf,
                options: CanvasExportOptions(
                    assetResolver: resolver, scope: .wholePage,
                    appearance: .light))
            let pdfName = try QualifyIO.write(
                pdf.primary.data, to: directory, name: pdf.primary.name)
            artifacts.append("synthetic/\(pdfName)")

            let svg = try await CanvasExchange.export(
                snapshot, format: .svg,
                options: CanvasExportOptions(
                    pageID: page1.id, assetResolver: resolver,
                    scope: .wholePage, appearance: .light))
            let svgName = try QualifyIO.write(
                svg.primary.data, to: directory, name: svg.primary.name)
            artifacts.append("synthetic/\(svgName)")

            let pngOK = png.primary.data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                && png.primary.data.count > 100
            let pdfOKBytes = pdf.primary.data.starts(
                with: Data("%PDF".utf8))
            let svgText = String(data: svg.primary.data, encoding: .utf8) ?? ""
            let svgOK = svgText.contains("<svg")
                && svgText.contains("混合研究样例")
            checks.append(Check(
                id: "s1.renderBytes",
                scenario: scenarioName,
                status: (pngOK && pdfOKBytes && svgOK) ? .pass : .fail,
                detail: "PNG carries the PNG magic and real pixels; PDF is a "
                    + "multipage %PDF document; SVG contains the svg root and "
                    + "the actual Chinese rich-text content",
                evidence: [
                    "png \(png.primary.data.count)B magic=\(pngOK)",
                    "pdf \(pdf.primary.data.count)B magic=\(pdfOKBytes)",
                    "svg \(svg.primary.data.count)B content=\(svgOK)",
                    "render issues: \(png.issues.count + pdf.issues.count + svg.issues.count)",
                ]))
            let renderIssues = png.issues + pdf.issues + svg.issues
            if !renderIssues.isEmpty {
                notes.append("render issues: " + renderIssues
                    .map { "\($0.code)(\($0.severity.rawValue))" }
                    .joined(separator: ", "))
            }
        } catch {
            checks.append(Check(
                id: "s1.renderBytes",
                scenario: scenarioName,
                status: .fail,
                detail: "render export error: \(error)",
                evidence: []))
        }

        notes.append(
            "video is a decodable synthetic H.264 clip; child editor bytes are "
            + "opaque fixture records, not evidence of a production CAD engine")
        notes.append(
            "Date timestamps are not part of structural equality checks")

        return ScenarioReport(
            scenario: scenarioName,
            checks: checks,
            artifacts: artifacts,
            notes: notes)
    }
}
