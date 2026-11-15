// FloeApp — compiled browser tools routed to the calling task's own session.

#if canImport(SwiftUI) && canImport(WebKit)
import Foundation
import CryptoKit
import WebKit
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace
import FloeExecution

private final class BrowserToolEnvironment: @unchecked Sendable {
    weak var center: BrowserSessionCenter?

    @MainActor private var designOwners: [UUID: BrowserDesignCaptureOwner] = [:]
    @MainActor private var busyDesignTasks: Set<UUID> = []

    @MainActor
    private struct BrowserDesignCaptureOwner {
        weak var session: BrowserTaskSession?
        let runID: UUID
        let root: URL
        let environmentID: String
        let tabID: UUID
    }

    init(center: BrowserSessionCenter) {
        self.center = center
    }

    /// Task ownership comes only from the runtime-issued ToolContext. A nil
    /// owner is rejected instead of falling back to whatever browser happens
    /// to be visible, and the temporary chat ceiling stays unchanged.
    @MainActor
    func owner(for context: ToolContext) throws -> UUID {
        guard let owner = context.conversationID else {
            throw FloeError.validationFailed(
                "Browser tools require a task-owned run. Open a task and use its browser."
            )
        }
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Temporary chat cannot open or control a durable browser session"
            )
        }
        return owner
    }

    /// One acquired model holding period plus the exact task session it
    /// covers. Every page read/action entry resolves this before touching the
    /// page; the lease is what later calls and `browser.release` present.
    @MainActor
    struct Control {
        let owner: UUID
        let session: BrowserTaskSession
        let lease: BrowserControlLease
        let acquiredNow: Bool
    }

    /// Atomic acquisition before the first page read/create. The logical run
    /// is runtime-issued: a delegated child acts for its original parent run,
    /// and a mismatched/nested identity is refused by `handoffRun`.
    @MainActor
    func control(for context: ToolContext) throws -> Control {
        guard let center else {
            throw FloeError.invalidConfiguration("The task browser service is unavailable")
        }
        let owner = try owner(for: context)
        try context.cancellation.throwIfCancelled()
        let runID = try handoffRun(for: context, owner: owner)
        let model = try center.beginModelControl(conversationID: owner, runID: runID)
        return Control(
            owner: owner,
            session: model.session,
            lease: model.lease,
            acquiredNow: model.acquiredNow
        )
    }

    /// The lightweight marker attached to every control-acquiring result. It
    /// is only present while this exact holding period is still live, so a
    /// result produced after takeover/release carries no stale token.
    @MainActor
    func controlMarker(for control: Control) -> [String: String]? {
        guard control.session.isModelControlCurrent(control.lease) else { return nil }
        return ["id": control.lease.id.uuidString, "releaseTool": "browser.release"]
    }

    @MainActor
    func assertCurrent(_ control: Control) throws {
        try control.session.assertModelControlCurrent(control.lease)
    }

    /// Honest needsUser result: no page, screenshot, event, text or control
    /// token. The model can continue other work and must not retry in a loop.
    @MainActor
    func needsUserOutput(_ message: String) -> ToolExecutionOutput {
        let result = BrowserResult(
            requestID: UUID(),
            status: .needsUser,
            message: message,
            error: BrowserFailure(code: "takeover", message: message)
        )
        let data = (try? JSONEncoder().encode(result)) ?? Data()
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            requiresUserAction: true,
            maximumSummaryCharacters: 16_384
        )
    }

    /// Fixed native measurement only. Engine execution remains in the
    /// resolved Linux environment through the existing exec.shell lifecycle.
    @MainActor
    func design(context: ToolContext, action: String, tabID: UUID?, captureID: UUID?, needsFile: String?) async throws -> ToolExecutionOutput {
        let owner = try owner(for: context)
        try context.cancellation.throwIfCancelled()
        guard let center else { throw FloeError.invalidConfiguration("The task browser service is unavailable") }
        if action != "release", let message = center.session(for: owner)?.userControlMessage {
            return needsUserOutput(message)
        }
        // Workspace/parameter authority is decided before the page is held.
        guard let root = context.workspaceRootURL, root.isFileURL,
              let environmentID = context.environmentID, !environmentID.isEmpty else {
            throw FloeError.validationFailed("Design capture requires this task's workspace and execution environment")
        }
        let physicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        try context.authorizeWorkspacePath("Impeccable/" + owner.uuidString)
        // `release` only retires this run's own measurement files: it never
        // reads the page and must stay possible after a takeover. Every other
        // design action reads/measures the real page, so it acquires control
        // atomically first.
        let resolved: (session: BrowserTaskSession, control: Control?)
        if action == "release" {
            guard let existing = center.session(for: owner) else {
                throw FloeError.validationFailed("This task's browser is not open; there is no design capture to release")
            }
            resolved = (existing, nil)
        } else {
            do {
                let acquired = try self.control(for: context)
                resolved = (acquired.session, acquired)
            } catch BrowserControlError.needsUser(let message) {
                return needsUserOutput(message)
            }
        }
        let session = resolved.session
        let control = resolved.control
        guard busyDesignTasks.insert(owner).inserted else {
            throw FloeError.validationFailed("A design measurement is already running for this task")
        }
        defer { busyDesignTasks.remove(owner) }
        designOwners = designOwners.filter { $0.value.session?.isReleased == false }
        switch action {
        case "capture":
            guard let selectedTab = tabID ?? session.activeTabID else { throw FloeError.validationFailed("Open a browser tab before capturing its design") }
            let ticket = try await session.impeccableCaptures.capture(tabID: selectedTab, bridgeRoot: root)
            do { try context.cancellation.throwIfCancelled() }
            catch {
                session.impeccableCaptures.fence(captureID: ticket.captureID, reason: .taskCancelled)
                session.impeccableCaptures.cleanup(captureID: ticket.captureID)
                throw error
            }
            guard ticket.bridgeRootIsTaskWorkspace, ticket.bridgeRoot == physicalRoot else {
                session.impeccableCaptures.cleanup(captureID: ticket.captureID)
                throw FloeError.validationFailed("The design capture belongs to a different workspace")
            }
            if let control { try assertCurrent(control) }
            designOwners[ticket.captureID] = BrowserDesignCaptureOwner(session: session, runID: context.runID,
                root: physicalRoot, environmentID: environmentID, tabID: selectedTab)
            struct CaptureResponse: Encodable {
                let profile = "design"
                let state = "captured"
                let engineRun = false
                let capture: ImpeccableCaptureReceipt
                let control: [String: String]?
            }
            let marker = control.flatMap { controlMarker(for: $0) }
            let bytes = try JSONEncoder().encode(CaptureResponse(capture: ticket.receipt, control: marker))
            return ToolExecutionOutput(summary: String(decoding: bytes, as: UTF8.self), fullOutputSHA256: FloeDigest.sha256Hex(bytes))
        case "facts", "release":
            guard let captureID, let captureOwner = designOwners[captureID],
                  captureOwner.session === session, captureOwner.runID == context.runID,
                  captureOwner.root == physicalRoot, captureOwner.environmentID == environmentID,
                  tabID == nil || tabID == captureOwner.tabID else {
                throw FloeError.validationFailed("The design capture is unavailable for this run or workspace")
            }
            if action == "release" {
                session.impeccableCaptures.cleanup(captureID: captureID)
                let directory = physicalRoot.appendingPathComponent("Impeccable/" + owner.uuidString + "/" + captureID.uuidString)
                guard !FileManager.default.fileExists(atPath: directory.path) else {
                    throw FloeError.storageCorrupted("The design capture files could not be removed")
                }
                designOwners[captureID] = nil
                return ToolExecutionOutput(digesting: "Design capture released")
            }
            guard let needsFile else { throw FloeError.validationFailed("facts requires the engine's Needs file") }
            try context.authorizeWorkspacePath(needsFile)
            let pathGuard = WorkspacePathGuard(rootURL: physicalRoot, maxReadBytes: 1_048_576)
            let input = try pathGuard.resolve(needsFile)
            try pathGuard.assertReadableSize(input)
            let file = try FileHandle(forReadingFrom: input)
            defer { try? file.close() }
            let needs = try file.read(upToCount: 1_048_577) ?? Data()
            guard !needs.isEmpty, needs.count <= 1_048_576 else { throw FloeError.validationFailed("The Needs file is empty or exceeds 1 MiB") }
            try context.cancellation.throwIfCancelled()
            let needsInput: Data
            if let envelope = try JSONSerialization.jsonObject(with: needs) as? [String: Any], envelope["needs"] != nil {
                let assessment = await session.impeccableCaptures.resultAssessment(captureID: captureID, resultJSON: needs)
                guard assessment.exit == .needsFacts, let request = envelope["needs"] as? [String: Any] else {
                    throw FloeError.validationFailed("The engine result does not contain a matching pending measurement request")
                }
                needsInput = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            } else { needsInput = needs }
            let facts = try await session.impeccableCaptures.answerNeeds(captureID: captureID, needsJSON: needsInput)
            try context.cancellation.throwIfCancelled()
            if let control { try assertCurrent(control) }
            let relative = "Impeccable/" + owner.uuidString + "/" + captureID.uuidString + "/" + facts.lastPathComponent
            guard try pathGuard.resolve(relative) == facts.standardizedFileURL else {
                throw FloeError.validationFailed("The measurements belong to a different workspace")
            }
            struct FactsResponse: Encodable {
                let state = "factsReady"
                let captureID: UUID
                let relativeFactsFile: String
                let control: [String: String]?
            }
            let marker = control.flatMap { controlMarker(for: $0) }
            let bytes = try JSONEncoder().encode(FactsResponse(captureID: captureID, relativeFactsFile: relative, control: marker))
            return ToolExecutionOutput(summary: String(decoding: bytes, as: UTF8.self), fullOutputSHA256: FloeDigest.sha256Hex(bytes))
        default:
            throw FloeError.validationFailed("Unknown design action")
        }
    }

    /// Fixed staged-export pull: commits the full-resolution PNG that this
    /// task's OWN preview page staged (the art/canvas packages' Export PNG /
    /// Download PNG controls) as a NEW workspace file. Destination and write
    /// authority come only from the runtime-issued ToolContext (task file
    /// scope + workspace path guard, create-new only); the bound page
    /// contributes validated bytes through the fixed native read-back script,
    /// never authority. This is internal browser/media measurement — engine
    /// execution stays in the resolved Linux environment through exec.shell.
    @MainActor
    func exportStagedFile(
        context: ToolContext,
        tabID: UUID?,
        path: String,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) async throws -> ToolExecutionOutput {
        let owner = try owner(for: context)
        try context.cancellation.throwIfCancelled()
        guard let root = context.workspaceRootURL, root.isFileURL,
              let environmentID = context.environmentID, !environmentID.isEmpty else {
            throw FloeError.validationFailed("Staged file export requires this task's workspace and execution environment")
        }
        let physicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let pathRejections = StagedExportValidation.destinationRejections(path)
        guard pathRejections.isEmpty else {
            throw FloeError.validationFailed(pathRejections.joined(separator: "; "))
        }
        try context.authorizeWorkspacePath(path)
        let pathGuard = WorkspacePathGuard(
            rootURL: physicalRoot,
            maxReadBytes: StagedExportContract.maxFileBytes,
            maxWriteBytes: StagedExportContract.maxFileBytes
        )
        // Create-new only: an existing destination (file, directory or symlink)
        // is refused before any page read. This guard resolution is the policy
        // authority for containment and secrets; the service then re-anchors the
        // same destination by descriptor and publishes with one atomic
        // no-overwrite syscall, which is what actually excludes a late race.
        let destination = try pathGuard.resolve(path, for: .createNew)
        guard destination.path.hasPrefix(physicalRoot.path + "/") else {
            throw FloeError.validationFailed("The export destination belongs to a different workspace")
        }
        let control = try self.control(for: context)
        guard control.owner == owner else {
            throw FloeError.validationFailed("The staged export task changed while validating the destination")
        }
        let session = control.session
        guard let selectedTab = tabID ?? session.activeTabID else {
            throw FloeError.validationFailed("Open the artifact preview in a browser tab before exporting its staged file")
        }
        let receipt = try await session.stagedExports.export(
            BrowserStagedExportService.Request(
                tabID: selectedTab,
                workspaceRootURL: physicalRoot,
                destinationURL: destination,
                relativePath: path,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            ),
            cancellation: context.cancellation
        )
        // A takeover or release during the export must not publish its
        // receipt as a live result even though the service already fenced.
        try assertCurrent(control)
        let receiptBytes = try receipt.encodedJSON()
        var object = try JSONSerialization.jsonObject(with: receiptBytes) as? [String: Any] ?? [:]
        if let marker = controlMarker(for: control) { object["control"] = marker }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ToolExecutionOutput(
            summary: String(decoding: bytes, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(bytes)
        )
    }

    /// Provider data authorization is requested BEFORE control is acquired:
    /// waiting for consent must not hold this task's page. The subsequent
    /// acquisition still rechecks user control and cancellation.
    @MainActor
    func requireBrowserDataAccess(context: ToolContext) async throws -> BrowserDataAuthorization {
        try await BrowserProviderTrustCoordinator.shared.requireBrowserDataAuthorization(
            runID: context.runID,
            conversationID: context.conversationID
        )
    }

    @MainActor
    func revalidateBrowserDataAccess(
        _ authorization: BrowserDataAuthorization,
        context: ToolContext
    ) throws {
        try BrowserProviderTrustCoordinator.shared.revalidateBrowserDataAuthorization(
            runID: context.runID,
            expectedProviderID: authorization.provider.id,
            advancedGeneration: authorization.advancedGeneration
        )
    }

    @MainActor
    func download(
        context: ToolContext,
        tabID: UUID?,
        urlString: String,
        path: String,
        maxBytes: Int?,
        overwrite: Bool?
    ) async throws -> ToolExecutionOutput {
        let owner = try owner(for: context)
        try context.cancellation.throwIfCancelled()
        let url = try BrowserURLPolicy.validate(urlString, conversationID: owner, allowLocalNetwork: true)
        guard let root = context.workspaceRootURL, root.isFileURL else {
            throw FloeError.validationFailed("Browser download requires this task's workspace")
        }
        let physicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        try context.authorizeWorkspacePath(path)
        let cap = max(1, min(maxBytes ?? 32 * 1_024 * 1_024, 64 * 1_024 * 1_024))
        let pathGuard = WorkspacePathGuard(
            rootURL: physicalRoot,
            maxReadBytes: cap,
            maxWriteBytes: cap
        )
        let destination = try pathGuard.resolve(
            path,
            for: overwrite == true ? .replace(consent: true) : .createNew
        )
        guard destination.path.hasPrefix(physicalRoot.path + "/") else {
            throw FloeError.validationFailed("The download destination belongs to a different workspace")
        }
        // Consent is awaited before the page is held; a takeover during the
        // wait therefore never has to wait for this run's lease.
        let authorization = try await BrowserProviderTrustCoordinator.shared.requireBrowserDataAuthorization(
            runID: context.runID,
            conversationID: context.conversationID
        )
        let control = try self.control(for: context)
        guard control.owner == owner else {
            throw FloeError.validationFailed("The browser download task changed while waiting for authorization")
        }
        let session = control.session
        let receipt = try await session.startDownload(
            tabID: tabID,
            url: url,
            destinationURL: destination,
            relativePath: path,
            maxBytes: cap,
            overwrite: overwrite == true,
            cancellation: context.cancellation
        )
        try BrowserProviderTrustCoordinator.shared.revalidateBrowserDataAuthorization(
            runID: context.runID,
            expectedProviderID: authorization.provider.id,
            advancedGeneration: authorization.advancedGeneration
        )
        try context.cancellation.throwIfCancelled()
        try assertCurrent(control)
        let outputFiles = try Self.publishDownload(receipt, using: context)
        var payload: [String: Any] = [
            "status": "ok",
            "path": receipt.relativePath,
            "mimeType": receipt.mimeType,
            "byteCount": receipt.byteCount,
            "sha256": receipt.sha256,
            "filename": receipt.suggestedFilename,
            "sourceHost": receipt.finalHost ?? ""
        ]
        if let marker = controlMarker(for: control) { payload["control"] = marker }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            artifacts: [],
            outputFiles: outputFiles,
            maximumSummaryCharacters: 16_384
        )
    }

    private static func publishDownload(
        _ receipt: BrowserDownloadReceipt,
        using context: ToolContext
    ) throws -> [RunOutputFile] {
        guard !context.temporaryReadOnly,
              let callID = context.toolCallID, !callID.isEmpty,
              context.conversationID != nil else {
            return []
        }
        do {
            let output = try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "browser.download",
                    slot: "download",
                    commit: RunOutputCommit(
                        sourceURL: receipt.destinationURL,
                        sha256: receipt.sha256,
                        byteCount: receipt.byteCount,
                        displayName: receipt.destinationURL.lastPathComponent,
                        mimeType: normalizedContentType(receipt.mimeType)
                    )
                ),
                using: context
            )
            return [output]
        } catch let error as RunOutputSnapshotError {
            throw FloeError.validationFailed("browser download output publication failed: \(error.localizedDescription)")
        }
    }

    private static func normalizedContentType(_ raw: String) -> String {
        let base = raw.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !base.isEmpty, base.utf8.count <= 128, base.contains("/"),
              !base.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return "application/octet-stream"
        }
        return base
    }

    /// Resolves the exact run that owns a durable browser handoff for this
    /// call. Main-run calls use their actual `context.runID`. A delegated
    /// child uses the runtime-issued `ChildExecutionIdentity`: the original
    /// parent run that delegated it, validated against the actual ToolContext
    /// conversation (`rootTaskID`) and against canonical depth (nested
    /// delegation is never minted and is refused). The newest run of a
    /// conversation is never chosen as a substitute for a known original.
    @MainActor
    func handoffRun(for context: ToolContext, owner: UUID) throws -> UUID {
        try BrowserControlIdentity.logicalRun(for: context, owner: owner)
    }

    @MainActor
    func run(
        context: ToolContext,
        action: BrowserAction,
        tabID: UUID? = nil,
        documentID: String? = nil,
        visualEvidenceSHA256: String? = nil,
        visualFallbackReason: String? = nil,
        timeoutMilliseconds: Int = 15_000
    ) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let center else { throw FloeError.invalidConfiguration("The task browser service is unavailable") }
        let control: Control
        do {
            control = try self.control(for: context)
        } catch BrowserControlError.needsUser(let message) {
            // The user owns the page. Return an honest needsUser result with
            // no page, screenshot, event or control token instead of reading
            // anything, and do not queue for a later attempt.
            return needsUserOutput(message)
        }
        let command = BrowserCommand(
            sessionID: control.session.sessionID,
            tabID: tabID,
            expectedDocumentID: documentID,
            timeoutMilliseconds: timeoutMilliseconds,
            visualEvidenceSHA256: visualEvidenceSHA256,
            visualFallbackReason: visualFallbackReason,
            action: action
        )
        // The owner and holding period are applied explicitly; visibility is
        // irrelevant and the command contents cannot choose a session.
        let result = await center.execute(command, in: control.owner, control: control.lease)
        try context.cancellation.throwIfCancelled()
        let encoded = try JSONEncoder().encode(result)
        var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        if let marker = controlMarker(for: control) { object["control"] = marker }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        // The protocol already bounds nodes, events and tabs. Byte truncation
        // here creates invalid JSON and can remove action evidence mid-field.
        let summary = String(decoding: data, as: UTF8.self)
        guard result.status == .ok || result.status == .needsUser else {
            throw FloeError.validationFailed(result.message ?? "Browser action failed")
        }
        let artifacts = result.page?.screenshotArtifact.map {
            [ToolArtifactReference(
                id: $0.id, relativePath: $0.relativePath, mimeType: $0.mimeType,
                byteCount: $0.byteCount, sha256: $0.sha256
            )]
        } ?? []
        // The protocol bounds nodes, events and tabs well below this ceiling,
        // but the default summary budget would still cut the JSON mid-field.
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            artifacts: artifacts,
            requiresUserAction: false,
            maximumSummaryCharacters: 262_144
        )
    }
}

/// Runtime-issued logical owner of a browser holding period. A delegated
/// child acts for its original parent run; nested/foreign identities are
/// refused. This is the same identity the durable handoff receipt uses, so
/// control release and user-takeover notification always target one run.
enum BrowserControlIdentity {
    static func logicalRun(for context: ToolContext, owner: UUID) throws -> UUID {
        guard let child = context.childExecution else { return context.runID }
        let identity = child.identity
        guard identity.depth == 1 else {
            throw FloeError.validationFailed(
                "A nested delegated child cannot use this task's browser control"
            )
        }
        guard identity.rootTaskID == owner else {
            throw FloeError.validationFailed(
                "The delegated child belongs to a different root task and cannot use this task's browser"
            )
        }
        return identity.parentRunID
    }
}

private struct BrowserPanelTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let reason: String?
        let tabID: UUID?
    }
    static let name = "browser.panel"
    static let toolDescription = "Browser navigation and previews run without opening the user's panel. Only when human interaction is necessary (login, verification, file selection or an explicit user interaction request), call requestUser with a concise reason explaining what the user must do. It opens this task's browser panel, hands browser control to the user. The task may continue other work; browser mutations are unavailable until the user returns control. The return event is delivered to this task; observe the page again before acting. Do not use it for ordinary navigation or progress display. hide closes only the browser panel after the user has returned control; it never changes the main navigation sidebar."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["requestUser","hide"]},"reason":{"type":"string","maxLength":500},"tabID":{"type":"string","format":"uuid"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard ["requestUser", "hide"].contains(args.action) else { throw FloeError.validationFailed("Unknown browser panel action") }
        if args.action == "requestUser" {
            guard let reason = args.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty, reason.count <= 500 else {
                throw FloeError.validationFailed("Explain the required human interaction in 1–500 characters")
            }
        } else if args.tabID != nil || args.reason != nil {
            throw FloeError.validationFailed("hide does not accept a tab or interaction reason")
        }
    }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try validate(args)
        guard let center = environment.center else { throw FloeError.invalidConfiguration("Browser is unavailable") }
        let owner = try environment.owner(for: context)
        if args.action == "requestUser" {
            let reason = args.reason!.trimmingCharacters(in: .whitespacesAndNewlines)
            // The handoff run is the exact original run: this run's own id for
            // a main-run call, or the runtime-issued parent run of a delegated
            // child (never the conversation's newest run). The notification
            // therefore can never be orphaned on a finished child run or
            // misattributed to a newer run of the same task.
            let handoffRunID = try environment.handoffRun(for: context, owner: owner)
            try center.requestUserInteraction(
                reason: reason,
                tabID: args.tabID,
                runID: handoffRunID,
                in: owner
            )
            return ToolExecutionOutput(summary: "The user controls this task's browser; continue other authorized work. A return notification will arrive in this task. Requested interaction: " + reason, fullOutputSHA256: FloeDigest.sha256Hex(Data(reason.utf8)), requiresUserAction: false)
        }
        try center.requestPanelDismissal(conversationID: owner)
        return ToolExecutionOutput(digesting: "Browser panel closed; sidebar preference retained")
    }
}

private struct BrowserTabsTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "browser.tabs"
    static let toolDescription = "List tabs in this task's browser session with exact tab IDs and active state. Does not open, switch or close tabs."
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return try await environment.run(context: context, action: .listTabs)
    }
}

private struct BrowserTabTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let tabID: UUID?
    }
    static let name = "browser.tab"
    static let toolDescription = "Create, activate, or close a tab in this task's browser session. Create returns a new tab ID; use browser.navigate on that ID to open a URL. Activate/close require an exact tabID from browser.tabs. Does not manage other apps' tabs."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","activate","close"]},"tabID":{"type":"string","format":"uuid"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard ["create", "activate", "close"].contains(args.action) else {
            throw FloeError.validationFailed("Unknown tab action")
        }
        guard (args.action == "create") == (args.tabID == nil) else {
            throw FloeError.validationFailed("Create must omit tabID; activate/close require tabID")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try validate(args)
        let action: BrowserAction
        switch args.action {
        case "create": action = .create
        case "activate": action = .activateTab(args.tabID!)
        default: action = .closeTab(args.tabID!)
        }
        return try await environment.run(context: context, action: action)
    }
}

private struct BrowserEventsTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let afterSequence: Int?; let limit: Int? }
    static let name = "browser.events"
    static let toolDescription = "Read bounded CDP-style lifecycle and DOM events from this task's browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"afterSequence":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        if let sequence = args.afterSequence, sequence < 0 { throw FloeError.validationFailed("afterSequence must be non-negative") }
        if let limit = args.limit, !(1...50).contains(limit) { throw FloeError.validationFailed("limit must be between 1 and 50") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context,
            action: .events(afterSequence: args.afterSequence, limit: args.limit ?? 20),
            tabID: args.tabID
        )
    }
}

private struct BrowserWaitTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let condition: String
        let value: String?
        let quietMilliseconds: Int?
        let timeoutMilliseconds: Int?
    }
    static let name = "browser.wait"
    static let toolDescription = "Wait for load, DOM readiness, selector, text, document change, or approximate idle in this task's browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"condition":{"type":"string","enum":["load","dom","selector","text","documentChanged","idle"]},"value":{"type":"string","maxLength":512},"quietMilliseconds":{"type":"integer","minimum":100,"maximum":5000},"timeoutMilliseconds":{"type":"integer","minimum":250,"maximum":30000}},"required":["condition"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard ["load", "dom", "selector", "text", "documentChanged", "idle"].contains(args.condition) else {
            throw FloeError.validationFailed("Unknown browser wait condition")
        }
        if ["selector", "text", "documentChanged"].contains(args.condition),
           args.value?.isEmpty != false {
            throw FloeError.validationFailed("This wait condition requires value")
        }
        if let value = args.value, value.utf8.count > 512 {
            throw FloeError.validationFailed("Browser wait value exceeds 512 bytes")
        }
        if let quiet = args.quietMilliseconds, !(100...5_000).contains(quiet) {
            throw FloeError.validationFailed("quietMilliseconds must be between 100 and 5000")
        }
        if let timeout = args.timeoutMilliseconds, !(250...30_000).contains(timeout) {
            throw FloeError.validationFailed("timeoutMilliseconds must be between 250 and 30000")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let condition: BrowserWaitCondition
        switch args.condition {
        case "load": condition = .load
        case "dom": condition = .domContentLoaded
        case "selector": condition = .selector(args.value ?? "")
        case "text": condition = .text(args.value ?? "")
        case "documentChanged": condition = .documentChanged(from: args.value ?? "")
        default: condition = .idle(milliseconds: args.quietMilliseconds ?? 500)
        }
        return try await environment.run(context: context,
            action: .wait(condition),
            tabID: args.tabID,
            timeoutMilliseconds: args.timeoutMilliseconds ?? 15_000
        )
    }
}

private struct BrowserNavigateTool: AgentTool {
    struct Arguments: Decodable, Sendable { let url: String; let tabID: UUID? }
    static let name = "browser.navigate"
    static let toolDescription = "Navigate this task's browser to an http or https URL without opening the user's panel. Use browser.panel requestUser only for a required human interaction"
    static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string"},"tabID":{"type":"string"}},"required":["url"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws { _ = try BrowserURLPolicy.parseNavigationURL(args.url) }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try environment.owner(for: context)
        _ = try BrowserURLPolicy.validate(args.url, conversationID: owner, allowLocalNetwork: true)
        return try await environment.run(context: context, action: .navigate(url: args.url), tabID: args.tabID)
    }
}

private struct BrowserObserveTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let cursor: Int?
        let profile: String?
        let designAction: String?
        let captureID: UUID?
        let needsFile: String?
    }
    static let name = "browser.observe"
    static let toolDescription = "FIRST choice for reading a page: bounded semantic DOM with stable refs, text, state and bounds. Default profile=semantic; continue pagination before concluding information is absent. profile=design captures a fixed, redacted design snapshot in this task's workspace; designAction=capture returns native capture metadata and relative files, not an engine verdict. Run the installed design engine through the existing task Linux exec.shell. For an actual needs-facts result, use designAction=facts with captureID and the workspace-relative Needs JSON file; native measurements remain bound to that exact run, tab and document. Release the capture after the scan. Navigation, scrolling or resizing invalidates it. No JavaScript is accepted."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"cursor":{"type":"integer","minimum":0},"profile":{"type":"string","enum":["semantic","design"]},"designAction":{"type":"string","enum":["capture","facts","release"]},"captureID":{"type":"string","format":"uuid"},"needsFile":{"type":"string","maxLength":1024}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        let profile = args.profile ?? "semantic"
        guard ["semantic", "design"].contains(profile) else { throw FloeError.validationFailed("Unknown observation profile") }
        if let cursor = args.cursor, cursor < 0 { throw FloeError.validationFailed("cursor must be non-negative") }
        if profile == "semantic" {
            guard args.designAction == nil, args.captureID == nil, args.needsFile == nil else {
                throw FloeError.validationFailed("Design arguments require profile=design")
            }
            return
        }
        guard args.cursor == nil else { throw FloeError.validationFailed("Design captures do not accept a semantic cursor") }
        switch args.designAction ?? "capture" {
        case "capture":
            guard args.captureID == nil, args.needsFile == nil else { throw FloeError.validationFailed("A new capture does not accept previous capture files") }
        case "facts":
            guard args.captureID != nil, let file = args.needsFile, !file.isEmpty, file.utf8.count <= 1024 else {
                throw FloeError.validationFailed("facts requires captureID and a bounded workspace-relative needsFile")
            }
        case "release":
            guard args.captureID != nil, args.needsFile == nil else { throw FloeError.validationFailed("release requires only captureID and optional tabID") }
        default:
            throw FloeError.validationFailed("Unknown design action")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        if args.profile == "design" {
            return try await environment.design(context: context, action: args.designAction ?? "capture",
                tabID: args.tabID, captureID: args.captureID, needsFile: args.needsFile)
        }
        return try await environment.run(context: context, action: .observe(cursor: args.cursor), tabID: args.tabID)
    }
}

private struct BrowserScreenshotTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID? }
    static let name = "browser.screenshot"
    static let toolDescription = "Capture the current viewport when browser.observe is unavailable or semantically insufficient. Returns on-device OCR visualTextRegions with text-N references and exact screenshot-pixel bounds. Prefer browser.clickVisualText for a matching text anchor; use browser.clickPoint only when neither DOM refs nor text anchors identify the target."
    static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context, action: .screenshot, tabID: args.tabID)
    }
}

/// Commits the full-resolution PNG that this task's own preview page staged
/// for export as a NEW workspace file — the delivered-artifact route for the
/// art/poster packages, whose pages rasterize at exact declared pixel sizes
/// that a viewport screenshot can never represent. The page cannot start
/// this operation, cannot choose the destination and its bytes are re-derived
/// natively (declared-size caps before decode, native SHA-256, PNG structure);
/// a data-URL click download alone materializes no file in WKWebView, and this
/// typed pull is the only page-to-workspace file route.
private struct BrowserExportStagedFileTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let path: String
        let expectedWidth: Int?
        let expectedHeight: Int?
    }
    static let name = "browser.exportFile"
    static let toolDescription = "Commit the full-resolution PNG that this task's own preview page staged for export (its Export PNG / Download PNG control) as a NEW workspace file. The page must be this task's authorized local preview in this task's browser and must have staged the raster first; native reads it back through a fixed script, verifies the byte count, checksum and PNG structure, and never overwrites an existing file. Verify the committed file (for example the package's verify_png.py through exec.shell) and publish it with workspace.publishOutput. A browser.screenshot capture is viewport-bounded preview evidence, never this deliverable."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"path":{"type":"string","maxLength":1024,"description":"Workspace-relative destination file ending in .png; must not exist yet"},"expectedWidth":{"type":"integer","minimum":1,"maximum":16384,"description":"Required exact pixel width of the staged raster"},"expectedHeight":{"type":"integer","minimum":1,"maximum":16384,"description":"Required exact pixel height of the staged raster"}},"required":["path"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        let rejections = StagedExportValidation.destinationRejections(
            args.path.trimmingCharacters(in: .whitespaces))
        guard rejections.isEmpty else {
            throw FloeError.validationFailed(rejections.joined(separator: "; "))
        }
        if let width = args.expectedWidth,
           !(1...StagedExportContract.maxDimension).contains(width) {
            throw FloeError.validationFailed("expectedWidth must be between 1 and \(StagedExportContract.maxDimension)")
        }
        if let height = args.expectedHeight,
           !(1...StagedExportContract.maxDimension).contains(height) {
            throw FloeError.validationFailed("expectedHeight must be between 1 and \(StagedExportContract.maxDimension)")
        }
    }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try validate(args)
        return try await environment.exportStagedFile(
            context: context,
            tabID: args.tabID,
            path: args.path.trimmingCharacters(in: .whitespaces),
            expectedWidth: args.expectedWidth,
            expectedHeight: args.expectedHeight
        )
    }
}

private struct BrowserClickVisualTextTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let documentID: String
        let reference: String
        let screenshotSHA256: String
    }
    static let name = "browser.clickVisualText"
    static let toolDescription = "Click an OCR-backed text-N reference from the latest browser.screenshot when no semantic DOM ref represents that visible text. The reference is bound to the current document and screenshot digest; a post-click screenshot must show an observable change."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"documentID":{"type":"string"},"reference":{"type":"string","pattern":"^text-[1-9][0-9]*$"},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"}},"required":["documentID","reference","screenshotSHA256"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard !args.documentID.isEmpty,
              args.reference.range(of: #"^text-[1-9][0-9]*$"#, options: .regularExpression) != nil,
              args.screenshotSHA256.count == 64,
              args.screenshotSHA256.allSatisfy(\.isHexDigit) else {
            throw FloeError.validationFailed(
                "documentID, a text-N reference, and its fresh screenshot sha256 are required"
            )
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context,
            action: .click(.visualText(reference: args.reference)),
            tabID: args.tabID,
            documentID: args.documentID,
            visualEvidenceSHA256: args.screenshotSHA256,
            visualFallbackReason: "insufficientStructuredInformation"
        )
    }
}

private struct BrowserClickTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let ref: String; let documentID: String }
    static let name = "browser.click"
    static let toolDescription = "Preferred browser action: click a stable element ref returned by browser.observe. Use this before any coordinate fallback."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"ref":{"type":"string"},"documentID":{"type":"string"}},"required":["ref","documentID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard !args.ref.isEmpty, !args.documentID.isEmpty else { throw FloeError.validationFailed("ref and documentID are required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context,
            action: .click(.element(ref: args.ref, documentID: args.documentID)),
            tabID: args.tabID,
            documentID: args.documentID
        )
    }
}

/// Coordinate fallback for canvas/custom controls after a fresh screenshot.
/// It still uses public WebKit DOM hit-testing; it does not forge trusted iOS
/// touch events and therefore may return takeover-required on protected UI.
private struct BrowserClickPointTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let documentID: String
        let x: Double
        let y: Double
        let screenshotSHA256: String
        let fallbackReason: String
    }
    static let name = "browser.clickPoint"
    static let toolDescription = "LAST-RESORT visual fallback after browser.observe: click x/y in the exact pixel coordinate space of the fresh browser.screenshot artifact. Provide that screenshot's sha256 and the exact fallback reason. Floe converts screenshot pixels to the page's CSS viewport and reports success only when a post-click screenshot or page state shows an observable change. Canvas-internal controls may use this fallback; ordinary DOM controls with stable refs are rejected and must use browser.click."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"documentID":{"type":"string"},"x":{"type":"number","minimum":0,"maximum":10000},"y":{"type":"number","minimum":0,"maximum":10000},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"fallbackReason":{"type":"string","enum":["noStructuredTarget","insufficientStructuredInformation"]}},"required":["documentID","x","y","screenshotSHA256","fallbackReason"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard !args.documentID.isEmpty, args.x.isFinite, args.y.isFinite,
              (0...10_000).contains(args.x), (0...10_000).contains(args.y) else {
            throw FloeError.validationFailed("documentID and bounded screenshot pixel coordinates are required")
        }
        guard args.screenshotSHA256.count == 64,
              args.screenshotSHA256.allSatisfy(\.isHexDigit) else {
            throw FloeError.validationFailed("a fresh browser screenshot sha256 is required")
        }
        guard ["noStructuredTarget", "insufficientStructuredInformation"]
            .contains(args.fallbackReason) else {
            throw FloeError.validationFailed("fallbackReason must explain why structured access is insufficient")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context,
            action: .click(.point(x: args.x, y: args.y)),
            tabID: args.tabID,
            documentID: args.documentID,
            visualEvidenceSHA256: args.screenshotSHA256,
            visualFallbackReason: args.fallbackReason
        )
    }
}

private struct BrowserTypeTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let ref: String
        let documentID: String
        let text: String
        let submit: Bool?
    }
    static let name = "browser.type"
    static let toolDescription = "Type into a non-password element in this task's browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"ref":{"type":"string"},"documentID":{"type":"string"},"text":{"type":"string","maxLength":16384},"submit":{"type":"boolean"}},"required":["ref","documentID","text"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI, .sendsDataToProvider]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard !args.ref.isEmpty, !args.documentID.isEmpty else { throw FloeError.validationFailed("ref and documentID are required") }
        guard args.text.utf8.count <= 16 * 1024 else { throw FloeError.validationFailed("text exceeds 16 KiB") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context,
            action: .type(.element(ref: args.ref, documentID: args.documentID), text: args.text, submit: args.submit ?? false),
            tabID: args.tabID,
            documentID: args.documentID
        )
    }
}

private struct BrowserScrollTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let deltaX: Double?; let deltaY: Double }
    static let name = "browser.scroll"
    static let toolDescription = "Scroll this task's browser viewport"
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard args.deltaY.isFinite, args.deltaX?.isFinite != false,
              abs(args.deltaY) <= 20_000, abs(args.deltaX ?? 0) <= 20_000 else {
            throw FloeError.validationFailed("scroll delta is invalid")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context, action: .scroll(deltaX: args.deltaX ?? 0, deltaY: args.deltaY), tabID: args.tabID)
    }
}

private struct BrowserLinksTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let cursor: Int?; let limit: Int? }
    static let name = "browser.links"
    static let toolDescription = "Read links from the current rendered DOM of this task's browser, including links created after page load. Returns absolute hrefs, text, title, target, download attribute and stable element refs. Use browser.navigate or browser.download with a chosen href; this tool does not follow links."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"cursor":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment

    func validate(_ args: Arguments) throws {
        if let cursor = args.cursor, cursor < 0 { throw FloeError.validationFailed("cursor must be non-negative") }
        if let limit = args.limit, !(1...100).contains(limit) { throw FloeError.validationFailed("limit must be between 1 and 100") }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await environment.run(
            context: context,
            action: .listLinks(cursor: args.cursor, limit: args.limit ?? 50),
            tabID: args.tabID
        )
    }
}

private struct BrowserTableTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let index: Int?; let cursor: Int?; let limit: Int? }
    static let name = "browser.table"
    static let toolDescription = "Read a table from the current rendered DOM of this task's browser. Returns caption, headers, bounded rows and the next row cursor. Use browser.text for prose outside tables."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"index":{"type":"integer","minimum":0,"maximum":49},"cursor":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment

    func validate(_ args: Arguments) throws {
        if let index = args.index, !(0...49).contains(index) { throw FloeError.validationFailed("index must be between 0 and 49") }
        if let cursor = args.cursor, cursor < 0 { throw FloeError.validationFailed("cursor must be non-negative") }
        if let limit = args.limit, !(1...100).contains(limit) { throw FloeError.validationFailed("limit must be between 1 and 100") }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await environment.run(
            context: context,
            action: .readTable(index: args.index ?? 0, cursor: args.cursor, limit: args.limit ?? 50),
            tabID: args.tabID
        )
    }
}

private struct BrowserTextTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let start: Int?; let maxCharacters: Int? }
    static let name = "browser.text"
    static let toolDescription = "Read a bounded character range of the rendered body text from this task's browser. Use start/nextStart for long pages. This reads the current DOM text, not the raw HTML source."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"start":{"type":"integer","minimum":0,"maximum":10000000},"maxCharacters":{"type":"integer","minimum":1000,"maximum":65536}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment

    func validate(_ args: Arguments) throws {
        if let start = args.start, !(0...10_000_000).contains(start) { throw FloeError.validationFailed("start is out of bounds") }
        if let maxCharacters = args.maxCharacters, !(1_000...65_536).contains(maxCharacters) {
            throw FloeError.validationFailed("maxCharacters must be between 1000 and 65536")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await environment.run(
            context: context,
            action: .readText(start: args.start ?? 0, maxCharacters: args.maxCharacters ?? 16_384),
            tabID: args.tabID
        )
    }
}

private struct BrowserCookiesTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let tabID: UUID?
        let includeValues: Bool?
        let cookie: HTTPCookieInput?
        let name: String?
        let domain: String?
        let path: String?
    }
    static let name = "browser.cookies"
    static let toolDescription = "Read or manage cookies for the active task-browser origin through public WebKit APIs. list returns attributes; includeValues=true explicitly returns raw values and requires one-time provider authorization. set accepts a full cookie object (including httpOnly); delete removes matching cookies; clear removes all cookies for the origin. Raw values never enter ordinary logs or durable captures; explicit raw-value results carry a sensitivity hook for redacted persistence."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["list","set","delete","clear"]},"tabID":{"type":"string","format":"uuid"},"includeValues":{"type":"boolean","description":"Explicitly return raw cookie values; default false returns attributes and lengths only"},"cookie":{"type":"object","properties":{"name":{"type":"string"},"value":{"type":"string"},"domain":{"type":"string"},"path":{"type":"string"},"secure":{"type":"boolean"},"httpOnly":{"type":"boolean"},"expiresAt":{"type":"string"},"sameSite":{"type":"string"}},"required":["name","value"],"additionalProperties":false},"name":{"type":"string"},"domain":{"type":"string"},"path":{"type":"string"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.accessesCredentials, .controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment

    func validate(_ args: Arguments) throws {
        guard ["list", "set", "delete", "clear"].contains(args.action) else {
            throw FloeError.validationFailed("Unknown cookie action")
        }
        if args.action == "set" {
            guard let cookie = args.cookie, !cookie.name.isEmpty, cookie.value.utf8.count <= 4_096 else {
                throw FloeError.validationFailed("set requires a bounded cookie object with name and value")
            }
        }
        if args.action == "delete" {
            guard args.name != nil || args.domain != nil || args.path != nil || args.cookie != nil else {
                throw FloeError.validationFailed("delete requires at least one matching attribute or a cookie object")
            }
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        _ = try environment.owner(for: context)
        try context.cancellation.throwIfCancelled()
        let recipient = try await environment.requireBrowserDataAccess(context: context)
        let control = try environment.control(for: context)
        let session = control.session
        let bridge = BrowserWebDataBridge(session: session)
        let selectedTab = args.tabID ?? session.activeTabID
        let pageOrigin = session.tabs.first(where: { $0.id == selectedTab })
            .flatMap { HTTPCookiePolicy.origin($0.webView.url ?? URL(string: "about:blank")!) }

        switch args.action {
        case "list":
            let includeValues = args.includeValues == true
            let records = try await bridge.cookies(tabID: args.tabID, includeValues: includeValues)
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            let sanitized = records.map { record -> BrowserCookieRecord in
                var copy = record
                copy.value = nil
                return copy
            }
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok",
                "action": "list",
                "origin": pageOrigin ?? "",
                "cookies": try Self.jsonObject(sanitized),
                "includeValues": includeValues,
                "valuesRedacted": includeValues
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            var ephemeral: String?
            if includeValues {
                ephemeral = try BrowserSensitiveOutput.encodedSummary([
                    "status": "ok",
                    "action": "list",
                    "origin": pageOrigin ?? "",
                    "cookies": try Self.jsonObject(records),
                    "includeValues": true
                ])
            }
            return try Self.output(object, maximum: 262_144, ephemeralSensitiveOutput: ephemeral)
        case "set":
            guard let input = args.cookie else {
                throw FloeError.validationFailed("set requires a cookie object")
            }
            let record = try await bridge.setCookie(tabID: args.tabID, input: input)
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "set", "origin": pageOrigin ?? "",
                "cookie": try Self.jsonObject([record])
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 16_384)
        case "delete":
            let name = args.name ?? args.cookie?.name
            let domain = args.domain ?? args.cookie?.domain
            let path = args.path ?? args.cookie?.path
            let count = try await bridge.deleteCookies(tabID: args.tabID, name: name, domain: domain, path: path)
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "delete", "origin": pageOrigin ?? "", "deleted": count
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 8_192)
        default:
            let count = try await bridge.clearCookies(tabID: args.tabID)
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "clear", "origin": pageOrigin ?? "", "deleted": count
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 8_192)
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func output(
        _ object: [String: Any],
        maximum: Int,
        ephemeralSensitiveOutput: String? = nil
    ) throws -> ToolExecutionOutput {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            maximumSummaryCharacters: maximum,
            ephemeralSensitiveOutput: ephemeralSensitiveOutput
        )
    }
}

private struct BrowserStorageTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let kind: String?
        let tabID: UUID?
        let origin: String?
        let key: String?
        let value: String?
        let includeValues: Bool?
    }
    static let name = "browser.storage"
    static let toolDescription = "Read or manage localStorage/sessionStorage for the exact origin and tab of this task's browser. list returns bounded keys; get returns metadata and, only with includeValues=true, the raw value; set/delete/clear mutate that tab's storage. This does not read Safari or Keychain data. Explicit raw values carry a sensitivity hook for redacted persistence."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["list","get","set","delete","clear"]},"kind":{"type":"string","enum":["local","session"]},"tabID":{"type":"string","format":"uuid"},"origin":{"type":"string","maxLength":2048,"description":"Must match the active tab's exact origin"},"key":{"type":"string","maxLength":512},"value":{"type":"string","maxLength":16384},"includeValues":{"type":"boolean","description":"Explicitly return raw storage values; default false"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.accessesCredentials, .controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment

    func validate(_ args: Arguments) throws {
        guard ["list", "get", "set", "delete", "clear"].contains(args.action) else {
            throw FloeError.validationFailed("Unknown storage action")
        }
        if let kind = args.kind, BrowserStorageKind(rawValue: kind) == nil {
            throw FloeError.validationFailed("kind must be local or session")
        }
        if ["get", "set", "delete"].contains(args.action) {
            guard let key = args.key, !key.isEmpty, key.utf8.count <= 512 else {
                throw FloeError.validationFailed("This storage action requires a bounded key")
            }
        }
        if args.action == "set" {
            guard let value = args.value, value.utf8.count <= 16 * 1_024 else {
                throw FloeError.validationFailed("set requires a value no larger than 16 KiB")
            }
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        _ = try environment.owner(for: context)
        try context.cancellation.throwIfCancelled()
        let recipient = try await environment.requireBrowserDataAccess(context: context)
        let control = try environment.control(for: context)
        let session = control.session
        let bridge = BrowserWebDataBridge(session: session)
        let kind = BrowserStorageKind(rawValue: args.kind ?? "local") ?? .local
        let includeValues = args.includeValues == true
        let origin = args.origin ?? session.tabs.first(where: { $0.id == (args.tabID ?? session.activeTabID) })
            .flatMap { $0.webView.url }
            .flatMap(HTTPCookiePolicy.origin)

        switch args.action {
        case "list":
            let page = try await bridge.storage(
                tabID: args.tabID,
                kind: kind,
                requestedOrigin: args.origin,
                includeValues: includeValues
            )
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            let sanitized = page.entries.map { entry -> BrowserStorageEntry in
                BrowserStorageEntry(key: entry.key, value: nil, valueLength: entry.valueLength)
            }
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "list", "kind": kind.rawValue,
                "origin": page.origin, "entries": try Self.jsonObject(sanitized),
                "totalKeys": page.totalKeys, "truncated": page.truncated,
                "includeValues": includeValues, "valuesRedacted": includeValues
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            var ephemeral: String?
            if includeValues {
                ephemeral = try BrowserSensitiveOutput.encodedSummary([
                    "status": "ok", "action": "list", "kind": kind.rawValue,
                    "origin": page.origin, "entries": try Self.jsonObject(page.entries),
                    "totalKeys": page.totalKeys, "truncated": page.truncated,
                    "includeValues": true
                ])
            }
            return try Self.output(object, maximum: 262_144, ephemeralSensitiveOutput: ephemeral)
        case "get":
            guard let key = args.key else { throw FloeError.validationFailed("get requires key") }
            let value = try await bridge.storageValue(
                tabID: args.tabID,
                kind: kind,
                requestedOrigin: args.origin,
                key: key
            )
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "get", "kind": kind.rawValue,
                "origin": origin ?? "", "key": key,
                "hasValue": value != nil,
                "valueLength": value?.utf8.count ?? 0,
                "includeValues": includeValues,
                "valuesRedacted": includeValues
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            var ephemeral: String?
            if includeValues, let value {
                ephemeral = try BrowserSensitiveOutput.encodedSummary([
                    "status": "ok", "action": "get", "kind": kind.rawValue,
                    "origin": origin ?? "", "key": key, "value": value
                ])
            }
            return try Self.output(object, maximum: 32_768, ephemeralSensitiveOutput: ephemeral)
        case "set":
            guard let key = args.key, let value = args.value else {
                throw FloeError.validationFailed("set requires key and value")
            }
            try await bridge.setStorage(
                tabID: args.tabID, kind: kind,
                requestedOrigin: args.origin, key: key, value: value
            )
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "set", "kind": kind.rawValue,
                "origin": origin ?? "", "key": key, "valueLength": value.utf8.count
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 8_192)
        case "delete":
            try await bridge.deleteStorage(
                tabID: args.tabID, kind: kind,
                requestedOrigin: args.origin, key: args.key ?? ""
            )
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "delete", "kind": kind.rawValue,
                "origin": origin ?? "", "key": args.key ?? ""
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 8_192)
        default:
            try await bridge.clearStorage(
                tabID: args.tabID, kind: kind, requestedOrigin: args.origin
            )
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "clear", "kind": kind.rawValue,
                "origin": origin ?? ""
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 8_192)
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func output(
        _ object: [String: Any],
        maximum: Int,
        ephemeralSensitiveOutput: String? = nil
    ) throws -> ToolExecutionOutput {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            maximumSummaryCharacters: maximum,
            ephemeralSensitiveOutput: ephemeralSensitiveOutput
        )
    }
}

private struct BrowserSiteDataTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let scope: String?
        let displayName: String?
        let types: [String]?
    }
    static let name = "browser.siteData"
    static let toolDescription = "List or delete this task-browser website-data records through WKWebsiteDataStore. list shows only site names and data-type metadata, never cache bodies or cookie values. scope persistent targets retained data; session targets the current in-memory store. Deleting a site or clearing all uses the public WebKit record API and does not touch Safari, Keychain or user files."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["list","delete","clear"]},"scope":{"type":"string","enum":["persistent","session","all"]},"displayName":{"type":"string","maxLength":512},"types":{"type":"array","items":{"type":"string"},"maxItems":32}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.accessesCredentials, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment

    func validate(_ args: Arguments) throws {
        guard ["list", "delete", "clear"].contains(args.action) else {
            throw FloeError.validationFailed("Unknown site-data action")
        }
        if args.action == "delete" {
            guard let name = args.displayName, !name.isEmpty, name.utf8.count <= 512 else {
                throw FloeError.validationFailed("delete requires a bounded displayName")
            }
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        _ = try environment.owner(for: context)
        try context.cancellation.throwIfCancelled()
        let recipient = try await environment.requireBrowserDataAccess(context: context)
        let control = try environment.control(for: context)
        let session = control.session
        let scope = args.scope ?? "persistent"
        guard ["persistent", "session", "all"].contains(scope) else {
            throw FloeError.validationFailed("Unknown site-data scope")
        }
        let types = args.types.map { Set($0.filter { BrowserWebDataBridge.allWebsiteDataTypes.contains($0) }) }
        if let types, types.isEmpty { throw FloeError.validationFailed("No recognized website data types") }
        let settings = session.websiteDataStore
        var stores: [(String, WKWebsiteDataStore)] = []
        if scope != "session" { stores.append(("persistent", .default())) }
        if scope != "persistent" {
            if scope == "session" || settings !== WKWebsiteDataStore.default() {
                stores.append(("session", settings))
            }
        }
        if stores.isEmpty { stores.append(("persistent", .default())) }

        switch args.action {
        case "list":
            var sites: [[String: Any]] = []
            for (name, store) in stores {
                let groups = await BrowserWebDataBridge.records(store: store, types: types)
                for group in groups {
                    sites.append([
                        "scope": name,
                        "displayName": group.displayName,
                        "dataTypes": group.dataTypes
                    ])
                }
            }
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = ["status": "ok", "action": "list", "sites": sites]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 131_072)
        case "delete":
            let name = args.displayName ?? ""
            var deleted = 0
            for (_, store) in stores {
                deleted += await BrowserWebDataBridge.deleteRecords(
                    store: store,
                    displayNames: [name],
                    types: types
                )
            }
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "delete", "displayName": name, "deleted": deleted
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 8_192)
        default:
            var cleared = 0
            for (_, store) in stores {
                cleared += await BrowserWebDataBridge.clearAll(store: store)
            }
            try environment.revalidateBrowserDataAccess(recipient, context: context)
            try environment.assertCurrent(control)
            var object: [String: Any] = [
                "status": "ok", "action": "clear", "cleared": cleared
            ]
            if let marker = environment.controlMarker(for: control) { object["control"] = marker }
            return try Self.output(object, maximum: 8_192)
        }
    }

    private static func output(_ object: [String: Any], maximum: Int) throws -> ToolExecutionOutput {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            maximumSummaryCharacters: maximum
        )
    }
}

private struct BrowserDownloadTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let url: String
        let path: String
        let tabID: UUID?
        let maxBytes: Int?
        let overwrite: Bool?
    }
    static let name = "browser.download"
    static let toolDescription = "Download a PDF or image through this task's own browser session into a new workspace file. The source tab's WebKit website data store supplies existing login cookies, so authenticated resources can be saved without exposing cookie values to the model. The file is staged, checked for a real PDF/image signature and the byte cap, then committed atomically; progress is visible and cancellable in the browser chrome. Existing destinations are refused unless overwrite=true was explicitly confirmed. Returns a workspace path and run-output attachment."
    static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","description":"HTTP(S) PDF or image URL, usually from browser.links"},"path":{"type":"string","maxLength":1024,"description":"Workspace-relative destination; must not exist unless overwrite is confirmed"},"tabID":{"type":"string","format":"uuid"},"maxBytes":{"type":"integer","minimum":1,"maximum":67108864},"overwrite":{"type":"boolean","description":"Set true only after explicit user confirmation to replace the destination"}},"required":["url","path"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess, .writesFiles, .accessesCredentials]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment

    func validate(_ args: Arguments) throws {
        _ = try BrowserURLPolicy.parseNavigationURL(args.url)
        let path = args.path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.split(separator: "/").contains("..") else {
            throw FloeError.validationFailed("path must be a workspace-relative file path")
        }
        if let maxBytes = args.maxBytes, !(1...64 * 1_024 * 1_024).contains(maxBytes) {
            throw FloeError.validationFailed("maxBytes is out of bounds")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        return try await environment.download(
            context: context,
            tabID: args.tabID,
            urlString: args.url,
            path: args.path.trimmingCharacters(in: .whitespaces),
            maxBytes: args.maxBytes,
            overwrite: args.overwrite
        )
    }
}

/// Explicit end of one model holding period. It releases only the caller's
/// own lease: the page, tabs, login state and scroll position stay exactly
/// where they are, and the tool can never acquire page access. Repeating an
/// already-consumed token is a no-op, so a stale release can never unlock the
/// run's newer holding period.
private struct BrowserReleaseTool: AgentTool {
    struct Arguments: Decodable, Sendable { let controlID: UUID }
    static let name = "browser.release"
    static let toolDescription = "Release this run's control of this task's browser when you have finished browsing. Pass the control.id from your latest browser tool result. The page and tabs stay open for the user; another run may then take control. Repeating an old release has no effect. This tool never grants page access and requires no confirmation."
    static let parametersJSON = #"{"type":"object","properties":{"controlID":{"type":"string","format":"uuid"}},"required":["controlID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment

    func validate(_ args: Arguments) throws {}

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let center = environment.center else {
            throw FloeError.invalidConfiguration("The task browser service is unavailable")
        }
        let owner = try environment.owner(for: context)
        let runID = try environment.handoffRun(for: context, owner: owner)
        // Never create a browser just to release one.
        guard let session = center.session(for: owner), !session.isReleased else {
            return ToolExecutionOutput(digesting: "No task browser is open; nothing was released")
        }
        if session.isUserControlling {
            return ToolExecutionOutput(digesting: "The user controls this browser; nothing was released")
        }
        switch center.releaseModelControl(
            conversationID: owner,
            runID: runID,
            controlID: args.controlID
        ) {
        case .released:
            return ToolExecutionOutput(digesting: "Browser control released; the page stays open for the user")
        case .alreadyReleased:
            return ToolExecutionOutput(digesting: "That browser control was already released; nothing changed")
        case .heldByAnotherRun:
            throw FloeError.validationFailed(
                "This browser is controlled by another run; nothing was released"
            )
        }
    }
}

@MainActor
func registerBrowserTools(center: BrowserSessionCenter, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(BrowserPanelTool.self)
    registry.register(BrowserPanelTool(environment: BrowserToolEnvironment(center: center)))
    ToolCatalog.register(BrowserTabsTool.self)
    ToolCatalog.register(BrowserTabTool.self)
    registry.register(BrowserTabsTool(environment: BrowserToolEnvironment(center: center)))
    registry.register(BrowserTabTool(environment: BrowserToolEnvironment(center: center)))
    let environment = BrowserToolEnvironment(center: center)
    ToolCatalog.register(BrowserNavigateTool.self)
    ToolCatalog.register(BrowserObserveTool.self)
    ToolCatalog.register(BrowserEventsTool.self)
    ToolCatalog.register(BrowserWaitTool.self)
    ToolCatalog.register(BrowserScreenshotTool.self)
    ToolCatalog.register(BrowserClickVisualTextTool.self)
    ToolCatalog.register(BrowserClickTool.self)
    ToolCatalog.register(BrowserClickPointTool.self)
    ToolCatalog.register(BrowserTypeTool.self)
    ToolCatalog.register(BrowserScrollTool.self)
    ToolCatalog.register(BrowserExportStagedFileTool.self)
    ToolCatalog.register(BrowserLinksTool.self)
    ToolCatalog.register(BrowserTableTool.self)
    ToolCatalog.register(BrowserTextTool.self)
    ToolCatalog.register(BrowserCookiesTool.self)
    ToolCatalog.register(BrowserStorageTool.self)
    ToolCatalog.register(BrowserSiteDataTool.self)
    ToolCatalog.register(BrowserDownloadTool.self)
    ToolCatalog.register(BrowserReleaseTool.self)
    registry.register(BrowserNavigateTool(environment: environment))
    registry.register(BrowserObserveTool(environment: environment))
    registry.register(BrowserEventsTool(environment: environment))
    registry.register(BrowserWaitTool(environment: environment))
    registry.register(BrowserScreenshotTool(environment: environment))
    registry.register(BrowserClickVisualTextTool(environment: environment))
    registry.register(BrowserClickTool(environment: environment))
    registry.register(BrowserClickPointTool(environment: environment))
    registry.register(BrowserTypeTool(environment: environment))
    registry.register(BrowserScrollTool(environment: environment))
    registry.register(BrowserExportStagedFileTool(environment: environment))
    registry.register(BrowserLinksTool(environment: environment))
    registry.register(BrowserTableTool(environment: environment))
    registry.register(BrowserTextTool(environment: environment))
    registry.register(BrowserCookiesTool(environment: environment))
    registry.register(BrowserStorageTool(environment: environment))
    registry.register(BrowserSiteDataTool(environment: environment))
    registry.register(BrowserDownloadTool(environment: environment))
    registry.register(BrowserReleaseTool(environment: environment))
}
#endif
