// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — the REAL registered
// `document.office.edit` tool for Android.
//
// What this actually connects (Main acceptance 2026-10-27):
//   chat request → `read` resolves-or-opens the conversation's document
//   through the existing App-owned Office lifecycle (the same
//   `OfficePreviewController.openWorkspace` staging + existing FloeShell
//   viewer launch effect — no headless engine, no second controller, no
//   first-document fallback, never another conversation's document), opens a
//   trusted owned EDIT CONTEXT holding the real P-A capture, lets the model
//   reason on the returned producer facts, then `apply` revalidates THAT
//   SAME target (never a silent fresh capture at apply time), executes one
//   typed allowlisted precision command, flushes the working copy, stages a
//   verified native export, verifies the ACTUAL saved OOXML bytes/structure
//   and cell types, publishes a runtime-sealed run output under the real
//   submitting ToolContext, and — only when explicitly requested — saves the
//   ORIGINAL through the acquired workspace write lease + the existing CAS
//   journal, reporting local and provider outcomes separately.
//
// What it never does:
//   * accept a raw UNO/wire/key/body string, a paragraph offset, an
//     arbitrary PPT object identity, a session token, a native generation,
//     an engine target handle or a filesystem path outside the task's own
//     workspace namespace;
//   * treat an acknowledgement, a matching frame, `ModifiedStatus` or a
//     `nativeCompleted` state as a persisted mutation;
//   * auto-replay or auto-undo an UNKNOWN effect, or report a clean
//     cancellation while a resource is live;
//   * publish under anyone's call but its own (the runtime strict-seals the
//     receipt against this exact call).

import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

public struct OfficeDocumentEditTool: AgentTool {

    // MARK: Arguments

    public enum Action: String, Codable, Sendable, Equatable, CaseIterable {
        case capabilities
        case read
        case apply
        case collect
    }

    public struct Arguments: Codable, Sendable {
        /// One of `capabilities` / `read` / `apply` / `collect`.
        public var action: Action
        /// Read or apply sub-command (validated against the action).
        public var command: String?
        /// Content for applyText/setCellContent only.
        public var text: String?
        /// A1 cell reference for setCellContent only.
        public var cell: String?
        /// "literal" | "formula" — REQUIRED for setCellContent.
        public var contentType: String?
        /// 1-based slide/sheet number for selectSlide only.
        public var slide: Int?
        /// Task-workspace-relative document path for `read` (opens the
        /// document through the existing owner-safe lifecycle when no owned
        /// viewer is open yet). Never absolute, never outside the task root.
        public var workspacePath: String?
        /// Opaque edit-context selector returned by a prior `read`
        /// (or refreshed preparatory effect). REQUIRED for `apply`; it is a
        /// lookup selector only and carries no direct authority.
        public var editContext: String?
        /// Completed Office edit job id for `collect` only.
        public var jobID: String?
        /// Explicit original-workspace save request (content `apply` only).
        /// Local CAS commit and provider journal outcomes are reported
        /// separately; a journal failure never retries the native edit.
        public var saveOriginal: Bool?

        public init(action: Action, command: String? = nil, text: String? = nil,
                    cell: String? = nil, contentType: String? = nil, slide: Int? = nil,
                    workspacePath: String? = nil, editContext: String? = nil,
                    jobID: String? = nil, saveOriginal: Bool? = nil) {
            self.action = action
            self.command = command
            self.text = text
            self.cell = cell
            self.contentType = contentType
            self.slide = slide
            self.workspacePath = workspacePath
            self.editContext = editContext
            self.jobID = jobID
            self.saveOriginal = saveOriginal
        }
    }

    // MARK: Metadata

    public static let name = "document.office.edit"
    public static let toolDescription =
        "Edit the Office document (DOCX/XLSX/PPTX) owned by THIS conversation through the real in-app engine. "
        + "Actions: capabilities; read (command=documentContext|textSelection|cellCursor|presentationInfo, optional workspacePath inside the task workspace to open the document through the normal in-app viewer when none is open — always returns an editContext id); "
        + "apply (REQUIRED editContext from a read: command=selectSlide|selectAllText move the target and answer a refreshed editContext, or applyText|setCellContent change content; content apply flushes, exports and verifies the ACTUAL saved file (intended content at the captured target — never mere global text presence) and publishes it as a run-output file; setCellContent REQUIRES contentType literal|number|formula: literal is an exact string (a leading = stays a literal through the host's safe encoding), number is a finite canonical decimal stored numerically, formula keeps its mandatory leading = and is verified against the actual saved <f> source; optional saveOriginal=true additionally commits the verified bytes over the original workspace document through the existing CAS journal and reports workspace vs provider outcomes separately); "
        + "collect (jobID of a COMPLETED authorized jobs.submit document.office.edit apply: re-verifies that job's stored artifact and publishes it under this call; it never re-applies any native effect). "
        + "A native acknowledgement is never reported as success without the verified saved file; an UNKNOWN effect is retained, never auto-retried or auto-undone. Raw UNO/wire/key commands, absolute paths, other documents' identities and current-selection guessing are not accepted."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "action":{"type":"string","enum":["capabilities","read","apply","collect"],
        "description":"capabilities = supported commands and limits; read = inspect and open an editContext; apply = one typed effect against that editContext; collect = publish a completed job's verified artifact"},
      "command":{"type":"string","enum":["documentContext","textSelection","cellCursor","presentationInfo","selectSlide","selectAllText","applyText","setCellContent"],
        "description":"read: documentContext|textSelection|cellCursor(XLSX)|presentationInfo(PPTX); apply: selectSlide|selectAllText|applyText|setCellContent"},
      "text":{"type":"string","maxLength":65536,"description":"Applied text for applyText/setCellContent (UTF-8 <= 64 KiB, no control-line breaks for cells)"},
      "cell":{"type":"string","description":"A1 cell reference for setCellContent (current sheet), e.g. B4 or $B$4"},
      "contentType":{"type":"string","enum":["literal","number","formula"],"description":"REQUIRED for setCellContent: literal = exact string (a leading = stays literal via the host's safe apostrophe encoding), number = finite canonical decimal, formula must start with ="},
      "slide":{"type":"integer","minimum":1,"maximum":1024,"description":"1-based slide/sheet number for selectSlide (XLSX/PPTX)"},
      "workspacePath":{"type":"string","description":"read only: task-workspace-relative .docx/.xlsx/.pptx path to open when no owned viewer is open; never an absolute path"},
      "editContext":{"type":"string","description":"apply only: the editContext id returned by a prior read; revalidates THAT captured target, never a fresh silent capture"},
      "jobID":{"type":"string","description":"collect only: id of a COMPLETED authorized document.office.edit job"},
      "saveOriginal":{"type":"boolean","description":"apply only: additionally commit the verified bytes over the ORIGINAL workspace document (CAS replace under the owned lease + the existing provider journal when one is bound); workspace and provider outcomes are reported separately and conflicts keep recoverable copies"}
    },"required":["action"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let executionBoundary: ToolExecutionBoundary = .any
    public static let supportsConcurrentBatchDispatch = false

    // MARK: Dependencies

    private let port: any OfficeEditEnginePort
    /// Deferred accessor (not the value): the durable job service is composed
    /// AFTER this tool is registered; the `collect` action re-reads the OWNED
    /// job row from the ORIGINAL store through this seam.
    private let serviceProvider: @Sendable () -> BackgroundJobService?
    /// The catalog name the publication path reports as `producerTool`. Must
    /// equal this tool's registered name so the runtime strict seal binds the
    /// receipt to the real submitting call.
    public static var producerToolName: String { name }

    public init(port: any OfficeEditEnginePort,
                serviceProvider: @escaping @Sendable () -> BackgroundJobService?) {
        self.port = port
        self.serviceProvider = serviceProvider
    }

    // MARK: Validation

    public func validate(_ args: Arguments) throws {
        switch args.action {
        case .capabilities:
            guard args.command == nil, args.text == nil, args.cell == nil,
                  args.contentType == nil, args.slide == nil, args.workspacePath == nil,
                  args.editContext == nil, args.jobID == nil, args.saveOriginal == true else {
                throw FloeError.validationFailed(
                    "action=capabilities takes no other arguments")
            }
        case .read:
            guard let raw = args.command, let read = OfficeEditReadCommand(rawValue: raw) else {
                throw FloeError.validationFailed(
                    "action=read requires command one of: \(OfficeEditReadCommand.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            try Self.reject(args, [.text, .cell, .contentType, .slide, .editContext, .jobID,
                                  .saveOriginal], for: "read")
            if let path = args.workspacePath { try Self.validWorkspaceRelativePath(path) }
        case .apply:
            guard let contextID = args.editContext, Self.isOpaqueSelector(contextID) else {
                throw FloeError.validationFailed(
                    "action=apply requires the 'editContext' id returned by a prior read; this tool never captures a fresh target silently at apply time")
            }
            guard let raw = args.command,
                  let apply = OfficeEditApplyCommand(rawValue: raw) else {
                throw FloeError.validationFailed(
                    "action=apply requires command one of: selectSlide, selectAllText, applyText, setCellContent")
            }
            try Self.reject(args, [.jobID, .workspacePath], for: "apply")
            switch apply {
            case .selectSlide:
                guard let slide = args.slide, (1...1024).contains(slide) else {
                    throw FloeError.validationFailed("apply command selectSlide requires slide in 1...1024")
                }
                try Self.reject(args, [.text, .cell, .contentType, .saveOriginal], for: "selectSlide")
            case .selectAllText:
                try Self.reject(args, [.text, .cell, .contentType, .slide, .saveOriginal],
                                for: "selectAllText")
            case .applyText:
                guard let text = args.text else {
                    throw FloeError.validationFailed("apply command applyText requires text")
                }
                try Self.validText(text)
                try Self.reject(args, [.cell, .contentType, .slide], for: "applyText")
            case .setCellContent:
                guard let cell = args.cell, OfficeEditLimits.isValidCellAddress(cell) else {
                    throw FloeError.validationFailed(
                        "apply command setCellContent requires a valid A1 cell reference (optional $ anchors, column <= XFD, row <= 1048576)")
                }
                guard let text = args.text else {
                    throw FloeError.validationFailed("apply command setCellContent requires text")
                }
                try Self.validText(text)
                guard OfficeEditLimits.isSingleCellSafe(text) else {
                    throw FloeError.validationFailed(
                        "setCellContent text must stay inside ONE cell: tab, carriage return and newline are refused, never spread across cells")
                }
                guard let kindRaw = args.contentType,
                      let kind = OfficeEditContentKind(rawValue: kindRaw) else {
                    throw FloeError.validationFailed(
                        "setCellContent requires contentType literal, number or formula — the producer parses pasted text exactly as typed")
                }
                switch kind {
                case .literal:
                    // Amendment/2: a literal is an EXACT string, including
                    // 00123 and leading '='. The trusted host applies a
                    // leading-'=' literal through its safe apostrophe encoding
                    // (the codec apostrophe is not part of the wanted value),
                    // so the obsolete shared-side leading-'=' refusal is gone;
                    // the saved string type + raw content are verified.
                    break
                case .number:
                    guard OfficeEditLimits.isValidFiniteNumberText(text) else {
                        throw FloeError.validationFailed(
                            "contentType=number requires a finite canonical decimal number "
                                + "(digits with optional fraction/exponent); use literal for text "
                                + "such as 00123 that must keep its exact string form")
                    }
                case .formula:
                    guard text.hasPrefix("=") else {
                        throw FloeError.validationFailed(
                            "contentType=formula requires the text to start with '='")
                    }
                }
                try Self.reject(args, [.slide], for: "setCellContent")
            }
        case .collect:
            guard let jobID = args.jobID, UUID(uuidString: jobID.trimmingCharacters(in: .whitespaces)) != nil else {
                throw FloeError.validationFailed("action=collect requires jobID: the id of a COMPLETED authorized document.office.edit job")
            }
            try Self.reject(args, [.command, .text, .cell, .contentType, .slide, .workspacePath,
                                   .editContext, .saveOriginal], for: "collect")
        }
    }

    enum OptionalField {
        case command, text, cell, contentType, slide, editContext, jobID, workspacePath, saveOriginal
        var name: String {
            switch self {
            case .command: return "command"
            case .text: return "text"
            case .cell: return "cell"
            case .contentType: return "contentType"
            case .slide: return "slide"
            case .editContext: return "editContext"
            case .jobID: return "jobID"
            case .workspacePath: return "workspacePath"
            case .saveOriginal: return "saveOriginal"
            }
        }
    }
    private static func reject(_ args: Arguments, _ fields: [OptionalField], for action: String) throws {
        for field in fields {
            let present: Bool
            switch field {
            case .command: present = args.command != nil
            case .text: present = args.text != nil
            case .cell: present = args.cell != nil
            case .contentType: present = args.contentType != nil
            case .slide: present = args.slide != nil
            case .editContext: present = args.editContext != nil
            case .jobID: present = args.jobID != nil
            case .workspacePath: present = args.workspacePath != nil
            case .saveOriginal: present = args.saveOriginal == true
            }
            if present {
                throw FloeError.validationFailed("argument '\(field.name)' is not accepted for \(action)")
            }
        }
    }

    private static func validText(_ text: String) throws {
        guard OfficeEditLimits.isValidText(text) else {
            throw FloeError.validationFailed(
                "text must be non-empty, contain no NUL characters and stay within \(OfficeEditLimits.maximumTextBytes) UTF-8 bytes")
        }
    }

    /// The model may only address documents INSIDE the submitting task's own
    /// workspace namespace; the runtime confines the resolved path the same
    /// way the file tools do. Absolute paths and traversal are refused here
    /// and re-confined again by the tool context before anything opens.
    private static func validWorkspaceRelativePath(_ path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048 else {
            throw FloeError.validationFailed("workspacePath must be a non-empty task-workspace-relative path")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("\\") else {
            throw FloeError.validationFailed("workspacePath must be relative to the task workspace, never absolute")
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              segments.first != "", !trimmed.contains("//") else {
            throw FloeError.validationFailed("workspacePath must not contain empty, '.' or '..' segments")
        }
        guard let ext = trimmed.split(separator: ".").last.map(String.init)?.lowercased(),
              OfficeEditDocumentFamily(rawValue: ext) != nil else {
            throw FloeError.validationFailed("workspacePath must name a .docx, .xlsx or .pptx document")
        }
    }

    /// Opaque selector grammar: UUID-shaped string, bounded; it is a LOOKUP
    /// key into the Core edit-context store, never engine authority.
    static func isOpaqueSelector(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 32, trimmed.count <= 64 else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: Execute

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        // A background-job executor synthesizes a `jobs.<uuid>` call context
        // with NO provider call of ours: publishing under it could never be
        // strict-sealed into a durable card and is forbidden (Main integration
        // fact 2026-10-27). The ORIGINAL service adapter owns deferred applies;
        // this runner only executes inline.
        if context.toolCallID?.hasPrefix("jobs.") == true {
            throw FloeError.invalidConfiguration(
                "document.office.edit runs inline or through its authorized service adapter, "
                + "never as a raw background job runner")
        }
        guard !context.temporaryReadOnly else {
            // Belt-and-braces: temporary chat already keeps a text/public-web
            // tool ceiling above this dispatch; the durable owner must exist
            // for ANY Office effect.
            throw FloeError.validationFailed(
                "Temporary chat cannot edit Office documents; run this from an ordinary saved task")
        }
        switch args.action {
        case .capabilities:
            return try officeOutput(Self.capabilitiesPayload, requiresUserAction: false)
        case .read:
            return try await executeRead(args, context: context)
        case .apply:
            return try await executeApply(args, context: context)
        case .collect:
            return try await executeCollect(args, context: context)
        }
    }

    // MARK: read

    private func executeRead(_ args: Arguments, context: ToolContext) async throws
        -> ToolExecutionOutput {
        guard port.isHostLaneLive() else { throw OfficeEditHostError.hostLaneUnavailable }
        let readCommand = OfficeEditReadCommand(rawValue: args.command!)!
        let workspaceRelative = try confinedWorkspacePath(args.workspacePath, context: context)
        let seed = Self.seed(runID: context.runID, callID: context.toolCallID, args: args)
        let conversationID = try requiringConversation(context)
        let opened = try await port.openEditContext(
            runID: context.runID, conversationID: conversationID,
            workspaceRelativePath: workspaceRelative, cancellation: context.cancellation)
        let result = try await port.read(readCommand, contextID: opened.contextID,
                                         conversationID: conversationID, seed: seed,
                                         cancellation: context.cancellation)
        guard result.state == .queryObserved || result.state == .mutationVerified
            || result.state == .nativeCompleted else {
            return try officeOutput(Self.refusalPayload(stage: "read", result: result,
                                                        contextID: opened.contextID),
                                    exitStatus: 1)
        }
        var payload: [String: Any] = [
            "status": "ok",
            "command": readCommand.rawValue,
            "engineState": result.state.rawValue,
            "attestation": result.attestation,
            "editContext": opened.contextID,
            "captureAttested": opened.captureAttested,
            "document": Self.documentPayload(opened.document),
        ]
        if !result.facts.isEmpty { payload["facts"] = Self.factsPayload(result.facts) }
        if let readback = result.contentReadback { payload["contentReadback"] = readback }
        return try officeOutput(payload, exitStatus: 0)
    }

    // MARK: apply

    private func executeApply(_ args: Arguments, context: ToolContext) async throws
        -> ToolExecutionOutput {
        guard port.isHostLaneLive() else { throw OfficeEditHostError.hostLaneUnavailable }
        let applyCommand = OfficeEditApplyCommand(rawValue: args.command!)!
        let contextID = args.editContext!
        // The submitting conversation must exist; the per-family support and
        // document realm are enforced by the revalidated owned context inside
        // the port (never from anything this call echoes back).
        let conversationID = try requiringConversation(context)
        let seed = Self.seed(runID: context.runID, callID: context.toolCallID, args: args)

        // Preparatory selection/navigation: no bytes, no publication; honest
        // recapture for the follow-up apply.
        if applyCommand == .selectSlide || applyCommand == .selectAllText {
            let command: OfficeEditPreparatoryCommand = applyCommand == .selectSlide
                ? .selectSlide(partID: (args.slide ?? 1) - 1)
                : .selectAllText
            let outcome = try await port.executePreparatory(
                command, contextID: contextID, conversationID: conversationID, seed: seed,
                cancellation: context.cancellation)
            var payload: [String: Any] = [
                "status": outcome.result.isEffectProven ? "ok" : "refused",
                "command": applyCommand.rawValue,
                "engineState": outcome.result.state.rawValue,
                "attestation": outcome.result.attestation,
            ]
            if let failure = outcome.result.failureCode { payload["failure"] = failure }
            if let detail = outcome.result.detail { payload["detail"] = detail }
            if let refreshed = outcome.refreshedContext {
                payload["editContext"] = refreshed.contextID
                if !refreshed.capturedContext.isEmpty {
                    payload["recapturedContext"] = Self.factsPayload(refreshed.capturedContext)
                }
            } else if outcome.result.state == .unknown {
                payload["note"] = Self.unknownRetentionNote
            }
            return try officeOutput(payload, exitStatus: outcome.result.isEffectProven ? 0 : 1)
        }

        // Content effect: full verified chain.
        let command: OfficeEditContentCommand
        switch applyCommand {
        case .applyText:
            command = .applyText(args.text!)
        case .setCellContent:
            command = .setCellContent(cell: OfficeEditLimits.canonicalCellAddress(args.cell!),
                                      text: args.text!,
                                      kind: OfficeEditContentKind(rawValue: args.contentType!)!)
        default:
            throw FloeError.validationFailed("unsupported apply command")
        }
        let outcome = try await port.executeContent(
            command, contextID: contextID, conversationID: conversationID, seed: seed,
            cancellation: context.cancellation)

        guard outcome.result.isEffectProven else {
            var payload = Self.refusalPayloadFromContent(outcome)
            if outcome.result.state == .unknown { payload["note"] = Self.unknownRetentionNote }
            return try officeOutput(payload, exitStatus: 1)
        }
        guard outcome.flush.state == .flushed, let snapshot = outcome.snapshot else {
            let code = outcome.flush.state == .unmodified ? "nativeUnmodifiedAfterApply"
                : (outcome.flush.failureCode ?? "flushNotProven")
            throw OfficeEditHostError.verificationFailed(
                code: code,
                detail: "The native engine did not prove saved bytes for this apply "
                    + "(flush state \(outcome.flush.state.rawValue)); nothing was published or committed. "
                    + "The working copy is retained for inspection.")
        }
        guard let semantic = outcome.semantic, !semantic.isUnproven else {
            throw OfficeEditHostError.verificationFailed(
                code: "semanticNotInspected",
                detail: "The saved OOXML package could not be inspected, so the applied content is "
                    + "UNVERIFIED. The verified export and working copy are retained; no success is claimed.")
        }
        if let verdict = Self.semanticGateFailure(command: applyCommand, semantic: semantic) {
            throw verdict
        }

        // Verified chain: publish the sealed run output under THIS call.
        let published = try port.publishVerifiedOutput(
            snapshot, semantic: semantic, slot: Self.publishSlot, context: context)

        var payload: [String: Any] = [
            "status": "verifiedSaved",
            "command": applyCommand.rawValue,
            "engineState": outcome.result.state.rawValue,
            "attestation": outcome.result.attestation,
            "flush": [
                "state": outcome.flush.state.rawValue,
                "workingCopySHA256": outcome.flush.workingCopySha256 ?? "",
                "workingCopyBytes": outcome.flush.workingCopyBytes,
            ],
            "saved": [
                "sha256": snapshot.sha256,
                "bytes": snapshot.byteCount,
                "attestation": snapshot.attestation,
            ],
            "semantic": Self.semanticPayload(semantic),
            "published": Self.publishedPayload(published),
        ]
        if let readback = outcome.result.contentReadback { payload["contentReadback"] = readback }

        // Optional explicit original save. Local and provider outcomes are
        // reported SEPARATELY; a journal failure never re-applies the edit.
        if args.saveOriginal == true, let document = outcome.document {
            let original = try await port.saveOriginal(
                snapshot, document: document, cancellation: context.cancellation)
            payload["originalSave"] = Self.originalSavePayload(original)
        } else if args.saveOriginal == true {
            payload["originalSave"] = ["local": "unsupported", "provider": "refused",
                                       "detail": "The applied effect did not carry document facts; original save was not attempted."]
        }
        return try officeOutput(payload, exitStatus: 0, outputFiles: [published])
    }

    /// The final content gate: which semantic facts must be TRUE before this
    /// command may report success. Kept strict — a missing required fact is a
    /// failure, never a pass.
    static func semanticGateFailure(command: OfficeEditApplyCommand,
                                    semantic: OfficeEditSemanticFacts) -> OfficeEditHostError? {
        OfficeEditSemanticGate.failure(command: command, semantic: semantic)
    }

    // MARK: collect

    private func executeCollect(_ args: Arguments, context: ToolContext) async throws
        -> ToolExecutionOutput {
        guard port.isHostLaneLive() else { throw OfficeEditHostError.hostLaneUnavailable }
        let conversationID = try requiringConversation(context)
        let jobID = UUID(uuidString: args.jobID!.trimmingCharacters(in: .whitespaces))!
        guard let service = serviceProvider() else {
            throw FloeError.invalidConfiguration("the durable job service is not composed in this build")
        }
        // Trusted durable read only. The model supplied an opaque job id; the
        // ORIGINAL store answers ownership, state and the frozen payload.
        let job: BackgroundJob?
        do { job = try await service.job(id: jobID) } catch {
            throw OfficeEditHostError.rejected(code: "jobUnreadable",
                                               detail: "The job row could not be read; nothing was published.")
        }
        guard let job else {
            throw OfficeEditHostError.rejected(code: "jobUnknown",
                                               detail: "No such job in this build's durable store.")
        }
        guard job.conversationID == conversationID else {
            throw OfficeEditHostError.rejected(
                code: "jobNotOwned",
                detail: "That job belongs to a different task; this tool publishes only jobs owned by the "
                    + "current conversation, resolved from the durable store — never from a quoted id.")
        }
        guard job.targetTool == Self.name else {
            throw OfficeEditHostError.rejected(code: "jobWrongTarget",
                                               detail: "That job is not a document.office.edit job.")
        }
        guard job.state == .completed else {
            throw OfficeEditHostError.rejected(
                code: "jobNotTerminalCompleted",
                detail: "The job state is '\(job.state.rawValue)'; collect publishes only a COMPLETED "
                    + "(verified) job. Use jobs.status for progression and never force success here.")
        }
        guard let path = job.resultPath, !path.isEmpty,
              let digest = job.resultDigest?.lowercased(),
              RunOutputFile.isValidSHA256Hex(digest) else {
            throw OfficeEditHostError.verificationFailed(
                code: "jobArtifactUnrecorded",
                detail: "The completed job recorded no verifiable artifact digest; inspect its result "
                    + "summary instead. Nothing was published.")
        }
        // Re-derive expectations from the job's OWN frozen payload.
        let frozen = try JSONDecoder().decode(Arguments.self, from: job.payloadJSON)
        guard frozen.action == .apply,
              let applyRaw = frozen.command,
              let applyCommand = OfficeEditApplyCommand(rawValue: applyRaw),
              applyCommand.isContentEffect else {
            throw OfficeEditHostError.rejected(
                code: "jobPayloadNotContentApply",
                detail: "The frozen job payload is not a content apply; there is nothing to collect.")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard let format = OfficeEditDocumentFamily(rawValue: ext) else {
            throw OfficeEditHostError.verificationFailed(
                code: "jobArtifactFormatUnknown",
                detail: "The recorded artifact extension is not a known OOXML family; nothing was adopted.")
        }
        let displayName = Self.collectedDisplayName(artifactPath: path, format: format)
        // Independent re-verification of the durable bytes (never a trust of
        // the recorded strings: the file is re-lstat'd, re-hashed and
        // re-scanned here) — then a FRESH semantic inspection. No native
        // mutation is ever re-applied during collect.
        let snapshot = try port.adoptVerifiedFile(
            path: path, expectedSha256: digest, expectedBytes: nil,
            format: format, displayName: displayName)
        // Amendment/2 owned identity for a COMPLETED-job proof: the stage opIds
        // are deterministically RECOMPUTED from the durable row's OWN
        // run/call/frozen-payload digest — the ORIGINAL apply/export identity
        // of the job that produced this artifact, NEVER this collect call's
        // identity.
        let originalSeed = OfficeEditOperationIdentity.derive(
            runID: job.runID, callID: job.toolCallID,
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(job.payloadJSON), step: "call")
        // Amendment/2 (Main ruling): historical reuse requires the ORIGINAL
        // service's DURABLE v2 VERIFIED summary — operation/seed/artifact
        // digest/format plus the strong producer version — read ONLY from
        // this original durable row, never from a model summary or path.
        // Old v1 rows, tampered summaries and unprovable targets stay
        // REFUSED; proofReused is never requested for them.
        guard let ownedTarget = Self.validatedOwnedV2Target(
            job: job, snapshot: snapshot, command: applyCommand, family: format,
            originalSeed: originalSeed) else {
            throw OfficeEditHostError.verificationFailed(
                code: "jobV2TargetUnproven",
                detail: "This completed job has no durable v2 verified target summary, or it "
                    + "failed validation against the row's own operation/seed/recorded digest. "
                    + "The captured logical part cannot be proven from this row; nothing was published.")
        }
        let expectations = OfficeEditExpectations(
            command: applyCommand, family: format,
            text: frozen.text,
            cell: frozen.cell.map(OfficeEditLimits.canonicalCellAddress),
            contentKind: frozen.contentType.flatMap(OfficeEditContentKind.init(rawValue:)),
            partIndex: ownedTarget.partIndex,
            preEditSnapshotSha256: ownedTarget.preEditSha256,
            verificationMode: .completedJob,
            effectOpId: OfficeEditOperationIdentity.stageOpId(seed: originalSeed, stage: "apply"),
            exportOpId: OfficeEditOperationIdentity.stageOpId(seed: originalSeed, stage: "export"),
            ownerTaskID: job.conversationID)
        let semantic = try await port.inspectSavedPackage(
            snapshot, expectations: expectations, cancellation: context.cancellation)
        guard !semantic.isUnproven else {
            throw OfficeEditHostError.verificationFailed(
                code: "semanticNotInspected",
                detail: "The stored artifact could not be inspected as a real OOXML package; nothing was published.")
        }
        if let verdict = Self.semanticGateFailure(command: applyCommand, semantic: semantic) {
            throw verdict
        }
        let published = try port.publishVerifiedOutput(
            snapshot, semantic: semantic, slot: Self.publishSlot, context: context)
        return try officeOutput([
            "status": "collectedVerified",
            "jobID": job.id.uuidString,
            "operation": Self.operationID(of: job),
            "command": applyCommand.rawValue,
            "saved": ["sha256": snapshot.sha256, "bytes": snapshot.byteCount,
                      "attestation": snapshot.attestation],
            "semantic": Self.semanticPayload(semantic),
            "published": Self.publishedPayload(published),
            "note": "Re-verified from the job's durable artifact and published under THIS call. "
                + "No native effect was replayed.",
        ], exitStatus: 0, outputFiles: [published])
    }

    private static func operationID(of job: BackgroundJob) -> String {
        NativeJobProgressDocument.decode(job.progressJSON)?.prepared?.operationID ?? "-"
    }

    /// The bounded owned v2 target metadata recovered from the ORIGINAL
    /// durable row's own verified summary (amendment/2). Every field was
    /// written by the producing job's verified run; `collect` validates the
    /// whole block against the row's own facts (operation, recomputed seed,
    /// recorded artifact digest, format, strong producer version) before ANY
    /// historical reuse is requested. Absent or unvalidated ⇒ nil ⇒ refusal.
    struct OwnedV2Target: Sendable, Equatable {
        var operation: String
        var seed: String
        var savedSHA256: String
        var format: OfficeEditDocumentFamily
        var command: OfficeEditApplyCommand
        var preEditSha256: String?
        var partIndex: Int?
    }

    static func validatedOwnedV2Target(job: BackgroundJob,
                                       snapshot: OfficeEditSavedSnapshot,
                                       command: OfficeEditApplyCommand,
                                       family: OfficeEditDocumentFamily,
                                       originalSeed: String) -> OwnedV2Target? {
        // Read ONLY the original durable row's own stored verified summary;
        // a model-quoted summary or path is never consulted.
        guard let summaryText = job.resultSummary, !summaryText.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(summaryText.utf8))
                as? [String: Any],
              let target = object["ownedV2Target"] as? [String: Any],
              let version = (target["producerProofVersion"] as? NSNumber)?.intValue,
              version == 2,
              let operation = target["operation"] as? String, !operation.isEmpty,
              let seed = target["seed"] as? String, !seed.isEmpty,
              let saved = (target["savedSHA256"] as? String)?.lowercased(),
              RunOutputFile.isValidSHA256Hex(saved),
              let formatRaw = target["format"] as? String,
              let targetFormat = OfficeEditDocumentFamily(rawValue: formatRaw),
              targetFormat == family,
              let commandRaw = target["command"] as? String,
              let targetCommand = OfficeEditApplyCommand(rawValue: commandRaw),
              targetCommand == command else { return nil }
        // Strong producer identity: the persisted operation must equal the
        // row's own prepared operation and the seed the deterministically
        // recomputed ORIGINAL job seed (never this collect call's identity).
        guard operation == operationID(of: job), seed == originalSeed else { return nil }
        // The persisted artifact digest must equal BOTH the row's recorded
        // digest and the independently re-verified adopted snapshot bytes.
        guard let recorded = job.resultDigest?.lowercased(), recorded == saved,
              snapshot.sha256.lowercased() == saved else { return nil }
        let baseline = (target["preEditSha256"] as? String).flatMap {
            RunOutputFile.isValidSHA256Hex($0.lowercased()) ? $0.lowercased() : nil
        }
        var partIndex = (target["partIndex"] as? NSNumber)?.intValue
        if family == .docx {
            partIndex = nil
        } else if partIndex == nil {
            // XLSX/PPTX REQUIRE the captured logical part identity; a v2 row
            // without it is unprovable and stays refused (Main ruling).
            return nil
        }
        return OwnedV2Target(operation: operation, seed: seed, savedSHA256: saved,
                             format: targetFormat, command: targetCommand,
                             preEditSha256: baseline, partIndex: partIndex)
    }

    /// Stable bounded display name from the durable artifact stem. The frozen
    /// job payload carries no document name by design (no model paths), so
    /// the collected name derives from the engine's own output stem.
    public static func collectedDisplayName(artifactPath: String,
                                            format: OfficeEditDocumentFamily) -> String {
        let stem = ((artifactPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let safe = stem.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let capped = String(safe.prefix(96))
        return "\(capped).edited.\(format.rawValue)"
    }

    // MARK: Shared helpers

    static let publishSlot = "office-document"

    static let unknownRetentionNote =
        "The effect's outcome is UNKNOWN inside the bounded window. The working copy and any partial "
        + "output are retained; do NOT resubmit the same apply automatically — inspect the document "
        + "(read again creates a FRESH context) and decide explicitly."

    private func requiringConversation(_ context: ToolContext) throws -> UUID {
        guard let conversationID = context.conversationID else {
            throw FloeError.validationFailed(
                "Office editing runs only inside a conversation task; this call has no owning task")
        }
        return conversationID
    }

    /// Confines a model-supplied workspace-relative path to the submitting
    /// call's OWN frozen workspace root (same authority the file tools use);
    /// returns the canonical relative path for the owner-safe open, or nil.
    private func confinedWorkspacePath(_ raw: String?, context: ToolContext) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = context.workspaceRootURL else {
            throw FloeError.validationFailed(
                "workspacePath needs the task workspace; this call runs without one")
        }
        // Canonical containment under the frozen root, no symlink following
        // into other realms, then re-checked through the call's own path
        // authority. A regular .docx/.xlsx/.pptx file is required.
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonical = candidate.resolvingSymlinksInPath()
        guard canonical.path == canonicalRoot.path
            || canonical.path.hasPrefix(canonicalRoot.path + "/") else {
            throw FloeError.validationFailed("workspacePath escapes the task workspace")
        }
        try context.authorizeWorkspacePath(canonical.path)
        var isRegular: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isRegular),
              !isRegular.boolValue else {
            throw FloeError.validationFailed("workspacePath must name an existing regular file in the task workspace")
        }
        let relative = String(canonical.path.dropFirst(canonicalRoot.path.count).dropFirst())
        guard OfficeEditDocumentFamily(
            rawValue: (relative as NSString).pathExtension.lowercased()) != nil else {
            throw FloeError.validationFailed("workspacePath must name a .docx, .xlsx or .pptx document")
        }
        return relative
    }

    /// Stable per-call seed: the SAME call retried yields the SAME stage
    /// opIds (the engine's duplicate refusal then blocks any re-application),
    /// while a fresh call yields fresh ones.
    static func seed(runID: UUID, callID: String?, args: Arguments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(args)) ?? Data("{}".utf8)
        return OfficeEditOperationIdentity.derive(
            runID: runID, callID: callID,
            payloadDigest: FloeDigest.sha256Hex(data), step: "call")
    }

    static var capabilitiesPayload: [String: Any] {
        [
            "status": "ok",
            "actions": ["capabilities", "read", "apply", "collect"],
            "readCommands": OfficeEditReadCommand.allCases.map(\.rawValue),
            "applyCommands": [
                ["command": "selectSlide", "families": ["xlsx", "pptx"], "bytes": false,
                 "returnsRefreshedEditContext": true],
                ["command": "selectAllText", "families": ["docx", "xlsx", "pptx"], "bytes": false,
                 "returnsRefreshedEditContext": true],
                ["command": "applyText", "families": ["docx", "xlsx", "pptx"], "bytes": true,
                 "replacesCurrentSelectionOrInsertsAtCursor": true],
                ["command": "setCellContent", "families": ["xlsx"], "bytes": true,
                 "requiresContentType": true,
                 "contentKinds": ["literal", "number", "formula"]],
            ],
            "limits": [
                "textUTF8Bytes": OfficeEditLimits.maximumTextBytes,
                "selectionReturnedBytes": OfficeEditLimits.maximumReturnedSelectionBytes,
                "cell": "single A1 per setCellContent; tab/CR/LF refused; contentType literal|number|formula — literal is an exact string (leading '=' stays literal via the host's safe encoding), number is a finite canonical decimal, formula keeps its leading '='",
            ],
            "requirements": [
                "apply needs the editContext id returned by a read (that captured target is revalidated; stale/manual-retargeted contexts are refused, never silently re-captured at apply time)",
                "content apply flushes, exports, verifies the ACTUAL saved OOXML bytes/cell types and publishes a run-output file before reporting success",
                "saveOriginal is explicit and separate: workspace-local CAS replace plus the existing provider journal, with separate reported outcomes; conflicts keep recoverable copies and never retry the native edit",
                "collect publishes a COMPLETED job's re-verified artifact under this call and never re-applies a native effect",
            ],
            "knownLimits": [
                "select-all readback is a partial postcondition (a selection exists; 'all' is not separately provable from the pinned surface)",
                "a formula is verified against the ACTUAL saved <f> source (conservative normalization); the cached display value or an old formula is not proof, and shared/array formulas stay unresolvable-honest; recalculation is the engine's, not this tool's claim",
                "Impress shape geometry keeps only the engine's own precision (0.01 mm loss); rich objects are preserved but not re-verified property-by-property",
                "documents opened from the system picker without task ownership cannot be edited (no owner fence exists for them); open them through this conversation's workspace instead",
                "one native document at a time: while another document is open in this task the tool refuses instead of switching",
                "an UNKNOWN effect is retained, never auto-replayed or auto-undone",
            ],
        ]
    }

    static func documentPayload(_ document: OfficeEditDocumentFacts) -> [String: Any] {
        var payload: [String: Any] = [
            "family": document.family.rawValue,
            "route": document.route.rawValue,
            "editable": document.editable,
            "nativeGeneration": document.nativeGeneration,
        ]
        if let path = document.sourceLogicalPath { payload["logicalPath"] = path }
        if let workspaceID = document.workspaceID { payload["workspaceID"] = workspaceID.uuidString }
        if let sha = document.originalSnapshotSha256 { payload["openTimeSnapshotSHA256"] = sha }
        if let sha = document.workingCopySha256 {
            payload["workingCopySHA256"] = sha
            payload["workingCopyBytes"] = document.workingCopyBytes
        }
        return payload
    }

    static func factsPayload(_ facts: OfficeEditQueryFacts) -> [String: Any] {
        var payload: [String: Any] = [:]
        if let value = facts.docType { payload["docType"] = value }
        if let value = facts.partsCount { payload["partsCount"] = value }
        if let value = facts.selectedPart { payload["selectedPart"] = value }
        if let value = facts.viewID { payload["viewID"] = value }
        if let value = facts.readOnly { payload["readOnly"] = value }
        if let value = facts.documentModified { payload["documentModified"] = value }
        if let value = facts.selectionText { payload["selectionText"] = value }
        if let value = facts.selectionByteCount { payload["selectionByteCount"] = value }
        if let value = facts.selectionTruncated { payload["selectionTruncated"] = value }
        if let value = facts.cellColumn { payload["cursorColumn"] = value }
        if let value = facts.cellRow { payload["cursorRow"] = value }
        if let value = facts.cellEmpty { payload["cursorEmpty"] = value }
        if let value = facts.slideCount { payload["slideCount"] = value }
        if let value = facts.shownPart { payload["shownPart"] = value }
        if let value = facts.selectedTextBytes { payload["selectedTextBytes"] = value }
        if let value = facts.captureWorkingCopySha256 { payload["captureWorkingCopySha256"] = value }
        if let value = facts.captureWorkingCopyBytes { payload["captureWorkingCopyBytes"] = value }
        return payload
    }

    static func semanticPayload(_ semantic: OfficeEditSemanticFacts) -> [String: Any] {
        var payload: [String: Any] = ["inspected": semantic.inspectedSavedPackage,
                                      "proofVersion": semantic.proofVersion]
        if let value = semantic.partName { payload["part"] = value }
        if let value = semantic.expectedTextFound { payload["appliedTextPresent"] = value }
        if let value = semantic.expectedContentMatches { payload["expectedContentMatches"] = value }
        if let value = semantic.targetEffectVerified { payload["targetEffectVerified"] = value }
        if let value = semantic.semanticDeltaVerified { payload["semanticDeltaVerified"] = value }
        if let value = semantic.proofReused { payload["proofReused"] = value }
        if let value = semantic.occurrenceCount { payload["appliedTextOccurrences"] = value }
        if let value = semantic.replacementScope { payload["replacementScope"] = value }
        if let value = semantic.cellTypeAttribute { payload["cellType"] = value }
        if let value = semantic.cellHasFormula { payload["cellHasFormula"] = value }
        if let value = semantic.cellPersistedValue { payload["cellPersistedValue"] = value }
        if let value = semantic.cellTypeMatchesIntent { payload["cellTypeMatchesIntent"] = value }
        if let value = semantic.changedFromOriginal { payload["changedFromOriginal"] = value }
        if !semantic.limitations.isEmpty { payload["limitations"] = semantic.limitations }
        return payload
    }

    static func publishedPayload(_ receipt: RunOutputFile) -> [String: Any] {
        [
            "outputID": receipt.outputID,
            "displayName": receipt.displayName,
            "bytes": receipt.byteCount,
            "sha256": receipt.sha256,
            "path": receipt.relativePath,
        ]
    }

    static func originalSavePayload(_ outcome: OfficeEditOriginalSaveOutcome) -> [String: Any] {
        var payload: [String: Any] = ["local": outcome.local.rawValue, "provider": outcome.provider.rawValue]
        if let sha = outcome.committedSHA256 { payload["committedSHA256"] = sha }
        if outcome.committedBytes > 0 { payload["committedBytes"] = outcome.committedBytes }
        if let token = outcome.localToken { payload["localToken"] = token }
        if let token = outcome.providerToken { payload["providerToken"] = token }
        if let recovery = outcome.recoveryID { payload["recoveryID"] = recovery }
        if let detail = outcome.detail { payload["detail"] = detail }
        if outcome.isPartial {
            payload["note"] = "The workspace original now carries the edit, but the provider push did "
                + "NOT complete. The recoverable copies remain; inspect and retry the push explicitly — "
                + "the document edit itself was not replayed."
        } else if outcome.hasRecoverableState, !outcome.isFullSuccess {
            payload["note"] = "The original was NOT fully replaced; recoverable copies are retained and "
                + "nothing was discarded."
        }
        return payload
    }

    static func refusalPayload(stage: String, result: OfficeEditCommandResult,
                               contextID: String) -> [String: Any] {
        var payload: [String: Any] = [
            "status": "refused", "stage": stage, "engineState": result.state.rawValue,
            "editContext": contextID,
        ]
        if let failure = result.failureCode { payload["failure"] = failure }
        if let detail = result.detail { payload["detail"] = detail }
        return payload
    }

    static func refusalPayloadFromContent(_ outcome: OfficeEditContentOutcome) -> [String: Any] {
        var payload: [String: Any] = [
            "status": outcome.result.state == .unknown ? "unknown" : "refused",
            "stage": "apply", "engineState": outcome.result.state.rawValue,
            "flushState": outcome.flush.state.rawValue,
        ]
        if let failure = outcome.result.failureCode { payload["failure"] = failure }
        if let detail = outcome.result.detail { payload["detail"] = detail }
        return payload
    }

    /// Declared bounded-output exception (same documented pattern as the
    /// jobs.* envelope): every field above its own bound (selection ≤ 32 KiB
    /// raw, limitations ≤ 8 × bounded, no identifiers truncated), so the only
    /// way the clamp can bite is JSON-escape blow-up, which stays inside the
    /// hard ceiling.
    private func officeOutput(_ payload: [String: Any], exitStatus: Int32 = 0,
                              outputFiles: [RunOutputFile] = [],
                              requiresUserAction: Bool = false) throws -> ToolExecutionOutput {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw FloeError.internalError("office output encoding failed")
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            exitStatus: exitStatus,
            artifacts: [],
            outputFiles: outputFiles,
            requiresUserAction: requiresUserAction,
            maximumSummaryCharacters: 262_144)
    }
}

// MARK: - Supporting extensions

