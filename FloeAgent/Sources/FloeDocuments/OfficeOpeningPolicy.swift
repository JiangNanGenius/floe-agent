// FloeDocuments — bounded, recoverable Office opening contract.
//
// The App's visible-render gate (`OfficeVisibleRenderGate`) answers one narrow
// question: *did the pinned engine host observe a real paint of this document?*
// Presentations must answer yes before the surface may claim a rendered editor,
// because the mobile engine paints its loading layout before any slide content
// exists.
//
// This policy answers the question that follows: what does the *user* get
// while that observation is pending, and what happens when it never arrives?
// Build 221 answered "a terminal error", which is how a presentation that the
// engine does not repaint on the device ends up stuck on the opening state with
// no way forward (the reported Build 221 PPT/PPTX failure). The contract here is
// deliberately bounded and recoverable:
//
//   - Word/Excel and every other format settle ready when the engine open
//     settles; the existing open-only contract is unchanged;
//   - a presentation waits, bounded, for the visible-render observation;
//   - when that bound elapses the session is `renderUnverified`: the mounted
//     engine surface stays usable and the surface shows a visible, recoverable
//     notice with retry/recovery. It never hangs and never dead-ends;
//   - a late render observation still settles the session fully ready, so a
//     genuinely slow paint is never turned into a failure;
//   - an open that never settles at all is `failed` with the retained-copy
//     copy and recovery actions (the only terminal outcome).
//
// The budgets live here so the App and the tests share one source. They are
// deliberately at or above the pinned host's own probe deadline (20 s preview /
// 25 s editable), so the host's honest render report always wins and this
// App-side bound only covers a host callback chain that stalls (the App's
// timer never depends on a host callback).

import Foundation

/// The user-facing outcome of one bounded Office opening attempt.
public enum OfficeOpeningOutcome: Equatable, Sendable {
    /// Still bounded and in progress: the surface keeps its opening state.
    case waiting
    /// Fully settled: documents on open, presentations on first paint.
    case ready
    /// Settled without the visible-render observation. The engine surface is
    /// usable and the user gets a recoverable notice; nothing claims a paint.
    case renderUnverified
    /// The open itself never settled. Visible, recoverable error with the
    /// retained editing copy.
    case failed
}

/// Visible, recoverable notice for a bounded opening outcome. Both languages
/// are carried so the owning surface can render the user's language without the
/// document layer depending on the App's localization helper.
public struct OfficeOpeningWarning: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        /// Re-open a truthful preview of the retained working copy.
        case retryPreview
        /// Tear the session down and re-open the retained working copy.
        case recover
        /// Hide the notice and keep the current surface.
        case dismiss
    }

    public let titleZh: String
    public let titleEn: String
    public let detailZh: String
    public let detailEn: String
    public let actions: [Action]
}

/// Bounded opening policy for one mounted Office session.
public struct OfficeOpeningPolicy: Equatable, Sendable {
    /// The first-intent semantics of the three owning entry paths. The paths
    /// share one session contract; only the first intent (preview vs explicit
    /// edit) and therefore the budget differ.
    public enum Intent: String, CaseIterable, Sendable {
        /// Workspace file inspector / preview surface: read-only first.
        case workspacePreview
        /// Workspace or IDE explicit edit entry.
        case workspaceEdit
        /// IDE internal Office tab.
        case ideTab
        /// Notes surface whose remembered mode resolved to preview.
        case notesPreview
        /// Notes surface whose remembered mode resolved to edit.
        case notesEdit
    }

    /// Formats whose renderer starts in the engine's file-based viewing layout,
    /// where page skeletons are painted before any document tile exists. Mirrors
    /// `OfficeRenderRequirement.renderRequiredExtensions` in
    /// `FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift` and
    /// `FloeDocumentRequiresVisibleRender` in
    /// `FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm`.
    /// A focused test asserts all three lists stay identical.
    public static let presentationExtensions: Set<String> = [
        "ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx",
        "odp", "otp", "fodp", "odg", "otg", "fodg",
    ]

    public static func requiresVisibleRender(pathExtension: String) -> Bool {
        presentationExtensions.contains(pathExtension.lowercased())
    }

    public let requiresVisibleRender: Bool
    public let readOnly: Bool
    public private(set) var outcome: OfficeOpeningOutcome = .waiting

    public init(requiresVisibleRender: Bool, readOnly: Bool) {
        self.requiresVisibleRender = requiresVisibleRender
        self.readOnly = readOnly
    }

    public init(intent: Intent, pathExtension: String) {
        self.init(requiresVisibleRender: Self.requiresVisibleRender(pathExtension: pathExtension),
                  readOnly: Self.startsReadOnly(intent))
    }

    /// Whether this entry path's first intent opens a read-only preview.
    public static func startsReadOnly(_ intent: Intent) -> Bool {
        switch intent {
        case .workspacePreview, .notesPreview: true
        case .workspaceEdit, .ideTab, .notesEdit: false
        }
    }

    /// Bounded wait for the engine open (and its permission report) to settle.
    /// Covers a mounted controller whose host callback chain never reports.
    public var openingBudget: TimeInterval { readOnly ? 30 : 45 }

    /// Bounded wait for the first visible render after the open settled. Kept
    /// above the pinned host's own deadline (20 s preview / 25 s editable) so
    /// the host's render report always lands before this safety net.
    public var renderBudget: TimeInterval { readOnly ? 25 : 30 }

    /// The engine open (and the engine's own permission report) settled.
    @discardableResult
    public mutating func openSettled() -> OfficeOpeningOutcome {
        guard outcome == .waiting else { return outcome }
        if !requiresVisibleRender { outcome = .ready }
        return outcome
    }

    /// The host observed a real paint. A late observation always wins; a
    /// settled `renderUnverified` session becomes fully ready again.
    @discardableResult
    public mutating func renderObserved() -> OfficeOpeningOutcome {
        outcome = .ready
        return outcome
    }

    /// The bounded render wait elapsed with no visible-render evidence.
    /// Presentations become recoverable-in-place; other formats never wait.
    @discardableResult
    public mutating func renderDeadlineElapsed() -> OfficeOpeningOutcome {
        guard outcome == .waiting else { return outcome }
        outcome = requiresVisibleRender ? .renderUnverified : .ready
        return outcome
    }

    /// The bounded opening wait elapsed: the open never settled.
    @discardableResult
    public mutating func openingDeadlineElapsed() -> OfficeOpeningOutcome {
        guard outcome == .waiting else { return outcome }
        outcome = .failed
        return outcome
    }

    /// True once no further bounded transition is possible without a new open.
    public var isSettled: Bool { outcome != .waiting }

    /// The visible, recoverable notice for a settled outcome, if any.
    public var warning: OfficeOpeningWarning? {
        switch outcome {
        case .waiting, .ready:
            return nil
        case .renderUnverified:
            return OfficeOpeningWarning(
                titleZh: "演示文稿尚未完成首次渲染",
                titleEn: "Presentation Render Not Verified",
                detailZh: readOnly
                    ? "编辑副本已保留：可重试预览，或从“保留的文档”恢复。"
                    : "编辑副本已保留：可重试预览，或恢复编辑副本；保存前请确认页面内容。",
                detailEn: readOnly
                    ? "Your editing copy was retained; retry the preview, or recover it under Retained Documents."
                    : "Your editing copy was retained; retry the preview or recover the editing copy. Confirm the slides before saving.",
                actions: [.retryPreview, .dismiss])
        case .failed:
            return OfficeOpeningWarning(
                titleZh: "文档引擎未能在限定时间内打开文档",
                titleEn: "The Document Did Not Open In Time",
                detailZh: "编辑副本已保留：可重试，或从“保留的文档”恢复。",
                detailEn: "Your editing copy was retained; retry, or recover it under Retained Documents.",
                actions: [.recover])
        }
    }
}
