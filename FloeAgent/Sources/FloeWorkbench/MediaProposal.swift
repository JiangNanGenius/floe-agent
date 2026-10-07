// FloeWorkbench — AI proposal validation.
//
// Proposals are the ONLY way the model-facing tool changes a project. A
// proposal binds the exact revision it was prepared against and a validated
// command sequence. The UI previews it; applying requires a trusted grant
// from `MediaProposalGrantStore` (issued only by the interactive UI after
// the user accepts). A Codable value in a tool request is never authority.
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

public enum MediaProposalGate {
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
