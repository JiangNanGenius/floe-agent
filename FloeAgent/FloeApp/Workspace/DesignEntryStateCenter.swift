// FloeApp — Design entry state center (observable, derived from durable truth).
//
// One shared, testable derivation of WHAT design entry a conversation may
// show right now — computed from REAL state only:
//   - the durable launch binding (DesignLaunchBindingStore, on disk),
//   - the durable owner envelope (ArtifactDesignOwnerStore via the shared
//     workflow — real retained artifacts/candidates, restored after relaunch),
//   - the real family capability registry.
// Never from "a binding exists" alone, never from a mark-only in-memory set.
//
// The center PUBLISHES per-conversation presentations, so the thread toolbar
// (and any future surface) updates live when runs end, candidates resolve or
// restore finishes — no chicken-and-egg with opening the design page.
//
// Semantics (user-steered 2026-10-14): ordinary Q&A gets no entry; a
// conversation OWNING a design binding is an explicit design task (bindings
// are only created by explicit file/attachment/creative design actions) and
// gets the workbench entry once its target is real; a creative create task
// stays conversation-first until the durable envelope holds a real artifact;
// results/notifications/restore never auto-open anything.

import Foundation
import FloeCore

@MainActor
final class DesignEntryStateCenter: ObservableObject {
    /// The latest presentation per conversation (absent = not yet assessed).
    @Published private(set) var presentations: [UUID: DesignEntryPresentation] = [:]

    func presentation(for conversationID: UUID) -> DesignEntryPresentation? {
        presentations[conversationID]
    }

    /// Recomputes one conversation from durable state. Callers: launch
    /// reload, task launch, run start/end, design decisions, restores.
    func refresh(conversationID: UUID, environment: AppEnvironment) async {
        let assessment = await derive(
            conversationID: conversationID, environment: environment)
        presentations[conversationID] = assessment.presentation
    }

    func refreshAll(conversationIDs: [UUID], environment: AppEnvironment) async {
        for id in conversationIDs {
            await refresh(conversationID: id, environment: environment)
        }
    }

    func clear(conversationID: UUID) {
        presentations.removeValue(forKey: conversationID)
    }

    /// The shared derivation — pure inputs, testable through real stores.
    func derive(
        conversationID: UUID,
        environment: AppEnvironment
    ) async -> DesignEntryAssessment {
        guard let binding = DesignLaunchBindingStore.load(conversationID: conversationID) else {
            // Ordinary chat/Q&A — no durable design ownership at all.
            return DesignEntryPolicy.assess(
                intent: .ordinaryQA,
                hasRealTarget: false,
                capabilityConnected: false,
                hasPreviewableArtifact: false,
                hasPendingCandidate: false)
        }
        // Durable envelope truth (survives relaunch; nil when the source is
        // gone — a deleted attachment/missing file means NO real target).
        let envelope = try? await environment.designOwnerWorkflow.state(binding.target)
        let hasArtifact = envelope?.project.artifacts.isEmpty == false
        let hasPending = envelope?.project.candidates.contains { $0.status == .pending } == true
        let artifact = envelope?.project.artifacts.first
        let family: DesignContentType = artifact?.contentType
            ?? binding.target.requestedOutputKind
            ?? .webpage
        // PREVIEW-presentability truth (separate from generation/edit): the
        // entry exists only when the retained artifact can really be shown
        // through an in-page branch or the existing professional handoff.
        // Unknown binary formats and CAD attachments (no workspace file)
        // are precise unsupported states — never a faked connected entry.
        let currentRevisionID = artifact?.currentRevisionID
            ?? envelope?.project.candidates.first(where: { $0.status == .pending })?.proposedRevisionID
        let format = (currentRevisionID.flatMap { artifact?.revision($0)?.payloadFormat })
            ?? artifact?.revisions.last?.payloadFormat
            ?? ""
        let preview = DesignPreviewPresentation.assess(
            contentType: family, format: format,
            isFileTarget: binding.target.kind == .fileDocument)
        let capabilityConnected: Bool
        switch preview {
        case .presentable: capabilityConnected = true
        case .unsupported: capabilityConnected = false
        }
        // Target reality: file targets were verified at launch (the freeze
        // establishment fail-closed); attachments/creative targets must prove
        // themselves through the durable envelope (real bytes now).
        let hasRealTarget: Bool
        switch binding.target.kind {
        case .fileDocument:
            hasRealTarget = true
        case .chatAttachment, .creativeDocument:
            // Attachments/creative targets must prove themselves through the
            // durable envelope (real retained bytes now).
            hasRealTarget = hasArtifact
        case .canvasNode:
            // Canvas nodes are not a chat workbench entry.
            hasRealTarget = false
        }
        // Intent is DERIVED, never hardcoded to interactive: owning a binding
        // means an explicit design TASK (created only by explicit design
        // actions), but the DEFAULT delivery still runs the original
        // make/modify flow — the entry becomes a lightweight "查看成果"
        // once the durable envelope holds a real artifact. The workbench
        // opens only when the USER clicks (or a future high-confidence
        // surface upgrades the intent).
        var assessment = DesignEntryPolicy.assess(
            intent: .singleShotMakeOrModify,
            hasRealTarget: hasRealTarget,
            capabilityConnected: capabilityConnected,
            hasPreviewableArtifact: hasArtifact,
            hasPendingCandidate: hasPending)
        if case .unsupported(let reason) = preview {
            assessment.trace.append("previewUnsupported: \(reason)")
        }
        return assessment
    }
}
