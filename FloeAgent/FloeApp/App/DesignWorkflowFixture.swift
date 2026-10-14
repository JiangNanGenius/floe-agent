// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import FloeCore
import FloeDocuments
import FloeModels
import FloePersistence

/// Debug-only design-workflow fixture for GUI acceptance of the
/// preview-first design conversation page and the original-write freeze.
///
/// Seeds FOUR named, idempotent conversations through the REAL stores and
/// typed services — no fake views, no second runtime:
///
/// 1. "设计验收-网页修改" — a bound modify task over a workspace HTML file:
///    the original is frozen at launch semantics (registry protection), the
///    owner envelope carries a base revision AND a pending candidate, so the
///    current/candidate lens, compare/adopt/reject/variant and the web
///    preview are all exercisable without any provider call.
/// 2. "设计验收-创意成果" — a creative request with its FIRST RESULT BOUND
///    (real adopted revision) plus one pending candidate.
/// 3. "设计验收-整站重构" — a restructure-bound webroot (two files) with the
/// whole-tree freeze active and a confirmed preservation operation.
/// 4. "设计验收-办公文档" — an Office readonly-preview fixture with a real
///    DOCX, a pending candidate and a whole-tree freeze.
///
/// Gated on `-ui-testing` plus an explicit launch argument; idempotent per
/// install (existing fixture conversations are left untouched). Conflict
/// acceptance (manual edit vs pending candidate) is intentionally NOT
/// pre-seeded: edit `site/index.html` in the Files UI to produce it, then
/// try adopting — the frozen-SHA gate must fail closed.
@MainActor
enum DesignWorkflowFixture {
    static let launchArgument = "--ui-test-design-workflow-fixture"

    // Named fixture identities (stable for UI tests and CUA handoff).
    static let modifyConversationID = UUID(uuidString: "D3516001-7A21-4F03-9C5A-71D8E0B4F101")!
    static let creativeConversationID = UUID(uuidString: "D3516001-7A21-4F03-9C5A-71D8E0B4F102")!
    static let restructureConversationID = UUID(uuidString: "D3516001-7A21-4F03-9C5A-71D8E0B4F103")!
    static let officeConversationID = UUID(uuidString: "D3516001-7A21-4F03-9C5A-71D8E0B4F104")!

    static func seedIfRequested(environment: AppEnvironment) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        await seedModifyFixture(environment: environment)
        await seedCreativeFixture(environment: environment)
        await seedRestructureFixture(environment: environment)
        await seedOfficeFixture(environment: environment)
    }


    /// Bookkeeping for tests: the project workspace each fixture
    /// conversation is linked to (the binding ownerID).
    static var fixtureWorkspaceIDs: [UUID: UUID] = [:]

    /// Creates a REAL project workspace (durable bookmark, like the
    /// production file-design entry) and links the conversation to it.
    /// Private-task workspaces carry empty bookmarks and can never satisfy
    /// the file owner port — the fixtures must mirror the real route.
    private static func makeProjectWorkspace(
        environment: AppEnvironment,
        conversationID: UUID,
        title: String
    ) async throws -> WorkspaceRecord {
        let store = SQLiteWorkspaceStore(database: environment.database)
        // Persistent app-owned storage: the simulator wipes tmp between
        // launches, which would stale the workspace bookmark exactly like a
        // deleted real folder. Real project workspaces live in durable
        // locations; the fixtures must too.
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let root = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("DesignFixtures", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = try root.bookmarkData(options: .minimalBookmark)
        let record = WorkspaceRecord(
            name: title,
            rootBookmark: bookmark,
            kind: .project,
            createdAt: Date(),
            updatedAt: Date())
        try await store.saveWorkspace(record)
        // NOTE: the conversation keeps its OWN private-task workspace link
        // (ensureWorkspace) so the sidebar lists it in the always-visible
        // chat section; the design target addresses THIS project workspace
        // directly. The file owner port only needs the target's workspace.
        fixtureWorkspaceIDs[conversationID] = record.id
        return record
    }

    // MARK: - 1. Bound modify task: frozen original + pending candidate

    static func seedModifyFixture(environment: AppEnvironment) async {
        let conversationID = modifyConversationID
        let store = SQLiteConversationStore(database: environment.database)
        // Self-healing idempotency: skip only a COMPLETE seed (conversation,
        // durable launch binding AND durable owner envelope). An aborted
        // earlier seed (e.g. binding without envelope from an older build)
        // is finished — deterministic operationIDs make the design steps
        // idempotent replays, never duplicates.
        let binding = DesignLaunchBindingStore.load(conversationID: conversationID)
        let envelope: DesignOwnerEnvelope?
        if let binding {
            envelope = try? await environment.designOwnerWorkflow.state(binding.target)
        } else {
            envelope = nil
        }
        let hasPending = (envelope?.project.candidates ?? [])
            .contains { $0.status == .pending } == true
        // Complete = conversation + binding + envelope WITH a pending
        // candidate (acceptance runs consume candidates; a resolved fixture
        // re-seeds a fresh pending one deterministically).
        guard (try? await store.conversation(id: conversationID)) == nil
                || binding == nil
                || envelope == nil
                || !hasPending else { return }
        do {
            try await saveConversation(
                store, id: conversationID, title: "设计验收-网页修改",
                userText: "把首屏标题改得更有冲击力，但保留正文。",
                assistantText: "已读取原文件并暂存了一个候选：仅标题变化，正文保持不变。")
            _ = try await SQLiteWorkspaceStore(database: environment.database)
                .ensureWorkspace(conversationID: conversationID, title: "设计验收-网页修改")
            let record = try await makeProjectWorkspace(
                environment: environment, conversationID: conversationID,
                title: "设计验收-网页修改")
            let lease = try await environment.workspaceCenter.acquireTaskRoot(record, conversationID: conversationID)
            defer { lease.release() }
            // Minimal web form + scroll content: gives the GUI acceptance an
            // HONEST state-retention proof (form values, scroll position and
            // web content survive fullscreen/split transitions of the SAME
            // live session). No private data — synthetic fixture text only.
            let originalV1 = """
            <!doctype html><html><head><meta charset="utf-8"><title>验收页</title></head>
            <body><h1>原始标题</h1><p>用于设计工作流 GUI 验收的原始页面。</p>
            <form action="#" method="get"><label>姓名 <input type="text" name="name"></label>
            <label>意向 <select name="choice"><option>参加</option><option>围观</option></select></label>
            <button type="submit">提交</button></form>
            <p>滚动区 01</p><p>滚动区 02</p><p>滚动区 03</p><p>滚动区 04</p>
            <p>滚动区 05</p><p>滚动区 06</p><p>滚动区 07</p><p>滚动区 08</p>
            <p>滚动区终点</p></body></html>
            """
            let originalV2 = """
            <!doctype html><html><head><meta charset="utf-8"><title>验收页</title></head>
            <body><h1>更有冲击力的标题</h1><p>用于设计工作流 GUI 验收的原始页面。</p></body></html>
            """
            let file = lease.url.appendingPathComponent("site/index.html")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                try originalV1.write(to: file, atomically: true, encoding: .utf8)
            }

            let target = DesignOwnerTargets.file(
                workspaceID: record.id, relativePath: "site/index.html")
                .rebindingOrigin(conversationID: conversationID)
            let binding = DesignLaunchBinding(
                target: target, workMode: .modify,
                originalConversationID: conversationID.uuidString)
            try DesignLaunchBindingStore.save(binding, conversationID: conversationID)

            // Launch-semantics freeze: the original is protected BEFORE any
            // run could touch it (the same call startTask makes).
            let protected = await DesignFreezeProtectionCoordinator.establish(
                binding: binding, conversationID: conversationID,
                workspaceStore: SQLiteWorkspaceStore(database: environment.database))
            guard protected else { return }

            // Real typed-service history: frozen input → pending candidate.
            let workflow = environment.designOwnerWorkflow
            let frozen = try await workflow.freezeInput(
                target: target,
                operationID: "fixture-freeze",
                expectedOwnerRevision: nil,
                displayName: "index.html")
            // Self-heal after acceptance runs consumed the candidate: a
            // state-derived operation id keeps re-proposals deterministic
            // (each resolution cohort gets exactly one new pending
            // candidate; replays never duplicate).
            let existingPending = frozen.envelope.project.candidates
                .contains { $0.status == .pending }
            if !existingPending {
                // Base the heal on the CURRENT revision (an earlier
                // acceptance run may have adopted a candidate) and add a
                // distinct marker so the candidate always differs from it.
                let baseID = frozen.envelope.project.artifacts.first?
                    .currentRevisionID ?? frozen.revision.id
                let currentBytes = (try? await workflow.revisionPreviewBytes(
                    target: target, artifactID: frozen.revision.artifactID,
                    revisionID: baseID)) ?? Data(originalV1.utf8)
                let cohort = frozen.envelope.project.candidates.count
                _ = try await workflow.propose(
                    target: target,
                    operationID: "fixture-propose-r\(cohort)",
                    expectedOwnerRevision: frozen.envelope.revision,
                    artifactID: frozen.revision.artifactID,
                    baseRevisionID: baseID,
                    bytes: currentBytes + Data("\n<!-- 验收候选 -->\n".utf8),
                    format: "html",
                    summary: "候选：仅标记一处验收注释，正文不动。")
            }
        } catch {
            FloeLogger(category: .app).error("designFixture modify seed failed: \(error)")
        }
    }

    // MARK: - 2. Creative request: first result bound + pending candidate

    static func seedCreativeFixture(environment: AppEnvironment) async {
        let conversationID = creativeConversationID
        let store = SQLiteConversationStore(database: environment.database)
        // Self-healing idempotency: skip only a COMPLETE seed (conversation,
        // durable launch binding AND durable owner envelope); deterministic
        // operationIDs make design steps idempotent replays, never dupes.
        let binding = DesignLaunchBindingStore.load(conversationID: conversationID)
        let envelope: DesignOwnerEnvelope?
        if let binding {
            envelope = try? await environment.designOwnerWorkflow.state(binding.target)
        } else {
            envelope = nil
        }
        let hasPending = (envelope?.project.candidates ?? [])
            .contains { $0.status == .pending } == true
        // Complete = conversation + binding + envelope WITH a pending
        // candidate (acceptance runs consume candidates; a resolved fixture
        // re-seeds a fresh pending one deterministically).
        guard (try? await store.conversation(id: conversationID)) == nil
                || binding == nil
                || envelope == nil
                || !hasPending else { return }
        do {
            try await saveConversation(
                store, id: conversationID, title: "设计验收-创意成果",
                userText: "做一页简洁的活动海报文案。",
                assistantText: "首版已绑定；另有一个候选等待你的决定。")
            // Sidebar ownership through the REAL workspace store (same call
            // the other fixtures make): without the
            // conversation_workspace_ownership row the creative fixture is
            // not listed in the always-visible chat section.
            _ = try await SQLiteWorkspaceStore(database: environment.database)
                .ensureWorkspace(conversationID: conversationID, title: "设计验收-创意成果")

            let requestID = UUID(uuidString: "D3516001-7A21-4F03-9C5A-71D8E0B4F201")!
            let target = DesignOwnerTargets.creative(requestID: requestID, kind: .webpage)
                .rebindingOrigin(conversationID: conversationID)
            let binding = DesignLaunchBinding(
                target: target, workMode: .create,
                originalConversationID: conversationID.uuidString)
            try DesignLaunchBindingStore.save(binding, conversationID: conversationID)
            DesignCreativeRequestStore.remember(target)

            // A REAL creative-library asset backs the first result: the
            // bind path verifies the recorded asset id against the actual
            // store rows (never a synthetic id).
            let v1URL = FileManager.default.temporaryDirectory
                .appendingPathComponent("fixture-poster-\(conversationID.uuidString).html")
            let v1 = """
            <!doctype html><html><head><meta charset="utf-8"><title>活动海报</title></head>
            <body><h1>夏日创作市集</h1><p>时间：周六 10:00 · 地点：滨江广场</p></body></html>
            """
            try v1.write(to: v1URL, atomically: true, encoding: .utf8)
            let asset = try await CreativeAssetIngestionService(
                assetStore: environment.creativeAssetStore).importLocalFile(v1URL)
            try? FileManager.default.removeItem(at: v1URL)

            let workflow = environment.designOwnerWorkflow
            let begun = try await workflow.beginCreativeRequest(
                target: target,
                operationID: "fixture-begin",
                expectedOwnerRevision: nil,
                brief: DesignBrief(
                    goal: "做一页简洁的活动海报文案",
                    audience: nil, constraints: []))
            let v2 = v1.replacingOccurrences(of: "夏日创作市集", with: "夏日创作市集 · 早鸟开放")
            let bound = try await workflow.bindFirstResult(
                target: target,
                operationID: "fixture-bind",
                expectedOwnerRevision: begun.envelope.revision,
                bytes: Data(v1.utf8),
                format: "html",
                displayName: asset.displayName,
                boundResultID: asset.id.uuidString)
            _ = try await workflow.propose(
                target: target,
                operationID: "fixture-propose",
                expectedOwnerRevision: bound.envelope.revision,
                artifactID: bound.revision.artifactID,
                baseRevisionID: bound.revision.id,
                bytes: Data(v2.utf8),
                format: "html",
                summary: "候选：主标题追加“早鸟开放”。")
        } catch {
            FloeLogger(category: .app).error("designFixture creative seed failed: \(error)")
        }
    }

    // MARK: - 3. Restructure-bound webroot: whole-tree freeze

    static func seedRestructureFixture(environment: AppEnvironment) async {
        let conversationID = restructureConversationID
        let store = SQLiteConversationStore(database: environment.database)
        // Self-healing idempotency: skip only a COMPLETE seed (conversation,
        // durable launch binding AND durable owner envelope); deterministic
        // operationIDs make design steps idempotent replays, never dupes.
        // This seed intentionally has no owner envelope (confirmed
        // restructure authority only): complete = conversation + binding.
        guard (try? await store.conversation(id: conversationID)) == nil
                || DesignLaunchBindingStore.load(conversationID: conversationID) == nil else { return }
        do {
            try await saveConversation(
                store, id: conversationID, title: "设计验收-整站重构",
                userText: "重构这个页面：重排结构，但必须保留品牌标语和导航链接。",
                assistantText: "已确认保留要求：品牌标语、导航链接、HTML 格式。")
            _ = try await SQLiteWorkspaceStore(database: environment.database)
                .ensureWorkspace(conversationID: conversationID, title: "设计验收-整站重构")
            let record = try await makeProjectWorkspace(
                environment: environment, conversationID: conversationID,
                title: "设计验收-整站重构")
            let lease = try await environment.workspaceCenter.acquireTaskRoot(record, conversationID: conversationID)
            defer { lease.release() }
            let site = lease.url.appendingPathComponent("site", isDirectory: true)
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            let siteIndex = site.appendingPathComponent("index.html")
            if !FileManager.default.fileExists(atPath: siteIndex.path) {
                try """
                <!doctype html><html><head><meta charset="utf-8"><title>品牌站</title>
                <link rel="stylesheet" href="style.css"></head>
                <body><h1 class="brand">品牌标语</h1><nav><a href="index.html">首页</a></nav></body></html>
                """.write(to: siteIndex, atomically: true, encoding: .utf8)
            }
            let siteStyle = site.appendingPathComponent("style.css")
            if !FileManager.default.fileExists(atPath: siteStyle.path) {
                try ".brand { color: #123; } nav { margin: 8px 0; }"
                    .write(to: siteStyle, atomically: true, encoding: .utf8)
            }

            let operationID = "fixture-restructure-\(conversationID.uuidString)"
            let constraints = DesignPreservationConstraints(
                content: ["品牌标语"], data: [], behavior: ["导航链接"], formatBounds: ["html"])
            let target = DesignOwnerTargets.file(
                workspaceID: record.id, relativePath: "site")
                .rebindingOrigin(conversationID: conversationID)
            let binding = DesignLaunchBinding(
                target: target, workMode: .restructure,
                preservation: constraints,
                originalConversationID: conversationID.uuidString,
                frozenRestructureOperationID: operationID)
            try DesignLaunchBindingStore.save(binding, conversationID: conversationID)
            // Directory original: the whole webroot tree is frozen.
            _ = await DesignFreezeProtectionCoordinator.establish(
                binding: binding, conversationID: conversationID,
                workspaceStore: SQLiteWorkspaceStore(database: environment.database))
            // The confirmed restructure authority the propose path will
            // require (mirrors the trusted panel confirmation).
            await DesignRestructureAuthorization.shared.issueRestructureConfirmation(
                targetKey: target.stableKey,
                operationID: operationID,
                baseRevisionID: "",
                preservationDigest: constraints.canonicalDigest,
                originalTaskOwnerID: conversationID.uuidString)
        } catch {
            FloeLogger(category: .app).error("designFixture restructure seed failed: \(error)")
        }
    }

    // MARK: - 4. Bound office-document task: readonly preview + editor handoff

    static func seedOfficeFixture(environment: AppEnvironment) async {
        let conversationID = officeConversationID
        let store = SQLiteConversationStore(database: environment.database)
        // Self-healing idempotency: skip only a COMPLETE seed (conversation,
        // durable launch binding AND durable owner envelope); deterministic
        // operationIDs make design steps idempotent replays, never dupes.
        let binding = DesignLaunchBindingStore.load(conversationID: conversationID)
        let envelope: DesignOwnerEnvelope?
        if let binding {
            envelope = try? await environment.designOwnerWorkflow.state(binding.target)
        } else {
            envelope = nil
        }
        let hasPending = (envelope?.project.candidates ?? [])
            .contains { $0.status == .pending } == true
        // Complete = conversation + binding + envelope WITH a pending
        // candidate (acceptance runs consume candidates; a resolved fixture
        // re-seeds a fresh pending one deterministically).
        guard (try? await store.conversation(id: conversationID)) == nil
                || binding == nil
                || envelope == nil
                || !hasPending else { return }
        do {
            try await saveConversation(
                store, id: conversationID, title: "设计验收-演示文稿",
                userText: "把第二段改得简洁一些。",
                assistantText: "已暂存候选：仅第二段变化，其余保留。")
            _ = try await SQLiteWorkspaceStore(database: environment.database)
                .ensureWorkspace(conversationID: conversationID, title: "设计验收-演示文稿")
            let record = try await makeProjectWorkspace(
                environment: environment, conversationID: conversationID,
                title: "设计验收-演示文稿")
            let lease = try await environment.workspaceCenter.acquireTaskRoot(record, conversationID: conversationID)
            defer { lease.release() }
            // A REAL .docx through the same OOXML builder. Written only on
            // the first seed: a re-seed (candidate healed after acceptance)
            // must never clobber adopted bytes.
            let file = lease.url.appendingPathComponent("文稿.docx")
            if !FileManager.default.fileExists(atPath: file.path) {
                try OfficeDocumentBuilder.createWord(at: file, title: "设计验收文稿", paragraphs: [
                    "第一段：用于设计工作流 GUI 验收的真实 DOCX。",
                    "第二段：候选只改这一段。",
                ])
            }

            let target = DesignOwnerTargets.file(
                workspaceID: record.id, relativePath: "文稿.docx")
                .rebindingOrigin(conversationID: conversationID)
            let binding = DesignLaunchBinding(
                target: target, workMode: .modify,
                originalConversationID: conversationID.uuidString)
            try DesignLaunchBindingStore.save(binding, conversationID: conversationID)
            let protected = await DesignFreezeProtectionCoordinator.establish(
                binding: binding, conversationID: conversationID,
                workspaceStore: SQLiteWorkspaceStore(database: environment.database))
            guard protected else { return }

            // Candidate: the same document regenerated with an edited
            // second paragraph (the SAME OOXML builder — real bytes, not a
            // textual zip patch).
            let workflow = environment.designOwnerWorkflow
            let frozen = try await workflow.freezeInput(
                target: target,
                operationID: "office-freeze",
                expectedOwnerRevision: nil,
                displayName: "文稿.docx")
            let candidateURL = lease.url.appendingPathComponent(".fixture-candidate.docx")
            try OfficeDocumentBuilder.createWord(at: candidateURL, title: "设计验收文稿", paragraphs: [
                "第一段：用于设计工作流 GUI 验收的真实 DOCX。",
                "第二段：更简洁。",
            ])
            let candidateBytes = try Data(contentsOf: candidateURL)
            try? FileManager.default.removeItem(at: candidateURL)
            // Heal after acceptance runs consumed the candidate (mirrors the
            // modify fixture: a state-derived operation id, base first).
            let existingPending = frozen.envelope.project.candidates
                .contains { $0.status == .pending }
            if !existingPending {
                let baseID = frozen.envelope.project.artifacts.first?
                    .currentRevisionID ?? frozen.revision.id
                let cohort = frozen.envelope.project.candidates.count
                _ = try await workflow.propose(
                    target: target,
                    operationID: "office-propose-r\(cohort)",
                    expectedOwnerRevision: frozen.envelope.revision,
                    artifactID: frozen.revision.artifactID,
                    baseRevisionID: baseID,
                    bytes: candidateBytes,
                    format: "docx",
                    summary: "候选：第二段更简洁，其余保留。")
            } else {
                _ = try await workflow.propose(
                    target: target,
                    operationID: "office-propose",
                    expectedOwnerRevision: frozen.envelope.revision,
                    artifactID: frozen.revision.artifactID,
                    baseRevisionID: frozen.revision.id,
                    bytes: candidateBytes,
                    format: "docx",
                    summary: "候选：第二段更简洁，其余保留。")
            }
        } catch {
            FloeLogger(category: .app).error("designFixture office seed failed: \(error)")
        }
    }

    // MARK: - Shared helpers

    private static func saveConversation(
        _ store: SQLiteConversationStore,
        id: UUID,
        title: String,
        userText: String,
        assistantText: String
    ) async throws {
        try await store.saveConversation(ConversationRecord(
            id: id, title: title, createdAt: Date(), updatedAt: Date()))
        // Reseed after an aborted seed must not duplicate the transcript.
        guard (try? await store.messages(conversationID: id))?.isEmpty != false else { return }
        try await store.appendMessage(PersistedMessage(
            id: UUID(), conversationID: id, role: "user", content: userText,
            createdAt: Date().addingTimeInterval(-120)))
        try await store.appendMessage(PersistedMessage(
            id: UUID(), conversationID: id, role: "assistant", content: assistantText,
            createdAt: Date().addingTimeInterval(-60)))
    }
}

extension DesignTarget {
    /// Fixture/launch convenience: the rebound origin identity a bound task
    /// carries (same rebound shape ConversationCenter.startTask writes).
    fileprivate func rebindingOrigin(conversationID: UUID) -> DesignTarget {
        DesignTarget(
            kind: kind,
            ownerID: ownerID,
            documentID: documentID,
            sourceID: sourceID,
            environmentID: environmentID,
            revision: revision,
            originConversationID: conversationID.uuidString,
            requestedOutputKind: requestedOutputKind)
    }
}
#endif
