// FloeApp — Design entry policy (shared, testable display/activation truth).
//
// The user-facing rule set for WHEN a design entry may appear and WHAT it
// may offer. One evaluator, many callers: the thread toolbar, the
// lightweight result entry, the work-mode presentation, and the tests all
// read the SAME decision so no surface can drift.
//
// Rules (user-steered 2026-10-14):
// - Ordinary Q&A / explain / summarize / diagnose / status queries get NO
//   design entry — not for being inside the creative surface, not for
//   attachments, not for keywords, not for an empty binding.
// - Default delivery runs the ALREADY-AUTHORIZED make/modify workflow to a
//   real artifact. Interaction is recognized only from HIGH-confidence
//   context (the user views the real artifact and keeps adjusting concrete
//   visible areas, asks to edit while viewing, or asks to compare options).
//   Plain "make a webpage" / "change this content" is NOT enough.
// - Low confidence yields a NON-BLOCKING lightweight hint only — never a
//   popup, never a forced mode choice.
// - A lightweight "查看成果" entry may appear only AFTER the model
//   established a design task with a REAL previewable artifact; results,
//   notifications, conversation switches and restores never auto-open it or
//   steal focus. Opening the workbench is always a user action.
// - Presentation records intent, target reality, capability and artifact
//   state — never "a binding exists".

import Foundation
import FloeCore

/// Classified user intent for the design surface.
enum DesignInteractionIntent: String, Sendable, Equatable {
    /// 问答/解释/总结附件/诊断错误/查询状态 — never shows design entries.
    case ordinaryQA
    /// 单次制作/修改内容 — the DEFAULT flow completes the artifact.
    case singleShotMakeOrModify
    /// 高置信度交互信号：查看真实成果后持续针对具体可见位置调整、
    /// 边看边改、比较方案。
    case highConfidenceInteractive
    /// 明确要求交互预览/逐步调整/打开工作台。
    case explicitInteractive
}

/// What the UI may present for one conversation/task right now.
enum DesignEntryPresentation: String, Sendable, Equatable {
    /// No entry at all.
    case none
    /// 低置信度：非阻塞轻量提示（不弹窗、不强制模式选择）。
    case lightweightHint
    /// 轻量"查看成果"入口/结果卡片（仅已有真实可预览成果）。
    case viewArtifactEntry
    /// 交互工作台入口（仍由用户点击打开，绝不自动弹出）。
    case openWorkbench
}

struct DesignEntryAssessment: Sendable, Equatable {
    var presentation: DesignEntryPresentation
    /// The recorded reasoning (intent / target / capability / artifact).
    var trace: [String]
}

enum DesignEntryPolicy {
    /// One shared decision. `hasRealTarget`: a concrete file/attachment/
    /// creative target the design services can actually address (never a
    /// vague or empty binding). `capabilityConnected`: the family/operation
    /// is really wired for this target. `hasPreviewableArtifact`: the owner
    /// envelope holds real retained bytes for the current or a candidate
    /// revision. `lowConfidenceInteractionSignal`: weak "maybe interactive"
    /// context (never enough alone to open anything).
    static func assess(
        intent: DesignInteractionIntent,
        hasRealTarget: Bool,
        capabilityConnected: Bool,
        hasPreviewableArtifact: Bool,
        hasPendingCandidate: Bool,
        lowConfidenceInteractionSignal: Bool = false
    ) -> DesignEntryAssessment {
        var trace: [String] = ["intent=\(intent.rawValue)"]
        trace.append("realTarget=\(hasRealTarget)")
        trace.append("capability=\(capabilityConnected)")
        trace.append("artifact=\(hasPreviewableArtifact)")
        trace.append("pendingCandidate=\(hasPendingCandidate)")

        guard hasRealTarget, capabilityConnected else {
            trace.append("decision=none (no real target or capability not connected)")
            return DesignEntryAssessment(presentation: .none, trace: trace)
        }
        switch intent {
        case .ordinaryQA:
            trace.append("decision=none (ordinary Q&A never shows a design entry)")
            return DesignEntryAssessment(presentation: .none, trace: trace)
        case .singleShotMakeOrModify:
            if hasPreviewableArtifact || hasPendingCandidate {
                trace.append("decision=viewArtifactEntry (default flow completed a real artifact)")
                return DesignEntryAssessment(presentation: .viewArtifactEntry, trace: trace)
            }
            if lowConfidenceInteractionSignal {
                trace.append("decision=lightweightHint (low-confidence signal, non-blocking)")
                return DesignEntryAssessment(presentation: .lightweightHint, trace: trace)
            }
            trace.append("decision=none (default make/modify flow, nothing to view yet)")
            return DesignEntryAssessment(presentation: .none, trace: trace)
        case .highConfidenceInteractive, .explicitInteractive:
            trace.append("decision=openWorkbench (high-confidence interaction; user still clicks to open)")
            return DesignEntryAssessment(presentation: .openWorkbench, trace: trace)
        }
    }
}


/// Preview-presentability truth for the design page: SEPARATE from
/// generation/edit capability. The entry appears only when the retained
/// artifact can really be PRESENTED (a real in-page branch or the existing
/// professional handoff) — a precise unsupported state (unknown binary
/// format, CAD attachment without a workspace file, canvas layout object)
/// never masquerades as connected.
enum DesignPreviewPresentation {
    enum Verdict: Equatable, Sendable {
        case presentable
        case unsupported(reason: String)
    }

    static func assess(
        contentType: DesignContentType,
        format: String,
        isFileTarget: Bool
    ) -> Verdict {
        let format = format.lowercased()
        switch contentType {
        case .image:
            let decodable: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg"]
            return decodable.contains(format)
                ? .presentable
                : .unsupported(reason: "image format '\(format)' has no connected preview path")
        case .video:
            let playable: Set<String> = ["mp4", "mov", "m4v"]
            return playable.contains(format)
                ? .presentable
                : .unsupported(reason: "video format '\(format)' has no connected player")
        case .webpage, .prototype:
            let renderable: Set<String> = ["html", "htm", "xhtml", "svg", "json", "txt", "md"]
            return renderable.contains(format)
                ? .presentable
                : .unsupported(reason: "web artifact format '\(format)' has no connected renderer")
        case .pdf:
            return .presentable // Quick Look system renderer (accepted platform path)
        case .presentation, .officeDocument:
            let office: Set<String> = ["pptx", "docx", "xlsx", "ppt", "doc", "xls"]
            return office.contains(format)
                ? .presentable
                : .unsupported(reason: "office format '\(format)' has no connected preview or editor handoff")
        case .notes:
            return .presentable // retained text renders inline
        case .cad:
            // No in-page CAD renderer: the entry is real ONLY through the
            // specialized workbench handoff, which needs a workspace file.
            guard isFileTarget else {
                return .unsupported(reason: "CAD artifacts preview through the specialized workbench, which needs a workspace file target")
            }
            let cad: Set<String> = ["floecad", "step", "stp", "iges", "igs", "stl", "obj", "glb", "gltf"]
            return cad.contains(format)
                ? .presentable
                : .unsupported(reason: "CAD format '\(format)' is not one the workbench opens")
        case .composition:
            return .unsupported(reason: "canvas layout objects preview on the canvas, not in the design workbench")
        }
    }
}
