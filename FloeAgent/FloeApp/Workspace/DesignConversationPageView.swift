// FloeApp — Design conversation page (preview-first workbench).
//
// The natural-language design presentation for an ORIGINAL chat task. The
// PRIMARY surface is the REAL artifact preview — the current/adopted
// revision or an explicit pending candidate — rendered from the verified
// retained payload bytes through the family-appropriate existing preview
// technology (web engine, image, video player, Quick Look, text). The SAME
// conversation renders beside it (wide) or behind a segmented switch
// (compact); one conversation, one run context, one workspace, no second
// chat and no second runtime.
//
// What this page is NOT: the rejected Form-first sheet. Brief/spec/feedback/
// work-mode controls live in a COLLAPSED details inspector; the preview and
// the conversation are the workbench.
//
// OWNERSHIP (rotation/split/fullscreen keep every piece of live state):
// - `model` (DesignOwnerWorkflowModel) is created once by this page and
//   handed to the fullscreen cover as the SAME instance.
// - `presentation` (DesignPagePresentationState) owns every transient UI
//   truth — lens selection, compact section, details visibility AND the
//   unsaved brief/spec/feedback drafts with dirty flags — so closing the
//   details panel, rotating, resizing or entering fullscreen never drops
//   a draft or moves the lens.
// - The layout keeps BOTH panes mounted at all times (zero-width clipping
//   instead of conditional removal), so ThreadDetailView's composer draft,
//   scroll position and selection survive wide→compact→rotation transitions
//   untouched.
// - Web previews keep ONE live WKWebView per revision id in the
//   presentation state: lens switches, fullscreen and rotation reuse the
//   same view object, so its scroll/position is the real retained state.
//
// The page itself is presented as a root full-screen cover (FloeAgentApp),
// so the preview already owns the whole available window — no dimmed
// margins around an in-sheet "fullscreen". The in-page fullscreen toggle
// only CLIPS the conversation pane to zero width: no second pane, no branch
// swap, an explicit >=44pt Done. Closing the page only closes the
// presentation: runs, services and the conversation stay alive (cancel is
// a separate, labeled action).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import WebKit
import FloeCore

// MARK: - Presentation state (shared by the page and the fullscreen cover)

/// Every transient UI truth of the design page, owned once and shared with
/// the fullscreen cover so no lens move, draft, scroll or selection is ever
/// reconstructed. Draft fields carry dirty flags: envelope refreshes NEVER
/// overwrite text the user is editing (a save clears the flag explicitly).
@MainActor
final class DesignPagePresentationState: ObservableObject {
    /// nil = the artifact's current (adopted) revision fills the stage.
    @Published var selectedCandidateID: String?
    @Published var compactSection = 0
    @Published var showsDetails = false
    @Published var showsCandidateDiff = false
    /// In-page fullscreen: the SAME view tree re-laid-out full-bleed, no
    /// separate presentation — so the preview/session/draft/selection are
    /// literally the same objects (retention is structural, not restated).
    @Published var isFullscreen = false

    // Details drafts (survive panel close/reopen, rotation and fullscreen).
    @Published var briefGoal = ""
    @Published var briefAudience = ""
    @Published var specText = ""
    @Published var feedbackDraft = ""
    @Published private(set) var briefDirty = false
    @Published private(set) var specDirty = false

    /// Envelope revision the draft fields were last loaded from; a refresh
    /// only reloads fields the user has NOT touched.
    private(set) var loadedDraftRevision: Int64?

    func markBriefEdited() { briefDirty = true }
    func markSpecEdited() { specDirty = true }

    func loadDrafts(from envelope: DesignOwnerEnvelope, force: Bool) {
        let revision = envelope.revision
        guard loadedDraftRevision != revision || force else { return }
        if !briefDirty {
            briefGoal = envelope.project.brief?.goal ?? briefGoal
            briefAudience = envelope.project.brief?.audience ?? briefAudience
        }
        if !specDirty {
            specText = envelope.project.spec?.rawMarkdown ?? specText
        }
        loadedDraftRevision = revision
    }

    func draftsSaved() {
        briefDirty = false
        specDirty = false
        loadedDraftRevision = nil
    }

    // MARK: Web preview ownership

    /// One live web view per revision id: the same UIView object follows the
    /// user across lens switches, fullscreen and rotation, so scroll
    /// position and rendered state are genuinely retained. Bounded: never
    /// more than `maxWebViews` live views, and pruning never evicts a lens
    /// the caller still names as live (the mounted page, the fullscreen
    /// cover and their lens selections share one live set).
    static let maxWebViews = 4
    private var webViews: [String: WKWebView] = [:]
    /// Insertion order for deterministic oldest-first eviction. Dictionary
    /// key order is hash-dependent (and shifts after removals), so evicting
    /// `keys.first` could drop the CURRENT lens; the explicit order keeps
    /// eviction truly oldest-inserted.
    private var webViewInsertionOrder: [String] = []

    private func removeWebView(for revisionID: String) {
        webViews[revisionID] = nil
        webViewInsertionOrder.removeAll { $0 == revisionID }
    }

    func webView(for revisionID: String, url: URL) -> WKWebView {
        if let existing = webViews[revisionID],
           existing.url?.standardizedFileURL != url.standardizedFileURL {
            // Same revision id with different bytes cannot happen (digest is
            // part of revision identity); a mismatched URL means a stale
            // scratch file — rebuild rather than render wrong bytes.
            removeWebView(for: revisionID)
        }
        if let existing = webViews[revisionID] { return existing }
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        webViews[revisionID] = view
        webViewInsertionOrder.append(revisionID)
        return view
    }

    /// Evicts web views whose revision is no longer visible anywhere (not
    /// the current lens, not a pending candidate, not a fullscreen/editor
    /// lease), oldest-inserted first; then enforces the hard count cap by
    /// dropping the oldest entries — full history can hold many revisions,
    /// but heavyweight browser state is retained only for the live set.
    func pruneWebViews(keeping liveRevisionIDs: Set<String>) {
        for key in webViews.keys where !liveRevisionIDs.contains(key) {
            removeWebView(for: key)
        }
        while webViews.count > Self.maxWebViews, let oldest = webViewInsertionOrder.first {
            removeWebView(for: oldest)
        }
    }

    // MARK: Media playback ownership

    /// ONE playback model per URL: the page and its fullscreen cover share
    /// the same AVPlayer for a given preview, so position and play/pause
    /// state cross surfaces instead of resetting (MediaPlayerView's own
    /// fullscreen uses the same shared model). Bounded to the active
    /// previews; history never retains players for revisions left the set.
    static let maxMediaModels = 2
    private var mediaModels: [URL: MediaPlayerModel] = [:]
    /// Insertion order for deterministic oldest-first eviction (the same
    /// hash-order trap as webViews: `keys.first` is not insertion order).
    private var mediaModelInsertionOrder: [URL] = []

    private func removeMediaModel(for url: URL) {
        mediaModels[url] = nil
        mediaModelInsertionOrder.removeAll { $0 == url }
    }

    func mediaModel(for url: URL) -> MediaPlayerModel {
        if let existing = mediaModels[url] { return existing }
        let model = MediaPlayerModel()
        mediaModels[url] = model
        mediaModelInsertionOrder.append(url)
        if mediaModels.count > Self.maxMediaModels, let oldest = mediaModelInsertionOrder.first {
            removeMediaModel(for: oldest)
        }
        return model
    }

    func pruneMediaModels(keeping liveURLs: Set<URL>) {
        for key in mediaModels.keys where !liveURLs.contains(key) {
            removeMediaModel(for: key)
        }
        while mediaModels.count > Self.maxMediaModels, let oldest = mediaModelInsertionOrder.first {
            removeMediaModel(for: oldest)
        }
    }

    // Test/inspection seams (no production UI reads these).
    func webViewIfPresent(for revisionID: String) -> WKWebView? { webViews[revisionID] }
    var webViewCount: Int { webViews.count }
    func mediaModelIfPresent(for url: URL) -> MediaPlayerModel? { mediaModels[url] }
    var mediaModelCount: Int { mediaModels.count }
}

// MARK: - Page

struct DesignConversationPageView: View {
    let target: DesignTarget
    let conversationID: UUID
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DesignOwnerWorkflowModel
    @StateObject private var presentation: DesignPagePresentationState

    init(target: DesignTarget, conversationID: UUID, environment: AppEnvironment) {
        self.target = target
        self.conversationID = conversationID
        _model = StateObject(wrappedValue: DesignOwnerWorkflowModel(
            target: target, environment: environment))
        _presentation = StateObject(wrappedValue: DesignPagePresentationState())
    }

    var body: some View {
        GeometryReader { proxy in
            // ONE view tree in every state: fullscreen only CLIPS the
            // conversation pane to zero width (the same zero-width-clipping
            // pattern as the compact layout) — it never swaps branches, so
            // the SAME live web view, media player, QuickLook/editor host,
            // chat, composer draft and selection stay mounted and retain
            // their state. The page itself occupies the whole window via
            // the root full-screen cover; the dimmed-margin in-sheet
            // "fullscreen" is gone.
            splitLayout(proxy: proxy)
                .safeAreaInset(edge: .top, spacing: 0) { topChrome }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // Compact (iPhone width / iPad portrait): an explicit
                    // preview/chat switch instead of side-by-side columns.
                    // One view tree either way — the clipped pane keeps its
                    // draft/scroll/selection while hidden.
                    if proxy.size.width < 900, !presentation.isFullscreen {
                        Picker(selection: $presentation.compactSection) {
                            Text("design.page.section.preview").tag(0)
                            Text("design.page.section.chat").tag(1)
                        } label: {
                            Text("design.page.section.switch")
                        }
                        .pickerStyle(.segmented)
                        .frame(height: FloeTheme.minimumTarget)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(.bar)
                        .accessibilityIdentifier("design.page.sectionPicker")
                    }
                }
                .overlay(alignment: .trailing) { detailsOverlay }
        }
        .task {
            await model.reload()
            model.reloadWorkModeBinding()
            if presentation.selectedCandidateID == nil {
                presentation.selectedCandidateID = model.pendingCandidates.first?.id
            }
            if let envelope = model.envelope {
                presentation.loadDrafts(from: envelope, force: true)
            }
        }
        .onChange(of: model.envelope?.revision) { _, _ in
            if let selected = presentation.selectedCandidateID,
               model.pendingCandidates.contains(where: { $0.id == selected }) == false {
                presentation.selectedCandidateID = model.pendingCandidates.first?.id
            }
            if let envelope = model.envelope {
                presentation.loadDrafts(from: envelope, force: false)
            }
        }
        // No page-level accessibility identifier here: at the root-sheet
        // level it REPLACES every descendant's identifier, hiding the real
        // controls from UI acceptance. Page presence is proven by the
        // controls themselves (lens bar, chrome buttons).
    }

    @ViewBuilder
    private var detailsOverlay: some View {
        if presentation.showsDetails {
            GeometryReader { proxy in
                // Trailing alignment done honestly: the GeometryReader only
                // MEASURES; a leading Spacer pushes the width-clamped panel
                // to the trailing edge. (A bare GeometryReader child is
                // greedy and top-leading aligned — that pinned the panel
                // left.)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    DesignPageDetailsPanel(model: model, presentation: presentation)
                        .frame(width: min(360, max(280, proxy.size.width - 24)))
                        .transition(.move(edge: .trailing))
                        // No container identifier: it would override the
                        // panel's own controls (fields/buttons) for UI
                        // acceptance. Presence is proven by those controls.
                }
            }
        }
    }

    @ViewBuilder
    private func splitLayout(proxy: GeometryProxy) -> some View {
        let wide = proxy.size.width >= 900
        // Fullscreen keeps the split mounted but gives the preview the
        // entire width: the conversation pane clips to zero instead of
        // unmounting, so its draft/scroll/selection survive the toggle.
        let conversationWidth = presentation.isFullscreen ? 0
            : wide ? min(480, max(340, proxy.size.width * 0.38))
            : (presentation.compactSection == 1 ? proxy.size.width : 0)
        let previewWidth = proxy.size.width - conversationWidth
        HStack(spacing: 0) {
                // Both panes stay MOUNTED through every geometry change:
                // zero-width clipping instead of conditional removal keeps
                // the composer draft, scroll and selection alive.
                DesignPreviewWorkbench(
                    model: model, presentation: presentation, target: target)
                    .frame(width: previewWidth)
                    .clipped()
                    .allowsHitTesting(previewWidth > 0)
                    .accessibilityHidden(previewWidth <= 0)
                if wide, !presentation.isFullscreen {
                    Divider()
                }
                conversationPane
                    .frame(width: conversationWidth)
                    .clipped()
                    .allowsHitTesting(conversationWidth > 0)
                    .accessibilityHidden(conversationWidth <= 0)
        }
        // Native top chrome RESERVATION and the details overlay live on the
        // body (shared by the split and fullscreen layouts).
    }

    // MARK: Chrome

    /// The page's top bar. In-page fullscreen swaps the close control for an
    /// explicit Done and hides the fullscreen entry — one chrome, one exit,
    /// no nested presentation.
    private var topChrome: some View {
        HStack(spacing: 4) {
            if presentation.isFullscreen {
                Button {
                    presentation.isFullscreen = false
                } label: {
                    Text("action.done")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("design.page.done")
            } else {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("design.page.close")
                .accessibilityLabel(Text("common.close"))
            }
            Spacer()
            Text(pageTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("design.page.title")
            Spacer()
            Button {
                withAnimation { presentation.showsDetails.toggle() }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.body.weight(.semibold))
                    .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("design.page.details")
            if !presentation.isFullscreen {
                Button {
                    presentation.isFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("design.page.fullscreen")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.bar)
    }

    private var pageTitle: String {
        if let source = model.resolvedSource, !source.displayName.isEmpty {
            return source.displayName
        }
        return FloeL10n.l("design.page.title")
    }

    // MARK: Conversation (the SAME task — never a second chat)

    private var conversationPane: some View {
        ThreadDetailView(
            conversationID: conversationID,
            center: environment.conversationCenter,
            embedded: true)
        .accessibilityIdentifier("design.page.conversationPane")
    }
}

// MARK: - Preview workbench (the page's primary surface, fullscreen included)

/// The preview stage + candidate decision bar. Mounted inside the page and
/// inside the fullscreen cover with the SAME model and presentation, so the
/// lens, drafts and (via the presentation state's web-view ownership) the
/// live web view follow the user across surfaces.
private struct DesignPreviewWorkbench: View {
    @ObservedObject var model: DesignOwnerWorkflowModel
    @ObservedObject var presentation: DesignPagePresentationState
    let target: DesignTarget
    @EnvironmentObject private var environment: AppEnvironment
    @State private var showsEditorHandoff = false

    /// Families whose professional editing surface is the app's EXISTING
    /// FilePreviewView host (native CAD workbench, Office editor, image
    /// editor, video, PDF). The handoff opens that real surface for the
    /// SAME file identity — no parallel editor, no second store.
    private var hasProfessionalEditor: Bool {
        switch model.project?.artifact(stagedArtifactID ?? "")?.contentType
            ?? target.requestedOutputKind ?? .webpage {
        case .cad, .presentation, .officeDocument, .image, .video, .pdf:
            return true
        case .webpage, .prototype, .notes, .composition:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            lensBar
            if let error = model.errorMessage {
                DesignPageErrorBanner(message: error) {
                    model.dismissError()
                }
            }
            previewBody
            editorHandoffBar
            candidateActionBar
        }
        .background(FloeTheme.readingSurface)
        .accessibilityIdentifier("design.page.previewStage")
        .onAppear {
            // Keep the web-view cache bounded to live lenses only.
            var ids = Set(model.currentArtifact.map { [$0.currentRevisionID] } ?? [])
            for candidate in model.pendingCandidates {
                ids.insert(candidate.proposedRevisionID)
                ids.insert(candidate.baseRevisionID)
            }
            presentation.pruneWebViews(keeping: Set(ids.compactMap { $0 }))
        }
        .sheet(isPresented: $showsEditorHandoff) {
            // The SAME professional surface the Files/IDE entries use, over
            // the SAME workspace file identity. FilePreviewView reports an
            // honest error when the workspace is not mounted (a truthful
            // session state, never a fake preview).
            NavigationStack {
                FilePreviewView(
                    relativePath: target.sourceID,
                    center: environment.workspaceCenter,
                    conversationID: conversationIDForHandoff,
                    allowsIDEExpansion: false,
                    // The page already owns this design target: the nested
                    // handoff must never re-present the same page on top of
                    // itself (no recursive presentation).
                    allowsDesignPage: false)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("action.done") {
                            showsEditorHandoff = false
                        }
                        .accessibilityIdentifier("design.page.editorHandoffDone")
                    }
                }
            }
            .accessibilityIdentifier("design.page.editorHandoff")
        }
    }

    private var conversationIDForHandoff: UUID? {
        target.originConversationID.flatMap(UUID.init(uuidString:))
    }

    /// Explicit specialized-editor handoff: current lens of a fileDocument
    /// target opens the real editor surface; a CANDIDATE lens is immutable
    /// and says so (adopt first, then edit the original).
    @ViewBuilder
    private var editorHandoffBar: some View {
        if target.kind == .fileDocument, hasProfessionalEditor {
            HStack(spacing: 8) {
                if presentation.selectedCandidateID != nil {
                    Label("design.page.candidateImmutable", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("design.page.candidateImmutable"))
                        .accessibilityIdentifier("design.page.candidateImmutable")
                } else {
                    Button {
                        showsEditorHandoff = true
                    } label: {
                        Label("design.page.openInEditor", systemImage: "rectangle.and.pencil.and.ellipsis")
                            .font(.caption.weight(.medium))
                            .frame(minHeight: FloeTheme.minimumTarget, alignment: .leading)
                    }
                    .accessibilityIdentifier("design.page.openInEditor")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }

    // MARK: Lens bar

    /// Explicit lens selection: the current artifact vs each pending
    /// candidate. This IS the candidate control surface — no Form landing.
    private var lensBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                lensChip(
                    title: FloeL10n.l("design.page.preview.current"),
                    selected: presentation.selectedCandidateID == nil,
                    enabled: model.currentArtifact?.currentRevisionID != nil
                ) {
                    presentation.selectedCandidateID = nil
                }
                .accessibilityIdentifier("design.page.lens.current")
                ForEach(model.pendingCandidates) { candidate in
                    lensChip(
                        title: FloeL10n.l(
                            "design.page.preview.candidate_index",
                            (model.pendingCandidates.firstIndex(where: { $0.id == candidate.id }) ?? 0) + 1),
                        selected: presentation.selectedCandidateID == candidate.id,
                        enabled: true
                    ) {
                        presentation.selectedCandidateID = candidate.id
                    }
                    .accessibilityIdentifier("design.page.lens.candidate.\(candidate.id)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func lensChip(
        title: String,
        selected: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(minHeight: FloeTheme.minimumTarget)
    }

    // MARK: Preview body

    /// The artifact revision filling the stage for the current lens.
    private var stagedRevisionID: String? {
        if let candidateID = presentation.selectedCandidateID,
           let candidate = model.project?.candidate(candidateID) {
            return candidate.proposedRevisionID
        }
        return model.currentArtifact?.currentRevisionID
    }

    private var stagedArtifactID: String? {
        if let candidateID = presentation.selectedCandidateID,
           let candidate = model.project?.candidate(candidateID) {
            return candidate.artifactID
        }
        return model.currentArtifact?.id
    }

    @ViewBuilder
    private var previewBody: some View {
        if model.busy && model.envelope == nil {
            Spacer()
            ProgressView("design.page.loading")
                .accessibilityIdentifier("design.page.loading")
            Spacer()
        } else if model.envelope == nil {
            Spacer()
            ContentUnavailableView(
                "design.page.noArtifact",
                systemImage: "square.dashed",
                description: Text("design.page.noArtifact.detail"))
                .accessibilityIdentifier("design.page.noArtifact")
            Spacer()
        } else if model.currentArtifact == nil || stagedRevisionID == nil {
            // Creative requests awaiting their first result land here: the
            // conversation is the workspace; the preview appears with the
            // first real revision (no fabricated placeholder).
            Spacer()
            ContentUnavailableView(
                "design.page.awaitingFirstResult",
                systemImage: "text.bubble",
                description: Text(model.isCreativeAwaitingFirstResult
                                  ? "design.page.awaitingFirstResult.detail"
                                  : "design.page.noArtifact.detail"))
                .accessibilityIdentifier("design.page.noArtifact")
            Spacer()
        } else {
            DesignArtifactPreview(
                model: model,
                presentation: presentation,
                artifactID: stagedArtifactID ?? "",
                revisionID: stagedRevisionID ?? "",
                contentType: model.project?.artifact(stagedArtifactID ?? "")?.contentType
                    ?? target.requestedOutputKind ?? .webpage,
                isCandidate: presentation.selectedCandidateID != nil)
                .id(stagedRevisionID ?? "empty")
                .accessibilityIdentifier("design.page.artifactPreview")
        }
    }

    // MARK: Candidate decisions

    /// Candidate decisions under the stage — shown ONLY while the selected
    /// lens is a pending candidate, and collapsed the moment it resolves.
    /// One clear primary action (adopt); variant/reject/authorize live in a
    /// compact "更多" menu. Nothing is resident: the current-artifact lens
    /// has NO decision bar at all (recovery lives in the details inspector),
    /// so the preview is never squeezed by a permanent strip.
    @ViewBuilder
    private var candidateActionBar: some View {
        if let candidateID = presentation.selectedCandidateID,
           let candidate = model.project?.candidate(candidateID),
           candidate.status == .pending {
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    DesignCandidateSummaryRow(
                        summary: candidate.summary,
                        statusText: FloeL10n.l("design.owner.pending"),
                        statusColor: FloeTheme.pending,
                        diffLines: model.comparison?.candidateID == candidateID
                            ? model.comparison?.diff : candidate.diff,
                        diffTruncated: model.comparison?.diffTruncated ?? false,
                        diffNote: model.comparison?.diffNote)
                    Spacer(minLength: 8)
                    // ONE primary action.
                    Button(model.isImmutableOwner
                           ? "design.owner.adopt_return"
                           : "design.owner.adopt") {
                        Task { await model.adopt(candidateID, mode: .updateOriginal) }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("design.page.adopt.\(candidateID)")
                    // Everything else: compact, on-demand menu.
                    Menu {
                        if !model.isImmutableOwner {
                            Button("design.owner.adopt_variant") {
                                Task { await model.adopt(candidateID, mode: .variant) }
                            }
                            .accessibilityIdentifier("design.page.variant.\(candidateID)")
                        }
                        Button("design.owner.reject", role: .destructive) {
                            Task { await model.reject(candidateID) }
                        }
                        .accessibilityIdentifier("design.page.reject.\(candidateID)")
                        Divider()
                        Button(presentation.showsCandidateDiff
                               ? "design.page.hide_diff"
                               : "design.owner.compare") {
                            presentation.showsCandidateDiff.toggle()
                            if presentation.showsCandidateDiff {
                                Task { await model.compare(candidateID) }
                            }
                        }
                        .accessibilityIdentifier("design.page.compare.\(candidateID)")
                        if model.canAuthorizeAssistant {
                            Divider()
                            Button("design.owner.authorize_update") {
                                Task { await model.authorizeAssistantAdoption(candidateID, mode: .updateOriginal) }
                            }
                            if !model.isImmutableOwner {
                                Button("design.owner.authorize_variant") {
                                    Task { await model.authorizeAssistantAdoption(candidateID, mode: .variant) }
                                }
                            }
                        }
                    } label: {
                        Label("design.page.moreActions", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("design.page.candidateMenu.\(candidateID)")
                }
                if presentation.showsCandidateDiff,
                   let comparison = model.comparison,
                   comparison.candidateID == candidateID {
                    if comparison.diffTruncated, let note = comparison.diffNote {
                        Text(note).font(.caption2).foregroundStyle(FloeTheme.pending)
                    }
                    if !comparison.changed {
                        Text("design.owner.no_change")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("design.page.candidateBar")
        }
    }
}

// MARK: - Details inspector (collapsed by default; NOT the landing surface)

/// Brief/spec/feedback/work-mode/history controls. Drafts live in the SHARED
/// presentation state: closing the panel, rotating or going fullscreen never
/// loses an unsaved edit, and an envelope refresh never reloads over text
/// the user is editing (dirty flags; explicit save clears them).
private struct DesignPageDetailsPanel: View {
    @ObservedObject var model: DesignOwnerWorkflowModel
    @ObservedObject var presentation: DesignPagePresentationState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("design.page.details")
                    .font(.headline)
                Spacer()
                Button {
                    presentation.showsDetails = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("design.page.detailsClose")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            Form {
                briefSection
                specSection
                DesignWorkModeSection(model: model)
                feedbackSection
                historySection
            }
        }
        // No hardcoded width here: the details overlay clamps the panel
        // adaptively (280...360). A fixed 360 used to fight that clamp.
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .task {
            await model.reload()
            model.reloadWorkModeBinding()
            if let envelope = model.envelope {
                presentation.loadDrafts(from: envelope, force: true)
            }
        }
    }

    private var briefSection: some View {
        Section("design.panel.brief") {
            DesignBriefFields(
                goal: $presentation.briefGoal, audience: $presentation.briefAudience,
                goalLabel: "design.panel.goal",
                audienceLabel: "design.panel.audience",
                goalIdentifier: "design.page.brief.goal",
                audienceIdentifier: "design.page.brief.audience",
                onEdit: { presentation.markBriefEdited() })
            Button("design.panel.save_brief") {
                Task {
                    await model.saveBrief(
                        goal: presentation.briefGoal,
                        audience: presentation.briefAudience)
                    presentation.draftsSaved()
                }
            }
            .disabled(model.busy)
            .accessibilityIdentifier("design.page.brief.save")
        }
    }

    private var specSection: some View {
        Section("design.panel.spec") {
            DesignSpecField(
                label: "design.panel.spec_markdown", text: $presentation.specText,
                identifier: "design.page.spec.markdown", onEdit: { presentation.markSpecEdited() })
            Button("design.panel.save_spec") {
                Task {
                    await model.saveSpec(rawMarkdown: presentation.specText)
                    presentation.draftsSaved()
                }
            }
            .disabled(model.busy)
            .accessibilityIdentifier("design.page.spec.save")
            Text("design.panel.spec_frozen_note")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var feedbackSection: some View {
        Section("design.owner.feedback") {
            TextField("design.owner.feedback_comment", text: $presentation.feedbackDraft, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityIdentifier("design.page.feedbackComment")
            Button("design.owner.feedback_add") {
                Task {
                    await model.addFeedback(presentation.feedbackDraft)
                    presentation.feedbackDraft = ""
                }
            }
            .disabled(model.busy || presentation.feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("design.page.feedbackAdd")
            ForEach(model.openFeedback) { item in
                DesignFeedbackRow(
                    comment: item.comment,
                    statusText: item.status.rawValue,
                    statusColor: .secondary,
                    busy: model.busy,
                    showsRelocate: item.status == .staleAnchor,
                    showsResolve: item.status != .staleAnchor
                        && model.currentArtifact?.currentRevisionID != nil,
                    onRelocate: { Task { await model.relocateAnchor(item.id) } },
                    onResolve: { Task { await model.resolveFeedback(item.id) } })
            }
        }
    }

    private var historySection: some View {
        Section("design.page.history") {
            if let artifact = model.currentArtifact {
                Text(FloeL10n.l("design.panel.revision_count", artifact.revisions.count))
                    .font(.caption).foregroundStyle(.secondary)
                if artifact.revisions.count >= 2 {
                    Button("design.page.restore") {
                        Task { await model.restoreLatestRevision() }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("design.page.restore")
                }
            } else {
                Text("design.page.noArtifact").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Error banner

private struct DesignPageErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Text(message).foregroundStyle(FloeTheme.destructive)
            Spacer()
            Button("design.panel.dismiss_error", action: onDismiss)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("design.page.error")
    }
}

// MARK: - Artifact preview (family-specific, real bytes)

/// Renders ONE verified revision's bytes with the existing truthful preview
/// technology for the family. Never claims editability it does not have:
/// document previews are explicitly labeled read-only and name the
/// professional editor as the editing surface; formats with no connected
/// inline preview say so honestly with the recovery action.
private struct DesignArtifactPreview: View {
    @ObservedObject var model: DesignOwnerWorkflowModel
    @ObservedObject var presentation: DesignPagePresentationState
    let artifactID: String
    let revisionID: String
    let contentType: DesignContentType
    let isCandidate: Bool
    @State private var scratch: DesignPreviewScratch?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let preview = model.revisionPreviews[revisionID] {
                previewContent(preview)
                    // The format/byte badge RESERVES its own strip above the
                    // content (outside the web view's coordinate space) so
                    // it can never paint over the page's top heading; the
                    // web content keeps its full unobstructed viewport.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 0) {
                            // Family caption: names the real preview
                            // technology rendering the retained bytes (and
                            // gives the UI acceptance a stable, truthful
                            // identifier — native representables absorb
                            // their own a11y ids).
                            Label(familyCaption(preview), systemImage: familyIcon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.bar, in: Capsule())
                                // One accessibility element: Labels otherwise
                                // split into image+text and lose the id.
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(familyCaption(preview))
                                .accessibilityIdentifier(familyAccessibilityIdentifier)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.bar)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isCandidate {
                            Text("design.page.preview.candidate")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(FloeTheme.pending, in: Capsule())
                                .padding(8)
                                .accessibilityIdentifier("design.page.candidateBadge")
                        }
                    }
            } else if let loadError {
                ContentUnavailableView(
                    "design.page.previewFailed", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
                    .accessibilityIdentifier("design.page.previewFailed")
            } else {
                ProgressView("design.page.loading")
                    .accessibilityIdentifier("design.page.loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: revisionID) {
            await load()
        }
    }

    private var familyAccessibilityIdentifier: String {
        switch contentType {
        case .image: return "design.page.preview.image"
        case .video: return "design.page.preview.video"
        case .webpage, .prototype: return "design.page.preview.web"
        case .pdf: return "design.page.preview.quicklook"
        case .presentation, .officeDocument: return "design.page.preview.quicklook"
        case .notes: return "design.page.preview.text"
        case .cad: return "design.page.preview.unavailable"
        case .composition: return "design.page.preview.unavailable"
        }
    }

    private var familyIcon: String {
        switch contentType {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .webpage, .prototype: return "safari"
        case .pdf: return "doc.richtext"
        case .presentation, .officeDocument: return "doc.richtext"
        case .notes: return "text.alignleft"
        case .cad: return "cube.transparent"
        case .composition: return "square.dashed"
        }
    }

    private func familyCaption(_ preview: DesignOwnerWorkflowModel.RevisionPreview) -> String {
        let format = preview.format.isEmpty ? "bin" : preview.format
        return "\(format.uppercased()) · \(preview.byteCount) B"
    }

    private func load() async {
        if model.revisionPreviews[revisionID] != nil {
            ensureScratch()
            return
        }
        loadError = nil
        await model.loadPreview(artifactID: artifactID, revisionID: revisionID)
        if model.revisionPreviews[revisionID] != nil {
            ensureScratch()
        } else if let error = model.errorMessage {
            loadError = error
        }
    }

    private func ensureScratch() {
        guard scratch == nil,
              let preview = model.revisionPreviews[revisionID] else { return }
        scratch = DesignPreviewScratch.make(
            bytes: preview.bytes, format: preview.format, revisionID: revisionID)
    }

    @ViewBuilder
    private func previewContent(_ preview: DesignOwnerWorkflowModel.RevisionPreview) -> some View {
        let format = preview.format.lowercased()
        switch contentType {
        case .image:
            if format == "svg", let url = scratch?.url {
                DesignPreviewWebView(
                    presentation: presentation, revisionID: revisionID, url: url)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("design.page.preview.web")
            } else if let url = scratch?.url,
                      let image = CanvasImageThumbnailCache.thumbnail(for: url, maxPixel: 2048) {
                // The SAME bounded, downsampled decoder the canvas uses:
                // ImageIO thumbnails bound decoded pixels (a compressed-byte
                // cap says nothing about decode size), the cache is bounded
                // by count and decoded cost, and a failed/huge decode is an
                // honest unavailable state — never a silent resize or a
                // full-pixel decode of a 100 MP source.
                GeometryReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: max(proxy.size.width - 8, 120),
                                   maxHeight: max(proxy.size.height - 8, 120))
                    }
                }
                .accessibilityIdentifier("design.page.preview.image")
            } else {
                // Decode failure or a format ImageIO cannot thumbnail:
                // honest unavailable state with the recovery, never a
                // silent resize or a blank stage.
                ContentUnavailableView(
                    "design.page.preview.unsupported", systemImage: "doc.questionmark",
                    description: Text("design.page.preview.decode_failed"))
                    .accessibilityIdentifier("design.page.preview.unavailable")
            }
        case .video:
            if let url = scratch?.url {
                // ONE playback session per URL across the page and the
                // fullscreen cover: position and play state cross surfaces.
                MediaPlayerView(url: url, sharedModel: presentation.mediaModel(for: url))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("design.page.preview.video")
            } else {
                unavailable(preview)
            }
        case .webpage, .prototype:
            if ["html", "htm", "svg", "xhtml"].contains(format), let url = scratch?.url {
                DesignPreviewWebView(
                    presentation: presentation, revisionID: revisionID, url: url)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("design.page.preview.web")
            } else if format == "json" || format == "txt" || format == "md" {
                textPreview(preview)
            } else {
                unavailable(preview)
            }
        case .pdf:
            if let url = scratch?.url {
                QuickLookView(url: url)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("design.page.preview.quicklook")
            } else {
                unavailable(preview)
            }
        case .presentation, .officeDocument:
            if let url = scratch?.url {
                VStack(spacing: 0) {
                    QuickLookView(url: url)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("design.page.preview.quicklook")
                    Label("design.page.preview.readonly", systemImage: "eye")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(8)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("design.page.preview.readonly"))
                        .accessibilityIdentifier("design.page.readonlyNote")
                }
                .accessibilityIdentifier("design.page.preview.quicklook")
            } else {
                unavailable(preview)
            }
        case .notes:
            textPreview(preview)
        case .cad:
            // No inline renderer exists in this page: the REAL surface is
            // the specialized CAD workbench, reached through the explicit
            // same-target handoff bar above (current lens). The retained
            // identity below keeps the preview truthful; candidates stay
            // immutable.
            ContentUnavailableView(
                "design.page.preview.unsupported", systemImage: "cube.transparent",
                description: Text("design.page.preview.cad.note"))
                .accessibilityIdentifier("design.page.preview.unavailable")
        case .composition:
            ContentUnavailableView(
                "design.page.preview.unsupported", systemImage: "square.dashed",
                description: Text("design.page.preview.unsupported.composition"))
                .accessibilityIdentifier("design.page.preview.unavailable")
        }
    }

    private func textPreview(_ preview: DesignOwnerWorkflowModel.RevisionPreview) -> some View {
        ScrollView {
            Text(String(decoding: preview.bytes, as: UTF8.self))
                .font(FloeTheme.Typography.evidence)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("design.page.preview.text")
    }

    private func unavailable(_ preview: DesignOwnerWorkflowModel.RevisionPreview) -> some View {
        ContentUnavailableView(
            "design.page.preview.unsupported", systemImage: "doc.questionmark",
            description: Text(preview.byteCount == 0
                              ? "design.panel.preview_not_retained"
                              : "design.panel.preview_binary"))
            .accessibilityIdentifier("design.page.preview.unavailable")
    }
}

/// Read-only web preview backed by the presentation state's per-revision web
/// view: ONE live WKWebView per revision follows the user across lens
/// switches, fullscreen and rotation, so scroll and rendered state are the
/// genuinely retained ones (not a fresh view per appearance). Loads the
/// scratch file URL with no navigation: the workspace browser preview
/// remains the build-serve surface; this renders the retained bytes as-is.
private struct DesignPreviewWebView: UIViewRepresentable {
    @ObservedObject var presentation: DesignPagePresentationState
    let revisionID: String
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = presentation.webView(for: revisionID, url: url)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the initial file load (and its subresources) render; any
            // link navigation is refused so the stage stays read-only.
            if navigationAction.navigationType == .other
                || navigationAction.navigationType == .reload {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

/// One transient scratch file backing the family previews (Quick Look,
/// video, web). The byte identity (revision id + size) is part of the name
/// so two lenses never collide and a stale lens file is never reused; the
/// presentation state drops the web view (and its scroll) if the identity
/// ever changes.
private final class DesignPreviewScratch: @unchecked Sendable {
    let url: URL

    private init(url: URL) { self.url = url }

    static func make(bytes: Data, format: String, revisionID: String) -> DesignPreviewScratch? {
        let sanitized = format.replacingOccurrences(
            of: #"[^a-zA-Z0-9]"#, with: "", options: .regularExpression)
        let name = "design-preview-\(revisionID.prefix(12))-\(bytes.count)b.\(sanitized.isEmpty ? "bin" : sanitized)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // Scratch files are per-revision content-identical: reuse the
        // existing file instead of rewriting it, so a mounted web view's
        // read-access URL stays valid across appearances.
        if FileManager.default.fileExists(atPath: url.path),
           (try? Data(contentsOf: url)) == bytes {
            return DesignPreviewScratch(url: url)
        }
        do {
            try bytes.write(to: url, options: .atomic)
            return DesignPreviewScratch(url: url)
        } catch {
            return nil
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
#endif
