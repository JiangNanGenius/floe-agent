import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasFlow

/// Injected host service bundle for the canvas editor.
///
/// The UI module never constructs its own persistence, media services or
/// runtime authority: every outward capability arrives through this bundle.
/// Unavailable capabilities stay `nil` and the UI renders an *actionable*
/// missing state (per UI_BRIEF) instead of failing silently.
///
/// Only `documentStore` is mandatory: the editor is document-authoritative
/// and everything else degrades. Conformance types come from
/// `FloeCanvasIntegration` (`CanvasDocumentStore`, `CanvasAssetStore`,
/// `CanvasSourceService`, `CanvasSourceOpening`, `CanvasEditorGateway`,
/// `CanvasEditorForkGateway`, `CanvasAssistantGateway`,
/// `CanvasAssistantProposalGateway`, `CanvasPreviewProviding`,
/// `CanvasResourceLeasing`, `CanvasStepExecutor`).
#if canImport(UIKit)
public struct CanvasEditorServices: Sendable {
    /// Document authority: load / commit / commitDocument / undo / redo.
    public var documentStore: any CanvasDocumentStore
    /// Byte channel for media assets referenced by `CanvasAssetLocator`.
    public var assetStore: (any CanvasAssetStore)?
    /// Live source reads for explicit source refresh.
    public var sourceService: (any CanvasSourceService)?
    /// UI-bound source opening (host resolves what “the original” is).
    public var sourceOpening: (any CanvasSourceOpening)?
    /// Professional editor gateway (image/video/CAD/mind-map child projects).
    public var editorGateway: (any CanvasEditorGateway)?
    /// Explicit fork gateway for professional sub-projects.
    public var editorForkGateway: (any CanvasEditorForkGateway)?
    /// Legacy assistant gateway (selection-aware requests).
    public var assistantGateway: (any CanvasAssistantGateway)?
    /// Proposal gateway returning validated canvas/document batches.
    public var proposalGateway: (any CanvasAssistantProposalGateway)?
    /// Opens the host's existing persisted assistant for this actual
    /// selection. The callback carries context, never tool authority.
    public var openAssistant: (@Sendable (CanvasAssistantRequest?) async throws -> Void)?
    /// Bounded preview bytes for media/PDF thumbnails (never whole-file Data).
    public var previewProvider: (any CanvasPreviewProviding)?
    /// File leases handed to external editors.
    public var resourceLeasing: (any CanvasResourceLeasing)?
    /// Host step executor for Flow external steps (jobs/service lifecycle).
    public var stepExecutor: (any CanvasStepExecutor)?
    /// Builds the Flow runtime for this host. The host owns executor, journal
    /// and registries; the UI only *drives* an existing runtime.
    public var makeFlowRuntime: (@Sendable () -> FlowRuntimeService)?
    /// Host-provided run configuration authority (REQUIRED for flow runs).
    /// The host supplies the real `FlowRunIdentity` (owning task, explicit
    /// environment policy per its own rules), the host-computed
    /// `configurationDigest`, run inputs and trusted source digests. The UI
    /// never invents a configuration hash, never infers permissions from
    /// stored node parameters, and validates the returned identity against
    /// the live document before use:
    /// `identity.canvasID == canvasID`, `identity.canvasRevision` equals the
    /// current revision, and graph identity/revision match the compiled
    /// graph. Pure local/deterministic graphs may carry an empty
    /// environment when the host's policy allows offline qualification;
    /// customScript/customAPI nodes always require the host's real
    /// environment/jobs path and otherwise surface the actionable error.
    public var makeRunConfiguration: (
        @Sendable (_ snapshot: CanvasSnapshot, _ pageID: UUID, _ graph: FlowGraph)
            async throws -> FlowRunConfiguration
    )?
    /// Host-only sample/measurement actions shown under the Lab menu.
    public var labActions: [CanvasLabAction]

    public init(
        documentStore: any CanvasDocumentStore,
        assetStore: (any CanvasAssetStore)? = nil,
        sourceService: (any CanvasSourceService)? = nil,
        sourceOpening: (any CanvasSourceOpening)? = nil,
        editorGateway: (any CanvasEditorGateway)? = nil,
        editorForkGateway: (any CanvasEditorForkGateway)? = nil,
        assistantGateway: (any CanvasAssistantGateway)? = nil,
        proposalGateway: (any CanvasAssistantProposalGateway)? = nil,
        openAssistant: (@Sendable (CanvasAssistantRequest?) async throws -> Void)? = nil,
        previewProvider: (any CanvasPreviewProviding)? = nil,
        resourceLeasing: (any CanvasResourceLeasing)? = nil,
        stepExecutor: (any CanvasStepExecutor)? = nil,
        makeFlowRuntime: (@Sendable () -> FlowRuntimeService)? = nil,
        makeRunConfiguration: (
            @Sendable (_ snapshot: CanvasSnapshot, _ pageID: UUID, _ graph: FlowGraph)
                async throws -> FlowRunConfiguration
        )? = nil,
        labActions: [CanvasLabAction] = []
    ) {
        self.documentStore = documentStore
        self.assetStore = assetStore
        self.sourceService = sourceService
        self.sourceOpening = sourceOpening
        self.editorGateway = editorGateway
        self.editorForkGateway = editorForkGateway
        self.assistantGateway = assistantGateway
        self.proposalGateway = proposalGateway
        self.openAssistant = openAssistant
        self.previewProvider = previewProvider
        self.resourceLeasing = resourceLeasing
        self.stepExecutor = stepExecutor
        self.makeFlowRuntime = makeFlowRuntime
        self.makeRunConfiguration = makeRunConfiguration
        self.labActions = labActions
    }
}

/// One host-provided Lab menu action (sample loading, measurement, tracing).
/// Lab actions never appear in normal chrome; the brief keeps them out of
/// the primary toolbar.
public struct CanvasLabActionGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct CanvasLabAction: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var group: CanvasLabActionGroup?
    /// Executes with the current editor store. Throws surface as alerts.
    public var run: @Sendable (CanvasEditorStore) async throws -> Void

    public init(
        id: String,
        title: String,
        group: CanvasLabActionGroup? = nil,
        run: @escaping @Sendable (CanvasEditorStore) async throws -> Void
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.run = run
    }

    // Explicit identity semantics: the closure is behavior, not identity.
    public static func == (lhs: CanvasLabAction, rhs: CanvasLabAction) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.group == rhs.group
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(group)
    }
}

#endif

/// Editor-wide configuration.
public struct CanvasEditorConfiguration: Sendable {
    /// Width (points) below which secondary chrome collapses into native
    /// menus and inspector sheets (UI_BRIEF: 390pt adaptation).
    public var narrowWidthThreshold: Double
    /// Pins the UI language; nil follows the host locale.
    public var preferredLanguage: CanvasStrings.Language?
    /// Default size for newly inserted cards.
    public var defaultNodeSize: CanvasGeometry.Size
    /// Grid/background preference for new pages.
    public var defaultBackground: CanvasBackgroundStyle
    /// Page-level pencil drawing cap (mirrors Core; host may lower it).
    public var maxPencilDrawingByteCount: Int

    public init(
        narrowWidthThreshold: Double = 390,
        preferredLanguage: CanvasStrings.Language? = nil,
        defaultNodeSize: CanvasGeometry.Size = .init(width: 260, height: 160),
        defaultBackground: CanvasBackgroundStyle = .grid,
        maxPencilDrawingByteCount: Int = CanvasPageSnapshot.maxPencilDrawingByteCount
    ) {
        self.narrowWidthThreshold = narrowWidthThreshold
        self.preferredLanguage = preferredLanguage
        self.defaultNodeSize = defaultNodeSize
        self.defaultBackground = defaultBackground
        self.maxPencilDrawingByteCount = maxPencilDrawingByteCount
    }
}
