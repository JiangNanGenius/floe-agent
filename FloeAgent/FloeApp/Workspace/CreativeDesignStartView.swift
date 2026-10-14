// FloeApp — conversational creation using the existing task launch service.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct CreativeDesignStartView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    let previousTarget: DesignTarget?
    /// File-entry mode: a brand-new ordinary task bound to THIS workspace
    /// file (自然语言 about the file, no old form, no hidden context).
    /// `previousTarget` (saved creative request) wins when both are set.
    let fileTarget: DesignTarget?
    @State private var previousEnvelope: DesignOwnerEnvelope?
    @State private var originConversationID: UUID?
    @State private var loaded = false
    @State private var loadError: String?
    @State private var reloadID = 0

    /// Distinct from the ordinary Home draft and every existing task.
    static let draftID = UUID(uuidString: "E5D23837-AF92-4AEC-B18B-CC71C8F3C012")!

    /// Stable draft identity for one file-entry target: retries after a
    /// failed send reuse the same draft and never fork parallel drafts.
    static func fileDraftID(for target: DesignTarget) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let digest = Array(FloeDigest.sha256Hex(
            Data("floe.file.design.draft.\(target.sourceIdentity)".utf8)).utf8)
        var index = 0
        while index < 16 && digest.count >= (index + 1) * 2 {
            let hi = digest[index * 2]
            let lo = digest[index * 2 + 1]
            func nibble(_ character: UInt8) -> UInt8 {
                switch character {
                case 48...57: return character - 48       // 0-9
                case 97...102: return character - 97 + 10 // a-f
                default: return 0
                }
            }
            bytes[index] = (nibble(hi) << 4) | nibble(lo)
            index += 1
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    init(previousTarget: DesignTarget?, fileTarget: DesignTarget? = nil) {
        self.previousTarget = previousTarget
        self.fileTarget = fileTarget
    }

    var body: some View {
        NavigationStack {
            Group {
                if let originConversationID {
                    ThreadDetailView(conversationID: originConversationID,
                                     center: environment.conversationCenter,
                                     embedded: true)
                } else if previousTarget != nil && !loaded {
                    ProgressView("design.conversation.loading_previous")
                } else if let loadError {
                    ContentUnavailableView {
                        Label("design.conversation.restore_failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("design.conversation.retry") { reloadID += 1 }
                    }
                } else {
                    VStack(spacing: 0) {
                        if let previousEnvelope {
                            savedSummary(previousEnvelope)
                        }
                        if let fileTarget {
                            boundFileBanner(fileTarget)
                        }
                        HomeLaunchpadView(
                            center: environment.conversationCenter,
                            workspaceID: fileTarget.flatMap { UUID(uuidString: $0.ownerID) },
                            draftStorageID: draftStorageID,
                            initialDraft: previousEnvelope?.project.brief?.goal,
                            designStart: true,
                            designLaunchBindingProvider: makeLaunchBinding,
                            onTaskCreated: openCreatedTask
                        )
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("workspace.workspace_canvas_view.done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("creative.design.conversation")
        .task(id: reloadID) { await restorePreviousRequest() }
    }

    private var draftStorageID: UUID {
        if let previousTarget, UUID(uuidString: previousTarget.sourceID) != nil {
            return UUID(uuidString: previousTarget.sourceID)!
        }
        if let fileTarget { return Self.fileDraftID(for: fileTarget) }
        return Self.draftID
    }

    private func boundFileBanner(_ target: DesignTarget) -> some View {
        Label(
            String(localized: "design.conversation.bound_file",
                   defaultValue: "Bound file: \(target.sourceID)"),
            systemImage: "doc.text.magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityIdentifier("creative.design.boundFile")
    }

    private func savedSummary(_ envelope: DesignOwnerEnvelope) -> some View {
        DisclosureGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let goal = envelope.project.brief?.goal {
                        Text(goal).textSelection(.enabled)
                    }
                    if let spec = envelope.project.spec?.rawMarkdown, !spec.isEmpty {
                        Text(spec).textSelection(.enabled)
                    }
                    Text(String(localized: "design.conversation.saved_candidates",
                                defaultValue: "Saved candidates: \(envelope.project.candidates.count)"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        } label: {
            Label("design.conversation.saved_request", systemImage: "clock.arrow.circlepath")
        }
        .padding()
        .accessibilityIdentifier("creative.design.savedSummary")
    }

    @MainActor
    private func restorePreviousRequest() async {
        guard let previousTarget else { loaded = true; return }
        loaded = false
        loadError = nil
        do {
            guard let value = try await environment.designOwnerWorkflow.state(previousTarget) else {
                // No envelope yet (request never persisted): treat as a fresh
                // create against the same saved target identity.
                guard !Task.isCancelled else { return }
                previousEnvelope = nil
                loaded = true
                return
            }
            guard !Task.isCancelled else { return }
            previousEnvelope = value
            // Only the saved original task may resume. Reading old data never
            // launches a model run or selects an unrelated recent conversation.
            let origin = previousTarget.originConversationID
                ?? value.project.creativeRequest?.originConversationID
            originConversationID = origin.flatMap(UUID.init(uuidString:))
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            loaded = true
        }
    }

    /// Builds the frozen launch binding for this send. The durable
    /// conversation identity does not exist yet; `ConversationCenter.
    /// startTask` rebinds `target.originConversationID` to the new
    /// conversation INSIDE the launch transaction, before provider I/O, so a
    /// model that requests tools immediately already sees the frozen target
    /// and work mode. The send callback below is navigation-only.
    ///
    /// A BRAND-NEW natural creation mints a real creative request identity
    /// through the existing owner target constructor: the requested output
    /// kind is not known until the model reads the user's request, so the
    /// frozen target carries a nil kind and the kind is fixed at
    /// `design.creativeBegin` time (the tool must address exactly this
    /// ownerID + sourceID). Continuing a saved request reuses its envelope
    /// identity unchanged.
    @MainActor
    private func makeLaunchBinding() -> DesignLaunchBinding? {
        if let previousTarget {
            // Continuing a saved request that never produced its first
            // result is still 制作; once real artifacts exist, natural-
            // language follow-ups are 修改 until the user explicitly
            // confirms a 重构 (which upgrades the binding through the
            // trusted confirmation path).
            let mode: DesignWorkMode = previousEnvelope?.project.creativeRequest?.state == .awaitingFirstResult
                ? .create
                : .modify
            return DesignLaunchBinding(
                target: previousTarget,
                workMode: mode,
                originalConversationID: previousTarget.originConversationID)
        }
        if let fileTarget {
            // File entry: a genuine ordinary task bound to THIS file. The
            // source already exists, so the frozen initial mode is 修改;
            // 重构 requires the user's explicit preservation confirmation
            // in the design page before any proposal.
            return DesignLaunchBinding(
                target: fileTarget,
                workMode: .modify,
                originalConversationID: nil)
        }
        return DesignLaunchBinding(
            target: DesignTarget(
                kind: .creativeDocument,
                ownerID: "creative-library",
                documentID: "",
                sourceID: UUID().uuidString,
                requestedOutputKind: nil),
            workMode: .create,
            originalConversationID: nil)
    }

    @MainActor
    private func openCreatedTask(_ conversationID: UUID) {
        // Navigation only. The design target + work mode were frozen inside
        // the launch transaction (see `makeLaunchBinding`); nothing here may
        // re-bind, duplicate or resurrect design state.
        dismiss()
        router.openConversation(conversationID)
    }
}
#endif
