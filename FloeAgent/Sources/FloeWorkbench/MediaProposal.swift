// FloeWorkbench — AI proposal validation.
//
// Proposals are the ONLY way the model-facing tool changes a project. A
// proposal binds the exact revision it was prepared against and a validated
// command sequence. A model-supplied Codable value is never authority. There
// are exactly two apply paths:
//
//   * INTERACTIVE: the UI previews the proposal and the user accepts it; the
//     single-use, revision-bound grant from `MediaProposalGrantStore` is the
//     only key that commits through `applyAuthorized`.
//   * RUNTIME-AUTHORIZED AUTOMATIC: an `apply` without `grant_id` consumes
//     the runtime-issued authority for that exact approved `media.project`
//     call (`MediaProposalGate.applyAutomatic`, which re-checks tool,
//     operation, proposal, base revision, canonical target and commands
//     digest) — or, when the submission was deferred through an authorized
//     `jobs.submit` call, the frozen service operation prepared from that
//     consumed submission authority.
//
// Manual edits — including undo/redo, which always advance the revision —
// invalidate a pending proposal, and the grant store then refuses apply.

import Foundation
import FloeCore

public struct MediaProposal: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    /// Revision the commands were prepared against.
    public var baseRevision: Int64
    public var summary: String
    public var commands: [MediaEditCommand]
    public var createdAt: Date
    /// Provenance: model id that produced the proposal (no prompts/logs).
    public var modelID: String?

    public init(id: UUID = UUID(), projectID: UUID, baseRevision: Int64, summary: String,
                commands: [MediaEditCommand], createdAt: Date = Date(), modelID: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.baseRevision = baseRevision
        self.summary = summary
        self.commands = commands
        self.createdAt = createdAt
        self.modelID = modelID
    }
}

public enum MediaProposalError: Error, Sendable, Equatable {
    case stale(String)
    case invalid(String)
    case notAuthorized(String)
}

/// Proof that the runtime approved this exact `media.project` apply call and
/// the consumer claimed its single-use authority. Built ONLY by
/// `MediaProjectTool.apply` after `consumeRuntimeAuthority` returned `.valid`
/// for the call's own binding; never reconstructed from model output.
public struct MediaAutomaticAuthorization: Sendable, Equatable {
    public var runID: UUID
    public var taskID: UUID?
    public var operationID: String
    public var idempotencyKey: String
    public var approvalGrantID: UUID?
    /// Canonical target exactly as the runtime resolved it for the approved
    /// call (the workspace wildcard for this tool, or an explicit document
    /// target when the caller supplied one).
    public var canonicalTarget: String
    /// Revision the project had when the authority was consumed.
    public var baseRevision: Int64
    /// Digest of the approved tool-call payload.
    public var payloadDigest: String
    /// Digest of the concrete proposal commands this authorization covers.
    public var commandsDigest: String
    public var proposalID: UUID
    public var toolName: String
    public var operation: String
    public var consumedAt: Date

    public init(runID: UUID, taskID: UUID?, operationID: String, idempotencyKey: String,
                approvalGrantID: UUID?, canonicalTarget: String, baseRevision: Int64,
                payloadDigest: String, commandsDigest: String, proposalID: UUID,
                toolName: String = "media.project", operation: String = "apply",
                consumedAt: Date = Date()) {
        self.runID = runID
        self.taskID = taskID
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.approvalGrantID = approvalGrantID
        self.canonicalTarget = canonicalTarget
        self.baseRevision = baseRevision
        self.payloadDigest = payloadDigest
        self.commandsDigest = commandsDigest
        self.proposalID = proposalID
        self.toolName = toolName
        self.operation = operation
        self.consumedAt = consumedAt
    }
}

public enum MediaProposalGate {
    /// Canonical digest of one validated command sequence, shared by the tool
    /// (which builds the authorization) and the gate (which re-checks it).
    public static func commandsDigest(_ commands: [MediaEditCommand]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(commands) else { return "" }
        return FloeDigest.sha256Hex(data)
    }

    /// Validates the proposal and produces the resulting DRAFT project
    /// without mutating anything. Used both for UI preview and before the
    /// trusted grant is consumed.
    @discardableResult
    public static func dryRun(_ proposal: MediaProposal, against project: MediaProject) throws -> MediaProject {
        guard proposal.projectID == project.id else {
            throw MediaProposalError.invalid("proposal belongs to a different project")
        }
        guard proposal.baseRevision == project.revision else {
            throw MediaProposalError.stale("Project changed since this proposal was prepared (revision \(project.revision), proposal based on \(proposal.baseRevision)). Review and prepare the proposal again.")
        }
        var draft = project
        for command in proposal.commands {
            do {
                try MediaEditCommandApplier.apply(command, to: &draft)
            } catch let error as MediaCommandError {
                throw MediaProposalError.invalid(String(describing: error))
            }
        }
        return draft
    }

    /// Preview validation only (no draft returned across the actor boundary
    /// convenience wrapper).
    public static func preview(_ proposal: MediaProposal, against project: MediaProject) throws {
        _ = try dryRun(proposal, against: project)
    }

    /// Applies an authorized proposal as ONE draft-then-commit transaction.
    /// The caller must have consumed a trusted grant from
    /// `MediaProposalGrantStore`; a Codable value supplied by the model is not
    /// authority. Revision is re-validated here; on any failure the passed
    /// project is left unchanged (no partial edits).
    public static func applyAuthorized(
        _ proposal: MediaProposal,
        grant: MediaGrantDecision,
        to project: inout MediaProject
    ) throws {
        guard grant == .authorized else {
            throw MediaProposalError.notAuthorized("User confirmation is required before applying a proposal.")
        }
        _ = try dryRun(proposal, against: project)
        try MediaTransactions.apply(proposal.commands, to: &project)
    }

    /// Applies a proposal under a runtime-issued automatic authorization. The
    /// authorization was built by the tool after `consumeRuntimeAuthority`
    /// returned `.valid` for the approved call; this gate re-checks every
    /// project-scoped field against the real current project so a mismatched
    /// or stale proof can never mutate a different project or revision.
    public static func applyAutomatic(
        _ proposal: MediaProposal,
        authorization: MediaAutomaticAuthorization,
        to project: inout MediaProject
    ) throws {
        guard authorization.toolName == MediaProjectTool.name,
              authorization.operation == "apply" else {
            throw MediaProposalError.notAuthorized(
                "the authorization is not bound to a media.project apply operation")
        }
        guard authorization.proposalID == proposal.id else {
            throw MediaProposalError.notAuthorized("the authorization was issued for a different proposal")
        }
        guard authorization.baseRevision == project.revision else {
            throw MediaProposalError.stale(
                "the authorization was issued for revision \(authorization.baseRevision), the project is at \(project.revision)")
        }
        guard !authorization.payloadDigest.isEmpty else {
            throw MediaProposalError.notAuthorized("the authorization carries no approved payload digest")
        }
        guard authorization.commandsDigest == commandsDigest(proposal.commands),
              !authorization.commandsDigest.isEmpty else {
            throw MediaProposalError.notAuthorized(
                "the authorization does not match this proposal's commands")
        }
        if authorization.canonicalTarget.hasPrefix("document:") {
            guard authorization.canonicalTarget == "document:mediaproject:\(project.id.uuidString.lowercased())" else {
                throw MediaProposalError.notAuthorized(
                    "the authorization targets a different media project")
            }
        } else if !authorization.canonicalTarget.hasPrefix("workspace:") {
            throw MediaProposalError.notAuthorized(
                "the authorization target is not a workspace or media-project identity")
        }
        _ = try dryRun(proposal, against: project)
        try MediaTransactions.apply(proposal.commands, to: &project)
    }
}

/// Reopen/verification helpers for the automatic apply path. These read the
/// real reopened project; they never synthesize a success.
public enum MediaAutomaticVerification {
    /// Canonical content digest of a persisted project (sorted-key JSON of the
    /// actual reopened value). Used as the immutable snapshot identity of the
    /// applied revision; a byte-level store digest is host-owned and private.
    public static func canonicalProjectDigest(_ project: MediaProject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(project) else { return "" }
        return FloeDigest.sha256Hex(data)
    }

    /// Referenced source assets and their recorded content hashes. Automatic
    /// apply must only reference assets, never replace or rewrite them, so the
    /// pair set is unchanged across an apply.
    public static func assetHashes(_ project: MediaProject) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0.contentHash ?? "") })
    }
}

// MARK: - Export validation
public enum MediaExportValidation {
    /// Validates explicit image export combinations. Transparency on JPEG is
    /// rejected (not silently flattened); PNG/HEIC alpha is supported.
    public static func validateImage(_ options: ImageExportOptions, canvasSize: CGSizeLike?,
                                     hasTransparency: Bool) throws {
        if options.format == .jpeg && options.preserveTransparency && hasTransparency {
            throw FloeError.validationFailed("JPEG cannot preserve transparency. Choose PNG/HEIC or turn off transparency to flatten onto an opaque background.")
        }
        guard options.quality.isFinite, (0.01...1).contains(options.quality) else {
            throw FloeError.validationFailed("Export quality must be 0.01...1")
        }
        if (options.width == nil) != (options.height == nil) {
            throw FloeError.validationFailed("Provide both export dimensions or neither")
        }
        if let width = options.width, let height = options.height {
            guard width >= 2, height >= 2, width <= 16384, height <= 16384 else {
                throw FloeError.validationFailed("Export dimensions must be 2...16384 px")
            }
        }
        _ = canvasSize
    }

    public static func validateVideo(_ options: VideoExportOptions, timeline: VideoTimeline) throws {
        guard options.width >= 2, options.height >= 2, options.width <= 8192, options.height <= 8192,
              options.width % 2 == 0, options.height % 2 == 0 else {
            throw FloeError.validationFailed("Video dimensions must be even and 2...8192 px")
        }
        guard options.frameRate.isFinite, options.frameRate > 0, options.frameRate <= 240 else {
            throw FloeError.validationFailed("Frame rate must be in (0, 240]")
        }
        guard options.quality.isFinite, (0.01...1).contains(options.quality) else {
            throw FloeError.validationFailed("Export quality must be 0.01...1")
        }
        guard !timeline.clips.isEmpty else {
            throw FloeError.validationFailed("Add at least one clip before exporting")
        }
        for caption in timeline.captions where caption.end > timeline.primaryDuration + 0.05 {
            throw FloeError.validationFailed("Caption ending at \(String(format: "%.2f", caption.end))s exceeds the \(String(format: "%.2f", timeline.primaryDuration))s timeline")
        }
        for music in timeline.music where music.offsetSeconds > timeline.primaryDuration + 0.05 {
            throw FloeError.validationFailed("A music clip starts after the video ends")
        }
    }
}

/// Platform-independent size carrier.
public struct CGSizeLike: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}
