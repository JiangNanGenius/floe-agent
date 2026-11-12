// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace

struct G04ExternalEditRouting: Sendable {
    let epoch: UInt64
    let isLive: @Sendable () -> Bool
    let resolveOwner: @Sendable (UUID) async -> G04WorkspaceOwner?
    let access: any G04WorkspaceAccessPort
    var mailbox: ExternalEditHostMailbox = .shared
}

struct G04ExternalEditTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let path: String
        let sessionID: String?
        let chooseApplication: Bool?
    }
    static let name = "workspace.externalEdit"
    static let toolDescription = "Open a task workspace file in an installed Android editor using a recoverable copy. Actions: open, status (check actual saved bytes), finish (check and revoke the editor grant), cancel (revoke and retain recovery copies). Supply the same path and returned sessionID for later actions. Opening or returning from an app does NOT mean editing finished. saved is true only after verified file content changed; sourcePending means the attached original still needs saving. For a READ-ONLY preview/import of a task-owned artifact (video, image, PDF, audio, text or calendar .ics), use workspace.artifactHandoff instead; it never grants write access or claims a save. For automated editing, when device tools are available, first call device.observe and resolve screen-handover questions while the owning task is foreground; then open the editor and observe its actual page. UI actions retain the configured approval policy. Returning to Floe for approval invalidates old external node refs: never replay them or assume the editor is still foreground. Do not guess a shared-storage path for the private edit copy or replace its session with an app launcher. Retain the session and report the required handover if its editor is no longer reachable. Check status after a save/return; do not poll in a tight loop. If a foreground handover is required, wait for the user. No URI, task, workspace or environment IDs may be supplied."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["open","status","finish","cancel"]},"path":{"type":"string","minLength":1,"maxLength":1024},"sessionID":{"type":"string","maxLength":36},"chooseApplication":{"type":"boolean"}},"required":["action","path"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    static let isSideEffecting = true
    let routing: G04ExternalEditRouting

    func validate(_ args: Arguments) throws {
        guard ["open", "status", "finish", "cancel"].contains(args.action),
              !args.path.isEmpty, args.path.utf8.count <= 1024,
              args.path.trimmingCharacters(in: .whitespacesAndNewlines) == args.path,
              !args.path.contains("\\"), !args.path.hasPrefix("~"),
              !args.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              args.path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              args.sessionID == nil || args.sessionID.flatMap(UUID.init(uuidString:)) != nil,
              args.action == "open" || args.sessionID != nil,
              args.action == "open" || args.chooseApplication == nil
        else { throw FloeError.validationFailed("Invalid editor action, workspace path or session") }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args); try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly, context.scope == .local,
              context.childExecution == nil, let task = context.conversationID,
              let callID = context.toolCallID, !callID.isEmpty, callID.utf8.count <= 128,
              routing.isLive(), routing.mailbox.isReady(epoch: routing.epoch)
        else { throw FloeError.validationFailed("Open a saved task with an available Android editor service") }
        if let origin = context.callOrigin {
            guard origin.kind == .mainRunDelegate, origin.runID == context.runID,
                  origin.toolName == Self.name, origin.callID == callID else { throw FloeError.cancelled }
        }
        if let names = context.allowedToolNames, !names.contains(Self.name) { throw FloeError.cancelled }
        if let names = context.frozenEffectiveCatalogNames, !names.contains(Self.name) { throw FloeError.cancelled }
        try context.authorizeWorkspacePath(args.path)
        guard let owner = await routing.resolveOwner(task), owner.epoch == routing.epoch else {
            throw FloeError.notFound("This task's workspace is unavailable")
        }
        let lease = try await routing.access.acquire(owner: owner, intent: .fileMutation, relativePath: args.path)
        do {
            try lease.cancellation.throwIfCancelled()
            let root = lease.service.guardResolver.rootURL.standardizedFileURL
            guard let boundRoot = context.workspaceRootURL?.standardizedFileURL.resolvingSymlinksInPath(), boundRoot == root,
                  routing.isLive() else { throw FloeError.validationFailed("The task workspace changed") }
            _ = try lease.service.guardResolver.resolve(args.path)
            try WorkspaceToolEnvironment.designFreezeGate()(lease.service.guardResolver.resolve(args.path))
            var request: [String: Any] = ["action": args.action, "path": args.path,
                "taskID": task.uuidString.lowercased(), "workspaceID": owner.workspaceID.uuidString.lowercased(),
                "runID": context.runID.uuidString.lowercased(), "callID": callID]
            if let id = args.sessionID { request["sessionID"] = id.lowercased() }
            if let chooser = args.chooseApplication { request["chooseApplication"] = chooser }
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            var reply = try await routing.mailbox.submit(epoch: routing.epoch, request: data,
                cancellation: context.cancellation, ownerCancellation: lease.cancellation)
            if args.action == "open", Self.error(reply) == "foregroundRequired" {
                guard let questions = UserQuestionHostAPI.shared.current(epoch: routing.epoch) else {
                    throw FloeError.invalidConfiguration("Open this task to continue with the editor")
                }
                let zh = Locale.current.identifier.lowercased().hasPrefix("zh")
                let draft = UserQuestionDraft(id: "external-editor-foreground",
                    question: zh ? "请打开这个任务，再继续使用外部编辑器。" : "Open this task, then continue with the external editor.",
                    options: [UserQuestionOption(id: "continue", label: zh ? "继续" : "Continue"),
                              UserQuestionOption(id: "cancel", label: zh ? "取消" : "Cancel")], allowsFreeText: false)
                let answer = try await questions.ask(UserQuestionRequest(waitPolicy: .required, questions: [draft]),
                    runID: context.runID, conversationID: task, toolCallID: callID,
                    cancellation: context.cancellation, temporaryReadOnly: false)
                guard answer.status == .answered,
                      answer.answers.first(where: { $0.source == .human })?.selectedOptionIDs == ["continue"]
                else { throw FloeError.cancelled }
                try context.cancellation.throwIfCancelled(); try lease.cancellation.throwIfCancelled()
                guard routing.isLive(), await routing.resolveOwner(task) == owner else { throw FloeError.cancelled }
                // The first host attempt did not launch. A human answer does
                // not bypass the host's same-task/foreground recheck.
                reply = try await routing.mailbox.submit(epoch: routing.epoch, request: data,
                    cancellation: context.cancellation, ownerCancellation: lease.cancellation)
            }
            try context.cancellation.throwIfCancelled(); try lease.cancellation.throwIfCancelled()
            guard routing.isLive(), await routing.resolveOwner(task) == owner else { throw FloeError.cancelled }
            await lease.release()
            let value = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            return ToolExecutionOutput(digesting: String(decoding: reply, as: UTF8.self),
                exitStatus: value?["ok"] as? Bool == true ? 0 : 1)
        } catch { await lease.release(); throw error }
    }
    private static func error(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
    }
    static func install(routing: G04ExternalEditRouting, registry: ToolRunnerRegistry = .shared) {
        ToolCatalog.register(Self.self)
        registry.register(AnyAgentTool(Self(routing: routing)).withAvailability {
            routing.isLive() && routing.mailbox.isReady(epoch: routing.epoch)
        })
        // The read-only artifact handoff is installed at the SAME composition
        // point because it shares the one ExternalEditHostMailbox/pump and the
        // identical task/root epoch/resolveOwner/access authority. It is a
        // distinct tool and record lane: no write grant, no edit/save claim.
        G04ArtifactHandoffTool.install(routing: G04ArtifactHandoffRouting(
            epoch: routing.epoch,
            isLive: routing.isLive,
            resolveOwner: routing.resolveOwner,
            access: routing.access,
            mailbox: routing.mailbox), registry: registry)
    }
}
