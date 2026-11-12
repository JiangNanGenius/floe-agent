// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace

/// Read-only counterpart of `workspace.externalEdit`.
///
/// It hands ONE task-owned artifact to ONE explicitly resolved, installed
/// Android handler:
///  * `workspace` source: an existing task workspace file (the Linux
///    deliverables live here), read through the original guarded workspace
///    service and staged as a verified copy;
///  * `output` source: this run's native-sealed run output, read through the
///    existing verified egress lane (never a model path).
///
/// The Android host copies the verified bytes into the App's own FileProvider
/// and launches `ACTION_VIEW` with a READ-ONLY grant. No Downloads write, no
/// broad storage permission, no operator chooser. An accepted launch is not a
/// completed view, edit or calendar import: `saved`/`completed` stay false and
/// the model must observe/read back the real target UI under the existing
/// Device grants.
struct G04ArtifactHandoffRouting: Sendable {
    let epoch: UInt64
    let isLive: @Sendable () -> Bool
    let resolveOwner: @Sendable (UUID) async -> G04WorkspaceOwner?
    let access: any G04WorkspaceAccessPort
    var mailbox: ExternalEditHostMailbox = .shared
}

struct G04ArtifactHandoffTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let source: String
        let path: String?
        let outputID: String?
        let sessionID: String?
        let targetPackage: String?
        let targetComponent: String?
    }

    static let name = "workspace.artifactHandoff"
    static let toolDescription = "Show a task-owned artifact in an installed, user-approved Android viewer or importer without exporting it through Downloads. Sources: workspace (a task workspace-relative file) or output (this run's published outputID). Actions: targets (list exact installed handlers and MIME; no launch), open (stage a verified read-only copy and launch one explicit permitted target), status, finish (revoke the read grant and remove the App copy), cancel. Supply the same source/path (or outputID) and returned sessionID for later actions. If open returns targetRequired, choose one exact component from targets; never use an Android chooser, app launcher, Downloads export or shell path. When this task is visible, open uses the ordinary foreground route; when Floe is backgrounded (for example a viewer is already foreground), open uses this task's already-armed device authorization to start only the typed read-only VIEW. If it returns deviceArmRequired, call device.observe for this task (or ask the user for the missing Settings > Device setup) and retry with the returned sessionID; do not create broader grants. Respect stoppedByUser, humanTakeover, deviceLocked and devicePausedByUser. foregroundRequired means this task is not the visible Floe conversation: bring it forward and retry. launchUnconfirmed means the OS launch outcome is unknown: observe the target, never repeat open; status/finish/cancel are the safe paths. launchState=accepted means only that the OS accepted the start. viewerState=visible means the target window was actually observed in the foreground, which is still NOT proof that the viewer decoded, played or imported anything; viewerState=notVisible means an ordinary different window was foreground instead; viewerState=unknown means the check could not attribute the page. If viewerState is notVisible, do not repeat open: observe the device, then finish this session before trying another installed target. A launched viewer/importer is NOT a completed view, edit or calendar save: observe the real target page, read back the saved item, then finish. Read-only handoff never grants write access to the original artifact."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["targets","open","status","finish","cancel"]},"source":{"type":"string","enum":["workspace","output"],"description":"workspace: a task workspace-relative file. output: this run's native-sealed outputID."},"path":{"type":"string","maxLength":1024,"description":"Workspace-relative path required for source=workspace. It must not be absolute or contain .., \\ or control characters."},"outputID":{"type":"string","maxLength":64,"description":"64-hex native outputID required for source=output. Get it from this run's output record; it cannot grant access to another run."},"sessionID":{"type":"string","maxLength":36,"description":"Returned handoff session UUID; required for status/finish/cancel and to resume an unlaunched open."},"targetPackage":{"type":"string","maxLength":255,"description":"Optional exact installed package from a targets result. If several permitted handlers exist, choose one explicitly."},"targetComponent":{"type":"string","maxLength":512,"description":"Optional exact flattened package/class from a targets result; same package must match targetPackage when both are supplied."}},"required":["action","source"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let routing: G04ArtifactHandoffRouting

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 &&
            path.trimmingCharacters(in: .whitespacesAndNewlines) == path &&
            !path.contains("\\") && !path.hasPrefix("~") &&
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func validOutputID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func validPackage(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.contains(".") &&
            value.unicodeScalars.allSatisfy {
                (33...126).contains(Int($0.value)) && $0.value != 47 && $0.value != 92
            }
    }

    func validate(_ args: Arguments) throws {
        guard ["targets", "open", "status", "finish", "cancel"].contains(args.action),
              ["workspace", "output"].contains(args.source)
        else { throw FloeError.validationFailed("Invalid artifact handoff action or source") }
        switch args.source {
        case "workspace":
            guard let path = args.path, Self.validPath(path), args.outputID == nil else {
                throw FloeError.validationFailed("A workspace handoff needs one valid relative path")
            }
        case "output":
            guard let outputID = args.outputID, Self.validOutputID(outputID), args.path == nil else {
                throw FloeError.validationFailed("An output handoff needs this run's 64-hex outputID")
            }
        default: throw FloeError.validationFailed("Invalid artifact source")
        }
        if let session = args.sessionID, UUID(uuidString: session) == nil {
            throw FloeError.validationFailed("Invalid handoff session")
        }
        if let targetPackage = args.targetPackage, !Self.validPackage(targetPackage) {
            throw FloeError.validationFailed("Invalid target package")
        }
        if let component = args.targetComponent {
            guard (3...512).contains(component.utf8.count), !component.contains("\\"),
                  component.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { throw FloeError.validationFailed("Invalid target component") }
            let pieces = component.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty,
                  Self.validPackage(String(pieces[0])) else {
                throw FloeError.validationFailed("targetComponent must be package/class")
            }
            if let targetPackage = args.targetPackage, targetPackage != String(pieces[0]) {
                throw FloeError.validationFailed("targetPackage and targetComponent disagree")
            }
        }
        if args.action == "targets" {
            guard args.sessionID == nil, args.targetPackage == nil, args.targetComponent == nil else {
                throw FloeError.validationFailed("targets does not accept a session or target")
            }
        } else if args.action == "open" {
            // targetPackage/targetComponent are optional; sessionID resumes a
            // staged record. All are validated above.
        } else {
            guard args.sessionID != nil, args.targetPackage == nil,
                  args.targetComponent == nil else {
                throw FloeError.validationFailed("This action needs the sessionID and no target")
            }
        }
        if args.action == "open", args.targetPackage == nil, args.targetComponent != nil {
            throw FloeError.validationFailed("Supply targetPackage with targetComponent")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args); try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly, context.scope == .local,
              context.childExecution == nil, let task = context.conversationID,
              let callID = context.toolCallID, !callID.isEmpty, callID.utf8.count <= 128,
              routing.isLive(), routing.mailbox.isReady(epoch: routing.epoch)
        else { throw FloeError.validationFailed("Open a saved task with an available Android handoff service") }
        if let origin = context.callOrigin {
            guard origin.kind == .mainRunDelegate, origin.runID == context.runID,
                  origin.toolName == Self.name, origin.callID == callID else {
                throw FloeError.cancelled
            }
        }
        if let names = context.allowedToolNames, !names.contains(Self.name) { throw FloeError.cancelled }
        if let names = context.frozenEffectiveCatalogNames, !names.contains(Self.name) {
            throw FloeError.cancelled
        }
        guard let owner = await routing.resolveOwner(task), owner.epoch == routing.epoch else {
            throw FloeError.notFound("This task's workspace is unavailable")
        }
        // Only targets/open READ the source. status verifies the App-private
        // staged copy; finish/cancel revoke and delete it. Those later actions
        // must not demand a fresh source write/read authority or fail just
        // because the viewer already consumed the staged URI.
        let needsSourceLease = args.source == "workspace" &&
            (args.action == "targets" || args.action == "open")
        if needsSourceLease, let path = args.path {
            try context.authorizeWorkspacePath(path)
        }
        var lease: G04WorkspaceAccessLease?
        do {
            if needsSourceLease, let path = args.path {
                let acquired = try await routing.access.acquire(
                    owner: owner, intent: .read, relativePath: path)
                lease = acquired
                try acquired.cancellation.throwIfCancelled()
                let root = acquired.service.guardResolver.rootURL.standardizedFileURL
                guard let boundRoot = context.workspaceRootURL?.standardizedFileURL
                        .resolvingSymlinksInPath(), boundRoot == root, routing.isLive()
                else { throw FloeError.validationFailed("The task workspace changed") }
                _ = try acquired.service.guardResolver.resolve(path)
            }
            let data = try G04ArtifactHandoffHostAPI.request(
                action: args.action,
                source: args.source,
                path: args.path,
                outputID: args.outputID,
                taskID: task,
                workspaceID: owner.workspaceID,
                runID: context.runID,
                callID: callID,
                sessionID: args.sessionID,
                targetPackage: args.targetPackage,
                targetComponent: args.targetComponent
            )
            let reply = try await routing.mailbox.submit(
                epoch: routing.epoch, request: data, cancellation: context.cancellation,
                ownerCancellation: lease?.cancellation)
            try context.cancellation.throwIfCancelled()
            if let lease { try lease.cancellation.throwIfCancelled() }
            guard routing.isLive(), await routing.resolveOwner(task) == owner else {
                throw FloeError.cancelled
            }
            await lease?.release()
            let value = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            // `accepted` is a real OS start, but a bounded post-dispatch read
            // that observed a different ordinary window is NOT delivery. Keep
            // the structured reply intact and mark the process status
            // non-success so a caller cannot read "open accepted" as "viewer
            // displayed"; finished/cancelled sessions and direct launches
            // (unknown visibility) keep their ordinary status.
            let ok = value?["ok"] as? Bool == true
            let viewerNotVisible = (value?["viewerState"] as? String) == "notVisible"
            return ToolExecutionOutput(
                digesting: String(decoding: reply, as: UTF8.self),
                exitStatus: ok && !viewerNotVisible ? 0 : 1)
        } catch {
            await lease?.release()
            throw error
        }
    }

    static func install(routing: G04ArtifactHandoffRouting, registry: ToolRunnerRegistry = .shared) {
        ToolCatalog.register(Self.self)
        registry.register(AnyAgentTool(Self(routing: routing)).withAvailability {
            routing.isLive() && routing.mailbox.isReady(epoch: routing.epoch)
        })
    }
}
