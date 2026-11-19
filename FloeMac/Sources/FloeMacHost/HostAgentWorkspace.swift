// SPDX-License-Identifier: MPL-2.0

import Combine
import FloeAgentRuntime
import FloeCore
import FloeMacSelfCore
import FloePersistence
import FloeProviders
import FloeSecurity
import Foundation
import UniformTypeIdentifiers
#if FLOE_MAC_HOST_SMOKE
import FloeModels
#endif

/// One staged file attachment prepared for the next send. The draft carries
/// a read-only security-scoped bookmark created at pick time plus verified
/// size and digest metadata; it grants no tool or permission authority.
/// The runtime verifies eligible attachments again before sending any bytes.
struct HostAgentAttachmentDraft: Hashable, Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case image
        case document
    }

    let id: UUID
    let kind: Kind
    let url: URL
    let bookmark: Data
    let displayName: String
    let byteCount: Int
    let sha256: String
    let uti: String

}

struct HostAgentProvider: Codable {
    var profile: ProviderProfile
    var model: ModelProfile
    /// This record is encoded only for the app's device-bound Keychain.
    let apiKey: String
    /// Optional preset identity (`ProviderTemplateID.rawValue`) this record
    /// was created from. Records written before presets existed decode this
    /// as nil and keep working; the effective preset is still resolvable
    /// from the endpoint when needed.
    var presetID: String?

    /// The label shown in the provider list: the user-chosen name when set,
    /// otherwise the model ID (the 1.3.0 single-profile behavior).
    var displayTitle: String { profile.displayName ?? model.displayName }

    @MainActor
    init(displayName: String? = nil, endpoint: String, protocolKind: ModelProtocol, modelID: String, apiKey: String,
         supportsImages: Bool = false, supportsTools: Bool = false, presetID: String? = nil) throws {
        guard let endpointURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InvalidConfiguration.endpoint
        }
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw InvalidConfiguration.key
        }
        profile = ProviderProfile(kind: .custom, wireProtocol: protocolKind, baseURL: endpointURL,
                                  displayName: trimmedName?.isEmpty == false ? trimmedName : nil,
                                  presetID: presetID)
        var capabilities: ModelCapabilities = [.text]
        if supportsImages { capabilities.insert(.vision) }
        if supportsTools { capabilities.insert(.tools) }
        model = ModelProfile(providerID: profile.id, remoteModelID: modelID, displayName: modelID,
                             limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
                             capabilities: capabilities)
        self.apiKey = apiKey
        self.presetID = presetID
        try validate()
    }

    func validate() throws {
        try ProviderConfigurationValidation.validate(profile)
        try ProviderConfigurationValidation.validate(model)
    }

    func binding() -> FloeMacSelfProviderBinding {
        FloeMacSelfProviderBinding(provider: profile, model: model,
            adapter: ProviderAdapterFactory().adapter(for: profile),
            credentials: ProviderCredentials(apiKey: apiKey.isEmpty ? nil : apiKey))
    }

    private enum InvalidConfiguration: Error {
        case endpoint, key
    }
}

/// Durable multi-provider record persisted in the existing chat Keychain
/// namespace (service `<bundle>.chat`). Version 1 is the first list-capable
/// format; a record written by a newer build fails closed on read so its
/// extra fields are never dropped by an older one. The legacy
/// single-profile account stays in place as a mirror of the selected record
/// so a downgrade to the 1.3.0 layout keeps working.
private struct ProviderListEnvelope: Codable {
    var version: Int
    var providers: [HostAgentProvider]
    var selectedProviderID: UUID?
}

private enum ProviderStoreError: Error {
    case missingRecord
}

enum HostAgentMode: String, CaseIterable {
    case chat, agent, plan, goal

    var runtimeMode: ConversationMode {
        switch self {
        case .chat, .agent: .chat
        case .plan: .plan
        case .goal: .goal
        }
    }
}

struct HostAgentApproval: Equatable {
    let conversationID: UUID
    let runID: UUID
    let workspaceID: UUID
    let callID: String
    let toolName: String
    let path: String?
    let text: String?
    let previousText: String?
}

@MainActor
final class HostAgentWorkspace: ObservableObject {
    typealias ReleaseWork = @MainActor () -> Void
    typealias AdmitWork = @MainActor () throws -> ReleaseWork
    @Published private(set) var isReady = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isSending = false
    @Published private(set) var isStopping = false
    @Published private(set) var isTerminating = false
    @Published private(set) var modelName: String?
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var recentTaskRuns: [UUID: RunRecord] = [:]
    @Published private(set) var taskRunLookupFailed = false
    @Published private(set) var selectedID: UUID?
    @Published private(set) var messages: [PersistedMessage] = []
    @Published private(set) var hasEarlierMessages = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isLoadingEarlierMessages = false
    @Published private(set) var historyLoadFailed = false
    @Published private(set) var pendingPrompt: String?
    @Published private(set) var streamedText = ""
    /// Durable project workspaces for task selection; nil selection means
    /// "all tasks". Selection never changes a task's immutable workspace.
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published private(set) var selectedWorkspaceID: UUID?
    /// Files staged for the next send; cleared once a run starts.
    @Published private(set) var stagedAttachments: [HostAgentAttachmentDraft] = []
    /// Live projection of the active run; nil when no run owns the composer.
    @Published private(set) var runPhase: FloeMacSelfSessionPhase?
    @Published private(set) var pendingApproval: HostAgentApproval?
    @Published private(set) var isResolvingApproval = false
    @Published private(set) var workspaceRevision = UUID()
    @Published private(set) var rejectedPrompt: String?
    @Published private(set) var plan: PlanDraft?
    @Published private(set) var goal: ConversationGoal?
    @Published private(set) var isAcceptingPlan = false
    @Published var notice: String?
    private(set) var storageErrorKind: String?

    /// Staged file ceiling. Inline content has narrower runtime limits.
    static let maximumAttachmentBytes = 32 * 1_024 * 1_024
    /// Mirrors the runtime's per-run attachment ceiling.
    static let maximumStagedAttachmentCount = 8
    /// Inline images above this size never reach the model; staging matches
    /// the runtime's image inlining bound instead of staging a file that
    /// would silently degrade.
    static let maximumInlineImageBytes = 8 * 1_024 * 1_024
    /// Key material and certificate exports are never staged: they are
    /// reference secrets, not model or task content.
    static let blockedAttachmentExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "der", "cer", "crt", "keystore",
        "jks", "asc", "gpg", "kdbx", "ppk", "mobileprovision"
    ]

    /// Saved provider records (list order). Records are validated on load;
    /// corrupt entries are dropped and the cleaned list is written back.
    @Published private(set) var providers: [HostAgentProvider] = []
    /// The provider `send` uses for new runs. Nil only when no provider
    /// exists or the Keychain is unavailable.
    @Published private(set) var selectedProviderID: UUID?

    private let supportDirectory: URL
    private let namespace: String
    private let vault: KeychainStore?
    private let admitWork: AdmitWork
    private var runtime: FloeMacSelfRuntime?
    private var activeRun: FloeMacSelfSessionHandle?
    #if FLOE_UNIFIED_MAC
    private var isSynchronizingCloudModels = false
    #endif
    #if FLOE_MAC_HOST_SMOKE
    private(set) var smokeRunDiagnostics: [String] = []
    #endif
    private var taskRunLookup = UUID()
    private var historySelection = UUID()
    private var earlierMessageCursor: ConversationMessageCursor?
    private static let settingsAccount = "selected-chat-provider.v1"
    private static let providerListAccount = "chat-providers.v2"
    private static let currentProviderListVersion = 1

    init(supportDirectory: URL, namespace: String, useKeychain: Bool = true,
         admitWork: @escaping AdmitWork = { {} }) {
        self.supportDirectory = supportDirectory
        self.namespace = namespace
        self.vault = useKeychain ? KeychainStore(service: namespace + ".chat",
            synchronizable: false, accessibility: .whenUnlockedThisDeviceOnly) : nil
        self.admitWork = admitWork
    }

    func prepare() async {
        guard !isReady, !isPreparing, !isTerminating else { return }
        guard let release = admit() else { return }
        isPreparing = true
        storageErrorKind = nil
        notice = nil
        defer { isPreparing = false; release() }
        do {
            if runtime == nil {
                runtime = try HostAgentDatabase.open(applicationSupport: supportDirectory, namespace: namespace)
            }
            guard let runtime else { return }
            try await runtime.bootstrap()
            // Archived tasks stay out of the workspace; they are only
            // reachable again after an explicit restore.
            conversations = try await runtime.conversations(includeArchived: true)
            workspaces = try await runtime.workspaces()
            if let recent = conversations.first(where: { $0.isVisibleInOrdinaryList }) {
                selectedID = recent.id
                applyHistory(try await runtime.conversationMessagePage(conversationID: recent.id))
                await loadPlanning(conversationID: recent.id, runtime: runtime)
            }
            isReady = true
            reloadProviders()
        } catch {
            if let error = error as? HostAgentDatabase.StorageError {
                storageErrorKind = error.rawValue
            } else if let error = error as? FloeMacSelfCoreError {
                storageErrorKind = error.code
            } else {
                storageErrorKind = "historyUnavailable"
            }
            notice = String(localized: "host.chat.storageUnavailable")
        }
    }

    /// Single-profile form used by the nonunified host. Keeps the 1.3.0
    /// behavior in list terms: update the selected provider when one exists,
    /// otherwise create it and make it the selected provider.
    func saveProvider(endpoint: String, protocolKind: ModelProtocol, modelID: String, key: String) -> Bool {
        updateProviderStore { store in
            var record = try HostAgentProvider(endpoint: endpoint, protocolKind: protocolKind,
                                               modelID: modelID, apiKey: key)
            if let selected = store.selectedProviderID,
               let index = store.providers.firstIndex(where: { $0.profile.id == selected }) {
                record.profile.id = selected
                record.model.id = store.providers[index].model.id
                record.model.providerID = selected
                record.model.capabilities = store.providers[index].model.capabilities
                store.providers[index] = record
            } else if !store.providers.isEmpty {
                let existing = store.providers[0].profile.id
                record.profile.id = existing
                record.model.id = store.providers[0].model.id
                record.model.providerID = existing
                record.model.capabilities = store.providers[0].model.capabilities
                store.providers[0] = record
                store.selectedProviderID = existing
            } else {
                store.providers = [record]
                store.selectedProviderID = record.profile.id
            }
        }
    }

    /// Adds a provider and makes it the selected one for chat.
    @discardableResult
    func addProvider(name: String?, endpoint: String, protocolKind: ModelProtocol,
                     modelID: String, key: String, supportsImages: Bool = false, supportsTools: Bool = false,
                     presetID: String? = nil) -> Bool {
        updateProviderStore { store in
            let record = try HostAgentProvider(displayName: name, endpoint: endpoint,
                                               protocolKind: protocolKind, modelID: modelID, apiKey: key, supportsImages: supportsImages, supportsTools: supportsTools, presetID: presetID)
            store.providers.append(record)
            store.selectedProviderID = record.profile.id
        }
    }

    /// Replaces the record at `id`, keeping its identity so existing
    /// selections and conversations stay bound to the same provider.
    @discardableResult
    func updateProvider(id: UUID, name: String?, endpoint: String, protocolKind: ModelProtocol,
                        modelID: String, key: String, supportsImages: Bool = false, supportsTools: Bool = false,
                        presetID: String? = nil) -> Bool {
        updateProviderStore { store in
            guard let index = store.providers.firstIndex(where: { $0.profile.id == id }) else {
                throw ProviderStoreError.missingRecord
            }
            let previous = store.providers[index]
            var record = try HostAgentProvider(displayName: name, endpoint: endpoint,
                                               protocolKind: protocolKind, modelID: modelID, apiKey: key, supportsImages: supportsImages, supportsTools: supportsTools, presetID: presetID)
            record.profile.id = id
            if previous.profile.baseURL == record.profile.baseURL && previous.profile.wireProtocol == protocolKind {
                record.profile.kind = previous.profile.kind
                record.profile.region = previous.profile.region
                record.profile.nonSecretHeaders = previous.profile.nonSecretHeaders
                record.profile.toolNameCompatibility = previous.profile.toolNameCompatibility
                if previous.model.remoteModelID == record.model.remoteModelID {
                    let editable: ModelCapabilities = [.vision, .tools]
                    let selectedCapabilities = record.model.capabilities.intersection(editable)
                    var model = previous.model
                    let changed = model.capabilities.intersection(editable).symmetricDifference(selectedCapabilities)
                    model.capabilities.subtract(editable)
                    model.capabilities.formUnion(selectedCapabilities)
                    if !changed.isEmpty {
                        model.explicitCapabilities = (model.explicitCapabilities ?? []).union(changed)
                    }
                    record.model = model
                }
            }
            record.model.id = previous.model.id
            record.model.providerID = id
            store.providers[index] = record
        }
    }

    #if FLOE_UNIFIED_MAC
    func synchronizeCloudModels(publishing providerID: UUID? = nil) async throws -> [MacCloudModelEntry] {
        guard vault != nil, isReady, !isSending, !isTerminating, !isSynchronizingCloudModels,
              let release = admit() else { throw MacICloudModelError.temporarilyUnavailable }
        isSynchronizingCloudModels = true
        defer { isSynchronizingCloudModels = false; release() }
        let entry: MacCloudModelEntry?
        if let providerID {
            guard let record = providers.first(where: { $0.profile.id == providerID }),
                  record.apiKey.isEmpty || !record.profile.baseURL.absoluteString.contains(record.apiKey),
                  MacCloudModelEntry.accepts(record.profile, model: record.model) else {
                throw MacICloudModelError.invalidProvider
            }
            var profile = record.profile
            profile.presetID = record.presetID ?? profile.presetID
            entry = .init(provider: profile, model: record.model)
        } else {
            entry = nil
        }
        let service = MacICloudModelSync(applicationSupport: supportDirectory, namespace: namespace)
        return try await service.synchronize(publishing: entry)
    }

    func importCloudModel(_ entry: MacCloudModelEntry) -> Bool {
        guard !isSynchronizingCloudModels, MacCloudModelEntry.accepts(entry.provider, model: entry.model) else {
            return false
        }
        return updateProviderStore { store in
            var base = entry.provider
            base.secretRef = nil
            let index = store.providers.firstIndex { $0.profile.id == base.id }
            let previous = index.map { store.providers[$0] }
            let sameConnection = previous?.profile.baseURL == base.baseURL
                && previous?.profile.wireProtocol == base.wireProtocol && previous?.profile.kind == base.kind
            var record = try HostAgentProvider(displayName: base.displayName, endpoint: base.baseURL.absoluteString,
                                              protocolKind: base.wireProtocol, modelID: entry.model.remoteModelID,
                                              apiKey: sameConnection ? previous?.apiKey ?? "" : "",
                                              presetID: base.presetID)
            record.profile = base
            record.model = entry.model
            if let index {
                store.providers[index] = record
            } else {
                store.providers.append(record)
            }
        }
    }
    #endif

    /// Removes the record and its stored key. Chat history is kept; when the
    /// removed provider was selected, the first remaining one takes over.
    @discardableResult
    func removeProvider(id: UUID) -> Bool {
        updateProviderStore { store in
            store.providers.removeAll { $0.profile.id == id }
            if store.selectedProviderID == id {
                store.selectedProviderID = store.providers.first?.profile.id
            }
        }
    }

    /// Chooses which provider `send` uses for new runs.
    @discardableResult
    func selectChatProvider(id: UUID?) -> Bool {
        updateProviderStore { store in
            if let id {
                guard store.providers.contains(where: { $0.profile.id == id }) else {
                    throw ProviderStoreError.missingRecord
                }
            }
            store.selectedProviderID = id
        }
    }

    func select(_ id: UUID?) async {
        guard isReady, !isSending, !isTerminating, !isAcceptingPlan, let runtime else { return }
        guard let release = admit() else { return }
        defer { release() }
        let selection = UUID()
        historySelection = selection
        isLoadingHistory = id != nil
        isLoadingEarlierMessages = false
        historyLoadFailed = false
        applyHistory(.init(messages: [], earlierCursor: nil, hasEarlier: false))
        selectedID = id
        plan = nil
        goal = nil
        notice = nil
        guard let id else { return }
        defer {
            if historySelection == selection { isLoadingHistory = false }
        }
        do {
            let page = try await runtime.conversationMessagePage(conversationID: id)
            guard historySelection == selection, !Task.isCancelled else { return }
            applyHistory(page)
            await loadPlanning(conversationID: id, runtime: runtime)
        } catch {
            if historySelection == selection, !Task.isCancelled { historyLoadFailed = true }
        }
    }

    func loadEarlierMessages() async {
        guard let id = selectedID, let cursor = earlierMessageCursor, hasEarlierMessages,
              !isLoadingHistory, !isLoadingEarlierMessages, !isSending, !isTerminating,
              let runtime, let release = admit() else { return }
        let selection = historySelection
        isLoadingEarlierMessages = true
        defer {
            if historySelection == selection { isLoadingEarlierMessages = false }
            release()
        }
        do {
            let page = try await runtime.conversationMessagePage(conversationID: id, before: cursor)
            guard historySelection == selection, !isSending, !Task.isCancelled else { return }
            messages.insert(contentsOf: page.messages, at: 0)
            earlierMessageCursor = page.earlierCursor
            hasEarlierMessages = page.hasEarlier
        } catch {
            if historySelection == selection, !Task.isCancelled {
                notice = String(localized: "host.chat.historyUnavailable")
            }
        }
    }

    func transcript(conversationID: UUID) async throws -> [PersistedMessage] {
        guard let runtime, isReady, !isSending, !isTerminating,
              conversations.contains(where: { $0.id == conversationID && $0.isVisibleInOrdinaryList }),
              let release = admit() else { throw CancellationError() }
        defer { release() }
        return try await runtime.conversationTranscript(conversationID: conversationID)
    }

    func withSavedAttachment(id: UUID, conversationID: UUID, use: (URL) -> Void) async {
        guard let runtime, selectedID == conversationID, !isTerminating,
              let release = admit() else { return }
        let selection = historySelection
        defer { release() }
        do {
            guard let attachment = try await runtime.conversationAttachment(id: id, conversationID: conversationID),
                  attachment.storage == .securityScopedBookmark, let bookmark = attachment.urlBookmark else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard historySelection == selection, selectedID == conversationID, !Task.isCancelled else { return }
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileNoSuchFile)
            }
            use(url)
        } catch {
            if historySelection == selection, !Task.isCancelled {
                notice = String(localized: "mac.workspace.attachmentUnavailable")
            }
        }
    }

    private func applyHistory(_ page: ConversationMessagePage, retainingVisibleHistory: Bool = false) {
        if retainingVisibleHistory, let first = page.messages.first,
           let overlap = messages.firstIndex(where: { $0.id == first.id }) {
            messages = Array(messages.prefix(upTo: overlap)) + page.messages
            return
        }
        messages = page.messages
        earlierMessageCursor = page.earlierCursor
        hasEarlierMessages = page.hasEarlier
    }

    /// Chooses the project workspace shown for task selection. Nil shows
    /// every task. This never rebinds an existing conversation: a task's
    /// workspace is fixed after its first message.
    func selectWorkspace(_ id: UUID?) {
        guard isReady, !isSending, !isTerminating else { return }
        selectedWorkspaceID = id
    }

    /// Registers a project workspace for an explicitly picked local folder.
    /// The runtime is idempotent per resolved root path: re-adding the same
    /// folder returns the existing record instead of creating a duplicate.
    @discardableResult
    func addWorkspace(name: String, rootURL: URL) async -> Bool {
        guard let runtime, isReady, !isSending, !isTerminating,
              let release = admit() else { return false }
        defer { release() }
        do {
            let bookmark = try rootURL.bookmarkData(options: [
                .withSecurityScope, .securityScopeAllowOnlyReadAccess
            ])
            let record = try await runtime.registerWorkspace(name: name, rootBookmark: bookmark)
            workspaces = try await runtime.workspaces()
            // Select the durable record the runtime actually bound: for an
            // already-registered folder this is the existing workspace id.
            selectedWorkspaceID = record.id
            return true
        } catch {
            notice = String(
                localized: "host.chat.workspaceSaveFailed",
                defaultValue: "The workspace could not be saved."
            )
            return false
        }
    }

    /// Stages picked files for the next send. Only regular files that open
    /// for reading, produce a read-only security-scoped bookmark, and pass
    /// the bounded size/type rules are staged; duplicates of an already
    /// staged path are ignored. The bounded read fetches at most the ceiling
    /// plus one byte so an oversized file is rejected without being fully
    /// loaded. The returned array lists exactly what was staged.
    @discardableResult
    func stageAttachments(_ urls: [URL]) -> [HostAgentAttachmentDraft] {
        guard isReady, !isSending, !isTerminating else { return [] }
        var staged: [HostAgentAttachmentDraft] = []
        var stagedPaths = Set(stagedAttachments.map {
            $0.url.resolvingSymlinksInPath().standardizedFileURL
        })
        for url in urls {
            guard stagedAttachments.count + staged.count < Self.maximumStagedAttachmentCount else { break }
            let pathExtension = url.pathExtension.lowercased()
            guard !pathExtension.isEmpty,
                  !Self.blockedAttachmentExtensions.contains(pathExtension) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            guard let bookmark = try? url.bookmarkData(options: [
                .withSecurityScope, .securityScopeAllowOnlyReadAccess
            ]) else { continue }
            var stale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale else { continue }
            let standardized = resolved.resolvingSymlinksInPath().standardizedFileURL
            guard stagedPaths.insert(standardized).inserted else { continue }
            // Read at most the document ceiling plus one byte; anything
            // larger is skipped before the image classification read.
            guard let head = Self.boundedContents(of: resolved, limit: Self.maximumAttachmentBytes),
                  !head.isEmpty else { continue }
            let rasterMIME = Self.rasterImageMIME(head)
            let kind: HostAgentAttachmentDraft.Kind = rasterMIME == nil ? .document : .image
            // Images must satisfy the stricter inline bound or they would
            // stage as model-visible drafts that the runtime then drops.
            if kind == .image, head.count > Self.maximumInlineImageBytes { continue }
            staged.append(HostAgentAttachmentDraft(
                id: UUID(),
                kind: kind,
                url: resolved,
                bookmark: bookmark,
                displayName: url.lastPathComponent,
                byteCount: head.count,
                sha256: FloeDigest.sha256Hex(head),
                uti: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data"
            ))
        }
        guard !staged.isEmpty else { return [] }
        stagedAttachments.append(contentsOf: staged)
        return staged
    }

    /// Reads at most `limit` bytes from one exact path. The descriptor is
    /// opened `O_NOFOLLOW | O_NONBLOCK` (a swapped-in symlink or FIFO can
    /// neither redirect the read nor block the staging UI) and `fstat` must
    /// confirm a regular file before any byte is read.
    private static func boundedContents(of url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(status.st_size))))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= limit {
            let readCount = read(fd, &buffer, buffer.count)
            guard readCount > 0 else { break }
            data.append(contentsOf: buffer[0..<readCount])
        }
        guard !data.isEmpty, data.count <= limit else { return nil }
        return data
    }

    func unstageAttachment(_ id: UUID) {
        stagedAttachments.removeAll { $0.id == id }
    }

    func clearStagedAttachments() {
        stagedAttachments.removeAll()
    }

    /// Raster signatures accepted by the runtime's image inlining. Kept in
    /// sync with the upstream normalizer; non-raster files stage as
    /// durable-only documents.
    private static func rasterImageMIME(_ data: Data) -> String? {
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.count >= 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if data.count >= 6, data.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return "image/webp" }
        return nil
    }

    /// Renames or pins a saved conversation through the runtime and reloads
    /// the list on success. False means the change was not applied; callers
    /// surface their own message.
    @discardableResult
    func changeConversationMetadata(id: UUID,
                                    change: FloeMacSelfRuntime.ConversationMetadataChange) async -> Bool {
        guard let runtime, isReady, !isSending, !isTerminating,
              let release = admit() else { return false }
        defer { release() }
        do {
            try await runtime.changeConversationMetadata(id: id, change: change)
            conversations = try await runtime.conversations(includeArchived: true)
            return true
        } catch {
            return false
        }
    }

    func loadTaskRuns() async {
        guard let runtime, isReady, let release = admit() else { return }
        defer { release() }
        let lookup = UUID()
        taskRunLookup = lookup
        let ids = conversations.filter {
            $0.purpose == .ordinary && $0.visibility == .normal && $0.editorOwnership == nil
        }.map(\.id)
        do {
            let records = try await runtime.latestRuns(conversationIDs: ids)
            guard !Task.isCancelled, lookup == taskRunLookup else { return }
            recentTaskRuns = records
            taskRunLookupFailed = false
        } catch {
            if !Task.isCancelled, lookup == taskRunLookup { taskRunLookupFailed = true }
        }
    }

    /// A new task can bind to a project before its first run. An existing
    /// task keeps its original workspace when the sidebar selection changes.
    @discardableResult
    func send(_ goal: String, workspaceID: UUID? = nil, mode: HostAgentMode = .chat,
              criterion: String = "") -> Bool {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runtime, isReady, !isSending, !isTerminating, !isAcceptingPlan,
              !isLoadingHistory, !historyLoadFailed, !text.isEmpty else { return false }
        do {
            guard let config = try configuration() else {
                notice = String(localized: "host.chat.configureFirst")
                return false
            }
            guard config.model.capabilities.contains(.vision) || !stagedAttachments.contains(where: { $0.kind == .image }) else {
                notice = String(localized: "mac.workspace.selectVisionModel")
                return false
            }
            guard mode == .chat || config.model.capabilities.contains(.tools) else {
                notice = String(localized: "mac.agent.toolsModelRequired")
                return false
            }
            return beginSend(text, runtime: runtime, provider: config.binding(), workspaceID: workspaceID,
                             mode: mode, criterion: criterion.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
            return false
        }
    }

    private func beginSend(_ text: String, runtime: FloeMacSelfRuntime,
                           provider: FloeMacSelfProviderBinding,
                           workspaceID: UUID? = nil, mode: HostAgentMode = .chat, criterion: String = "",
                           acceptedPlan: PlanConfirmationSnapshot? = nil) -> Bool {
        let currentID = selectedID
        let currentGoal = mode == .goal && criterion.isEmpty && goal?.conversationID == currentID ? goal : nil
        let selectedProject = workspaces.first { $0.id == workspaceID && $0.kind == .project }
        let requiresProject = mode == .agent || mode == .plan
        if requiresProject && currentID == nil && selectedProject == nil {
            notice = String(localized: "mac.agent.projectRequired")
            return false
        }
        guard let release = admit() else { return false }
        isSending = true
        notice = nil
        rejectedPrompt = nil
        pendingPrompt = acceptedPlan == nil ? text : nil
        let drafts = stagedAttachments
        if !drafts.isEmpty { stagedAttachments = [] }
        Task {
            var admitted = false
            defer {
                isSending = false
                runPhase = nil
                activeRun = nil
                pendingApproval = nil
                pendingPrompt = nil
                streamedText = ""
                release()
            }
            do {
                let tools: FloeMacSelfToolBinding?
                #if FLOE_UNIFIED_MAC
                let project: WorkspaceRecord?
                if mode != .chat, let currentID {
                    let owner = try await runtime.workspaceForConversation(currentID)
                    project = owner?.kind == .project ? owner : nil
                } else {
                    project = selectedProject
                }
                if requiresProject && project == nil {
                    stagedAttachments = drafts
                    rejectedPrompt = text
                    notice = String(localized: "mac.agent.projectRequired")
                    return
                }
                if let project, mode != .chat {
                    tools = try MacAgentWorkspaceTools.binding(workspace: project, readOnly: mode == .plan)
                } else {
                    tools = nil
                }
                #else
                let project = selectedProject
                tools = nil
                #endif
                let acceptedExecution: FloeMacSelfAcceptedPlanExecution?
                if let acceptedPlan, let currentID {
                    acceptedExecution = try await runtime.prepareAcceptedPlanExecution(acceptedPlan, conversationID: currentID)
                } else {
                    acceptedExecution = nil
                }
                let expectedGoal: FloeMacSelfExpectedGoal?
                if let goalID = acceptedExecution?.goalID, let revision = acceptedExecution?.goalRevision {
                    expectedGoal = .init(id: goalID, revision: revision)
                } else if let currentGoal {
                    expectedGoal = .init(id: currentGoal.id, revision: currentGoal.revision ?? 1)
                } else {
                    expectedGoal = nil
                }
                let request = FloeMacSelfSessionRequest(
                    conversationID: currentID,
                    workspaceID: tools == nil ? workspaceID : project?.id,
                    goal: acceptedExecution?.goal ?? text,
                    mode: acceptedExecution?.conversationMode ?? mode.runtimeMode,
                    runID: acceptedExecution?.runID,
                    context: FloeMacSelfRunContext(workspaceName: project?.name),
                    attachments: drafts.map {
                        FloeMacSelfSessionAttachment(
                            id: $0.id,
                            kind: $0.kind == .image ? .image : .document,
                            displayName: $0.displayName,
                            uti: $0.uti,
                            byteCount: $0.byteCount,
                            sha256: $0.sha256,
                            bookmark: $0.bookmark
                        )
                    },
                    chatFastMode: mode == .chat,
                    goalCriteria: mode == .goal && !criterion.isEmpty ? [criterion] : [],
                    reusingUserMessageID: acceptedExecution?.userMessageID,
                    expectedGoal: expectedGoal
                )
                let handle = try await runtime.startSession(request, provider: provider, tools: tools)
                admitted = true
                activeRun = handle
                selectedID = handle.identity.conversationID
                runPhase = await handle.phase()
                let events = handle.events()
                await updateLiveRun(handle)
                for await event in events {
                    await updateLiveRun(handle)
                    runPhase = await handle.phase()
                    switch event {
                    case .harness(.planChanged), .harness(.goalChanged):
                        await loadPlanning(conversationID: handle.identity.conversationID, runtime: runtime)
                    default:
                        break
                    }
                }
                let terminal = await handle.waitForTerminal()
                #if FLOE_MAC_HOST_SMOKE
                if vault == nil {
                    smokeRunDiagnostics.append("\(mode.rawValue): \(String(describing: terminal?.outcome))")
                    if terminal?.outcome == .failed || terminal?.outcome == .blocked,
                       let events = try? await handle.durableEvents(limit: 100) {
                        smokeRunDiagnostics.append(contentsOf: events.suffix(8).map(\.payloadJSON))
                    }
                }
                #endif
                let page = try await runtime.conversationMessagePage(conversationID: handle.identity.conversationID)
                applyHistory(page, retainingVisibleHistory: true)
                conversations = try await runtime.conversations(includeArchived: true)
                workspaces = try await runtime.workspaces()
                if mode == .plan || mode == .goal {
                    await loadPlanning(conversationID: handle.identity.conversationID, runtime: runtime)
                }
                if tools != nil { workspaceRevision = UUID() }
                pendingPrompt = nil
                streamedText = ""
                guard let terminal, terminal.confirmed else {
                    notice = String(localized: "host.chat.unconfirmed")
                    return
                }
                _ = try await handle.close()
                if terminal.outcome == .failed || terminal.outcome == .blocked {
                    notice = String(localized: "host.chat.runFailed")
                }
            } catch {
                // User input and provider errors can contain private material.
                // Show the action that failed and preserve the draft for retry.
                if !admitted {
                    stagedAttachments = drafts
                    if acceptedPlan == nil { rejectedPrompt = text }
                }
                #if FLOE_MAC_HOST_SMOKE
                if vault == nil { smokeRunDiagnostics.append("\(mode.rawValue): \(error)") }
                #endif
                notice = String(localized: "host.chat.runFailed")
            }
        }
        return true
    }

    private func loadPlanning(conversationID: UUID, runtime: FloeMacSelfRuntime) async {
        do {
            let latest = try await runtime.latestPlan(conversationID: conversationID)
            let goals = try await runtime.goals(conversationID: conversationID)
            guard selectedID == conversationID else { return }
            plan = latest
            goal = goals.first { !$0.status.isTerminal } ?? goals.first
        } catch {
            if selectedID == conversationID { notice = String(localized: "mac.agent.planningLoadFailed") }
        }
    }

    func acceptPlan(_ candidate: PlanDraft) async -> Bool {
        guard isReady, let runtime, !isSending, !isTerminating, !isAcceptingPlan,
              candidate == plan, selectedID == candidate.conversationID, let release = admit() else { return false }
        isAcceptingPlan = true
        defer { isAcceptingPlan = false; release() }
        do {
            _ = try await runtime.acceptPlan(candidate, conversationID: candidate.conversationID, execution: .normal)
            messages = try await runtime.conversationMessages(conversationID: candidate.conversationID)
            await loadPlanning(conversationID: candidate.conversationID, runtime: runtime)
            return plan?.status == .accepted
        } catch {
            #if FLOE_MAC_HOST_SMOKE
            if vault == nil { smokeRunDiagnostics.append("acceptPlan: \(error)") }
            #endif
            await loadPlanning(conversationID: candidate.conversationID, runtime: runtime)
            notice = String(localized: "mac.agent.planAcceptFailed")
            return false
        }
    }

    var pendingAcceptedPlan: PlanConfirmationSnapshot? {
        guard let plan, plan.status == .accepted else { return nil }
        return messages.reversed().lazy.filter { $0.runID == nil }
            .compactMap(PlanConfirmationSnapshot.from(message:))
            .first { $0.plan.id == plan.id && $0.plan.revision == plan.revision }
    }

    func runAcceptedPlan(_ saved: PlanConfirmationSnapshot) {
        guard isReady, let runtime, !isSending, !isTerminating, !isAcceptingPlan,
              saved == pendingAcceptedPlan, selectedID == saved.plan.conversationID,
              stagedAttachments.isEmpty else { return }
        do {
            guard let config = try configuration(), config.model.capabilities.contains(.tools) else {
                notice = String(localized: "mac.agent.toolsModelRequired")
                return
            }
            _ = beginSend(saved.executionPrompt, runtime: runtime, provider: config.binding(), mode: .agent,
                          acceptedPlan: saved)
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
        }
    }

    private func updateLiveRun(_ handle: FloeMacSelfSessionHandle) async {
        let snapshot = await handle.snapshot()
        guard activeRun?.identity == handle.identity else { return }
        streamedText = snapshot?.streamedText ?? ""
        guard let call = snapshot?.pendingApproval?.toolCall else {
            pendingApproval = nil
            return
        }
        let preview: (path: String?, text: String?, previousText: String?)
        #if FLOE_UNIFIED_MAC
        let decoder = JSONDecoder()
        switch call.toolName {
        case MacAgentWorkspaceCreateFileTool.name:
            let args = try? decoder.decode(MacAgentWorkspaceCreateFileTool.Arguments.self, from: call.argumentsJSON)
            preview = (args?.path, args?.content, nil)
        case MacAgentWorkspaceReplaceTextTool.name:
            let args = try? decoder.decode(MacAgentWorkspaceReplaceTextTool.Arguments.self, from: call.argumentsJSON)
            preview = (args?.path, args?.newText, args?.oldText)
        default:
            preview = (nil, nil, nil)
        }
        #else
        preview = (nil, nil, nil)
        #endif
        let card = HostAgentApproval(conversationID: handle.identity.conversationID,
                                     runID: handle.identity.runID, workspaceID: handle.identity.workspaceID,
                                     callID: call.id, toolName: call.toolName, path: preview.path,
                                     text: preview.text, previousText: preview.previousText)
        if pendingApproval != card { pendingApproval = card }
    }

    func resolveApproval(_ approval: HostAgentApproval, allow: Bool) async {
        guard isSending, !isStopping, !isResolvingApproval, !isTerminating,
              pendingApproval == approval, let handle = activeRun,
              handle.identity.runID == approval.runID, !allow || approval.path != nil,
              let release = admit() else { return }
        isResolvingApproval = true
        defer { isResolvingApproval = false; release() }
        let decision: ApprovalDecision = allow
            ? .allow(scope: ApprovalScope(toolName: approval.toolName, singleUse: true), expiresAt: nil)
            : .deny(reason: "User declined this workspace operation.")
        let result = await handle.resolveApproval(.init(conversationID: approval.conversationID,
            runID: approval.runID, workspaceID: approval.workspaceID, callID: approval.callID,
            toolName: approval.toolName, decision: decision))
        guard activeRun?.identity == handle.identity else { return }
        if result == .accepted, pendingApproval == approval { pendingApproval = nil }
        await updateLiveRun(handle)
        if result != .accepted, pendingApproval == approval {
            notice = String(localized: "mac.agent.approvalFailed")
        }
    }

    func stop() {
        guard let activeRun, !isStopping else { return }
        guard let release = admit() else { return }
        isStopping = true
        Task {
            defer { isStopping = false; release() }
            let cancellation = await activeRun.cancelAndWait()
            if cancellation.terminal?.confirmed != true {
                notice = String(localized: "host.chat.unconfirmed")
            }
        }
    }

    var canStop: Bool { activeRun != nil && !isStopping }

    func beginTermination() -> Bool {
        guard !isSending, !isPreparing, !isStopping, !isAcceptingPlan else { return false }
        isTerminating = true
        return true
    }

    func cancelTermination() {
        isTerminating = false
    }

    func finishTermination() async throws {
        if let runtime { _ = try await runtime.shutdown(cancelActive: false) }
        runtime = nil
        isReady = false
    }

    func removeSmokeStoreAfterTermination() {
        guard vault == nil, isTerminating, runtime == nil else { return }
        try? FileManager.default.removeItem(at: supportDirectory)
    }

    private func configuration() throws -> HostAgentProvider? {
        guard let vault else { return nil }
        let store = try loadProviderStore()
        return store.providers.first(where: { $0.profile.id == store.selectedProviderID })
            ?? store.providers.first
    }

    // MARK: - Provider store

    /// Reads the persisted list, migrating the 1.3.0 single-profile account
    /// on first use. Reads are non-destructive: invalid or duplicate records
    /// fail closed (surfaced as the existing Keychain-unavailable notice)
    /// and the stored bytes are never rewritten by a read.
    private func loadProviderStore() throws -> ProviderListEnvelope {
        guard let vault else { return Self.emptyProviderStore() }
        let envelope: ProviderListEnvelope
        do {
            let encoded = try vault.read(account: Self.providerListAccount)
            let decoded = try JSONDecoder().decode(ProviderListEnvelope.self, from: encoded)
            guard decoded.version <= Self.currentProviderListVersion else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "newer provider list version \(decoded.version)"))
            }
            envelope = decoded
        } catch KeychainStoreError.itemNotFound {
            return try migrateLegacyProviderStore()
        }
        try validateProviderEnvelope(envelope)
        return recoverLegacySelectionIfNeeded(envelope)
    }

    /// Imports the legacy single-profile record without deleting it: the
    /// envelope is written so later launches read the list directly, while
    /// the legacy account remains as the downgrade mirror and as the
    /// recovery source when the list has no selected profile.
    private func migrateLegacyProviderStore() throws -> ProviderListEnvelope {
        guard let vault else { return Self.emptyProviderStore() }
        do {
            let encoded = try vault.read(account: Self.settingsAccount)
            let record = try JSONDecoder().decode(HostAgentProvider.self, from: encoded)
            try record.validate()
            let envelope = ProviderListEnvelope(version: Self.currentProviderListVersion,
                                                providers: [record], selectedProviderID: record.profile.id)
            try persistProviderStore(envelope)
            return envelope
        } catch KeychainStoreError.itemNotFound {
            return Self.emptyProviderStore()
        }
    }

    /// Every record must validate and IDs must be unique. A violation makes
    /// the whole list unreadable on purpose: the bytes stay untouched for
    /// repair instead of being silently rewritten under changed validation
    /// rules or dropped by a read.
    private func validateProviderEnvelope(_ envelope: ProviderListEnvelope) throws {
        var seen = Set<UUID>()
        for record in envelope.providers {
            try record.validate()
            guard seen.insert(record.profile.id).inserted,
                  record.model.providerID == record.profile.id else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "duplicate or inconsistent provider record"))
            }
        }
    }

    /// Read-only recovery: when the persisted list names no selected
    /// profile, the legacy 1.3.0 account may still hold one. The envelope
    /// bytes stay untouched; the recovery lives only in memory until the
    /// next successful save.
    private func recoverLegacySelectionIfNeeded(_ envelope: ProviderListEnvelope) -> ProviderListEnvelope {
        guard envelope.selectedProviderID == nil else { return envelope }
        guard let vault,
              let encoded = try? vault.read(account: Self.settingsAccount),
              let record = try? JSONDecoder().decode(HostAgentProvider.self, from: encoded),
              (try? record.validate()) != nil else { return envelope }
        var recovered = envelope
        if !recovered.providers.contains(where: { $0.profile.id == record.profile.id }) {
            recovered.providers.append(record)
        }
        recovered.selectedProviderID = record.profile.id
        return recovered
    }

    /// Canonical list commit first; the 1.3.0 legacy mirror is best-effort
    /// afterwards so a mirror failure cannot fail an already-committed save.
    private func persistProviderStore(_ store: ProviderListEnvelope) throws {
        guard let vault else { return }
        let encoder = JSONEncoder()
        try vault.store(account: Self.providerListAccount, secret: encoder.encode(store))
        if let selected = store.providers.first(where: { $0.profile.id == store.selectedProviderID }) {
            try? vault.store(account: Self.settingsAccount, secret: encoder.encode(selected))
        } else {
            // No selected profile (e.g. the last provider was removed):
            // clear the mirror so the legacy recovery path cannot resurrect
            // a record the user deleted.
            try? vault.delete(account: Self.settingsAccount)
        }
    }

    private static func emptyProviderStore() -> ProviderListEnvelope {
        ProviderListEnvelope(version: currentProviderListVersion, providers: [], selectedProviderID: nil)
    }

    private func reloadProviders() {
        guard let vault else {
            providers = []
            selectedProviderID = nil
            modelName = nil
            return
        }
        do {
            applyProviderStore(try loadProviderStore())
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
        }
    }

    private func applyProviderStore(_ store: ProviderListEnvelope) {
        providers = store.providers
        selectedProviderID = store.selectedProviderID
        modelName = store.providers.first { $0.profile.id == store.selectedProviderID }
            .map { $0.profile.displayName ?? $0.model.displayName }
    }

    /// Serialized list mutation: load, mutate, persist, then republish. Any
    /// Keychain read/write or decode failure leaves the stored bytes
    /// untouched and reports the existing local error notices.
    @discardableResult
    private func updateProviderStore(_ mutation: (inout ProviderListEnvelope) throws -> Void) -> Bool {
        guard let vault, !isSending, !isTerminating else { return false }
        guard let release = admit() else { return false }
        defer { release() }
        do {
            var store = try loadProviderStore()
            try mutation(&store)
            try persistProviderStore(store)
            applyProviderStore(store)
            notice = nil
            return true
        } catch is KeychainStoreError, is DecodingError {
            notice = String(localized: "host.chat.keychainUnavailable")
            return false
        } catch {
            notice = String(localized: "host.chat.providerSaveFailed")
            return false
        }
    }

    // MARK: - Model discovery

    /// Live result state for the provider editor's model listing. Results
    /// come straight from the endpoint's own listing through the shared
    /// factory adapter; nothing is invented locally.
    enum HostModelDiscoveryState: Equatable {
        /// No request yet, or the draft fields are not ready (blank endpoint
        /// or a key still required before discovery may run).
        case idle
        case discovering
        case succeeded(modelCount: Int)
        /// The endpoint publishes no model listing (subscription gateways):
        /// manual model entry is the honest path.
        case listingUnavailable
        /// Redacted, localized failure the editor shows next to the manual
        /// model field.
        case failed(String)
    }

    /// Live model candidates for the editor's current draft fields. Every
    /// entry keeps the capability metadata the endpoint reported.
    @Published private(set) var discoveredModels: [ModelProfile] = []
    @Published private(set) var modelDiscoveryState: HostModelDiscoveryState = .idle

    /// Debounce for automatic discovery while the user types.
    static let modelDiscoveryDebounceNanoseconds: UInt64 = 600_000_000
    private var modelDiscoveryGeneration: UInt64 = 0
    private var modelDiscoveryTask: Task<Void, Never>?

    /// Starts one model-listing pass for the editor's draft fields. Every
    /// call invalidates the previous pass synchronously: the old task is
    /// cancelled, the generation is bumped and the visible stale results are
    /// cleared before this function returns, so a stale listing can never
    /// cross a provider, endpoint or key change. The debounced form waits
    /// briefly so a burst of edits collapses into one request; intermediate
    /// endpoints the user typed through never receive a request.
    func requestModelDiscovery(endpoint: String, protocolKind: ModelProtocol, apiKey: String, debounce: Bool) {
        modelDiscoveryGeneration &+= 1
        let generation = modelDiscoveryGeneration
        modelDiscoveryTask?.cancel()
        discoveredModels = []
        modelDiscoveryState = .idle
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        modelDiscoveryTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: Self.modelDiscoveryDebounceNanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            await self.runModelDiscovery(generation: generation, endpoint: trimmedEndpoint,
                                         protocolKind: protocolKind, apiKey: trimmedKey)
        }
    }

    /// Abandons any in-flight listing and clears the live results. Called
    /// when the editor closes or switches records.
    func cancelModelDiscovery() {
        modelDiscoveryGeneration &+= 1
        modelDiscoveryTask?.cancel()
        modelDiscoveryTask = nil
        modelDiscoveryState = .idle
        discoveredModels = []
    }

    private func runModelDiscovery(generation: UInt64, endpoint: String,
                                   protocolKind: ModelProtocol, apiKey: String) async {
        // The endpoint must parse to an absolute http(s) URL before any
        // network work; everything else stays idle.
        guard !endpoint.isEmpty,
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            applyModelDiscoveryResult(generation: generation, state: .idle, models: [])
            return
        }
        // Subscription gateways publish no `/models` listing; their honest
        // path here is manual model entry, never a fabricated catalog.
        let preset = ProviderPreset.preset(for: .custom, baseURL: url)
        guard preset.supportsModelDiscovery else {
            applyModelDiscoveryResult(generation: generation, state: .listingUnavailable, models: [])
            return
        }
        // A blank key is allowed only for keyless (local) endpoints; every
        // other listing runs with the exact current key and the key is sent
        // only to this settled endpoint.
        guard preset.authStyle == .none || !apiKey.isEmpty else {
            applyModelDiscoveryResult(generation: generation, state: .idle, models: [])
            return
        }
        // The same key admission rule as save: control characters are never
        // transmitted.
        guard !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            applyModelDiscoveryResult(generation: generation,
                                      state: .failed(String(localized: "mac.provider.keyInvalid")), models: [])
            return
        }
        applyModelDiscoveryResult(generation: generation, state: .discovering, models: [])
        do {
            var profile = ProviderProfile(kind: .custom, wireProtocol: protocolKind,
                                          baseURL: url, displayName: nil)
            // Plain HTTP is admitted only for the packaged smoke fixture's
            // exact loopback host with Keychain disabled; production listings
            // stay on the validated save rules (https, or acknowledged
            // private-network http through the ordinary editor flow).
            #if FLOE_MAC_HOST_SMOKE
            if vault == nil, url.host == "127.0.0.1" {
                profile.allowsPlainHTTP = true
            }
            #endif
            // Save-rule validation before any byte leaves the device: this
            // rejects plaintext http, non-http(s) schemes and URLs embedding
            // credentials, so a key is never transmitted to an invalid URL.
            try ProviderConfigurationValidation.validate(profile)
            let adapter = ProviderAdapterFactory().adapter(for: profile)
            let models = try await adapter.listModels(
                provider: profile,
                credentials: ProviderCredentials(apiKey: apiKey.isEmpty ? nil : apiKey)
            )
            try Task.checkCancellation()
            applyModelDiscoveryResult(generation: generation,
                                      state: .succeeded(modelCount: models.count), models: models)
        } catch is CancellationError {
            // A newer request owns the editor now; it republishes state.
        } catch {
            let message = SecretRedactor.redact(error.localizedDescription,
                                                secret: apiKey.isEmpty ? nil : apiKey)
            applyModelDiscoveryResult(generation: generation, state: .failed(message), models: [])
        }
    }

    private func applyModelDiscoveryResult(generation: UInt64, state: HostModelDiscoveryState,
                                           models: [ModelProfile]) {
        guard generation == modelDiscoveryGeneration else { return }
        modelDiscoveryState = state
        discoveredModels = models
    }

    private func admit() -> ReleaseWork? {
        do {
            return try admitWork()
        } catch {
            notice = String(localized: "host.chat.endingSession")
            return nil
        }
    }

    #if FLOE_MAC_HOST_SMOKE
    // Used only by the packaged App smoke command with its temporary
    // database and Keychain disabled. The adapter never creates a request.
    func verifyChatSmoke(admissionIsClosedToInstall: () -> Bool = { true }) async -> Bool {
        guard vault == nil, isReady, let runtime, !isSending, conversations.isEmpty,
              let config = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                  protocolKind: .openAIChatCompletions, modelID: "mac-smoke", apiKey: "") else { return false }
        guard beginSend("Synthetic Mac chat", runtime: runtime,
                  provider: .init(provider: config.profile, model: config.model,
                                  adapter: SmokeChatAdapter(), credentials: .init())) else { return false }
        let heldAdmission = admissionIsClosedToInstall()
        let deadline = ContinuousClock.now + .seconds(8)
        while isSending && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !isSending, notice == nil, let conversationID = selectedID,
              messages.map(\.role) == ["user", "assistant"] else { return false }
        await select(conversationID)
        return heldAdmission && messages.map(\.content) == ["Synthetic Mac chat", "Synthetic persisted reply."]
    }

    #if FLOE_UNIFIED_MAC
    func verifyConversationHistorySmoke(reference: URL) async -> Bool {
        guard vault == nil, let runtime, let id = selectedID, !isSending,
              let config = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                  protocolKind: .openAIChatCompletions, modelID: "mac-smoke", apiKey: "") else { return false }
        do {
            let database = try DatabaseManager(path: runtime.databaseURL)
            let store = SQLiteConversationStore(database: database)
            for index in 0..<105 {
                try await store.appendMessage(PersistedMessage(
                    id: UUID(), conversationID: id, role: "assistant",
                    content: "Fixture earlier message \(index)",
                    createdAt: Date(timeIntervalSince1970: 1_000 + Double(index))
                ))
            }
            try await database.close()
            await select(id)
            guard messages.count == 100, hasEarlierMessages else { return false }
            let transcript = try await transcript(conversationID: id)
            let exported = MacWorkspaceRootView.markdownTranscript(name: "Fixture", messages: transcript)
            guard transcript.count == 107, exported.contains("Fixture earlier message 0\n"),
                  exported.contains("Synthetic persisted reply.") else { return false }
            await loadEarlierMessages()
            guard messages.map(\.id) == transcript.map(\.id), !hasEarlierMessages,
                  let attachment = stageAttachments([reference]).first else { return false }
            let provider = FloeMacSelfProviderBinding(provider: config.profile, model: config.model,
                                                      adapter: SmokeChatAdapter(expectedAttachmentText: "Synthetic attachment"),
                                                      credentials: .init())
            guard beginSend("Fixture follow-up", runtime: runtime, provider: provider), await waitForSmokeRun(),
                  messages.count == 109, messages.first?.id == transcript.first?.id,
                  messages.contains(where: { $0.content == "Fixture follow-up" }),
                  messages.last?.content == "Synthetic persisted reply." else { return false }
            await select(nil)
            await select(id)
            var resolved: URL?
            await withSavedAttachment(id: attachment.id, conversationID: id) { resolved = $0 }
            return resolved?.standardizedFileURL == reference.standardizedFileURL
                && messages.contains(where: { $0.parts.contains(where: { $0.attachmentID == attachment.id }) })
        } catch {
            return false
        }
    }
    #endif

    private struct SmokeChatAdapter: ProviderAdapter {
        let protocolKind: ModelProtocol = .openAIChatCompletions
        var expectedAttachmentText: String? = nil

        func stream(request: ProviderStreamRequest,
                    credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                let received = expectedAttachmentText.map { marker in
                    request.effectiveMessages.contains { message in
                        message.role == "user" && message.content.contains { part in
                            if case .text(let text) = part { return text.contains(marker) }
                            return false
                        }
                    }
                } ?? true
                let reply = received ? "Synthetic persisted reply." : "Required attachment absent."
                continuation.yield(.textDelta(.init(text: reply)))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }

        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] {
            []
        }
    }

    #if FLOE_UNIFIED_MAC
    func verifyAgentApprovalSmoke(project: WorkspaceRecord, checkingFile root: URL,
                                  approveOnScreen: (Bool) -> Bool) async -> (allowed: Bool, denied: Bool) {
        guard vault == nil, let runtime, !isSending else { return (false, false) }
        await select(nil)
        var results: [Bool] = []
        for (file, allow) in [("approved.txt", true), ("declined.txt", false)] {
            let output = root.appendingPathComponent(file)
            guard let provider = smokeProvider(.createFile(file)),
                  beginSend("Create \(file)", runtime: runtime, provider: provider,
                            workspaceID: selectedID == nil ? project.id : nil, mode: .agent) else { break }
            let deadline = ContinuousClock.now + .seconds(6)
            while pendingApproval == nil && isSending && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard let approval = pendingApproval, approval.path == file,
                  approval.workspaceID == project.id, !FileManager.default.fileExists(atPath: output.path) else {
                stop()
                _ = await waitForSmokeRun()
                break
            }
            if !approveOnScreen(allow) {
                await resolveApproval(approval, allow: allow)
            }
            let stored = await waitForSmokeRun()
            let data = try? String(contentsOf: output, encoding: .utf8)
            results.append(stored && (allow ? data == "Synthetic workspace output." : data == nil))
        }
        return (results.first == true, results.count == 2 && results[1])
    }

    func verifyAgentTextEditSmoke(project: WorkspaceRecord, folder: URL) async -> Bool {
        guard vault == nil, let runtime, !isSending else { return false }
        await select(nil)
        do {
            for scenario in ["approved", "denied", "stale", "ambiguous"] {
                let name = "edit-\(scenario).txt"
                let url = folder.appendingPathComponent(name)
                let prefix = Data([0xef, 0xbb, 0xbf])
                let body = scenario == "ambiguous" ? "before\r\nbefore\r\n" : "before\r\nkeep\r\n"
                let original = prefix + Data(body.utf8)
                try original.write(to: url, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
                let priorCopies = try Self.smokePreviousVersions(in: folder)
                guard let provider = smokeProvider(.replaceText(name, FloeDigest.sha256Hex(original))),
                      beginSend("Edit \(name)", runtime: runtime, provider: provider,
                                workspaceID: selectedID == nil ? project.id : nil, mode: .agent) else { return false }
                let deadline = ContinuousClock.now + .seconds(6)
                while pendingApproval == nil && isSending && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard let approval = pendingApproval, approval.path == name,
                      approval.toolName == MacAgentWorkspaceTools.replaceTextToolName,
                      approval.previousText == "before", approval.text == "after",
                      try Data(contentsOf: url) == original else {
                    stop()
                    _ = await waitForSmokeRun()
                    return false
                }
                let changedElsewhere = Data("external revision\n".utf8)
                if scenario == "stale" { try changedElsewhere.write(to: url, options: .atomic) }
                await resolveApproval(approval, allow: scenario != "denied")
                let succeeded = await waitForSmokeRun()
                guard !isSending, pendingApproval == nil else { return false }
                let events = try await runtime.runEvents(runID: approval.runID)
                let result = events.filter { $0.kind == .toolResult }.lazy
                    .compactMap { try? JSONDecoder().decode([String: String].self, from: Data($0.payloadJSON.utf8)) }
                    .first { $0["id"] == approval.callID }
                let versions = try Self.smokePreviousVersions(in: folder).subtracting(priorCopies)
                let actual = try Data(contentsOf: url)
                switch scenario {
                case "approved":
                    guard succeeded, result?["status"] == "ok", actual == prefix + Data("after\r\nkeep\r\n".utf8),
                          versions.count == 1, let backup = versions.first,
                          try Data(contentsOf: backup) == original,
                          (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
                            .intValue == 0o640 else { return false }
                case "stale":
                    guard actual == changedElsewhere, versions.isEmpty, result?["status"] == "failed",
                          result?["summary"]?.contains("the file changed since it was inspected") == true
                    else { return false }
                case "ambiguous":
                    guard actual == original, versions.isEmpty, result?["status"] == "failed",
                          result?["summary"]?.contains("the specified text must occur exactly once") == true
                    else { return false }
                default:
                    guard succeeded, result?["status"] == "denied", actual == original, versions.isEmpty else { return false }
                }
                smokeRunDiagnostics.append("workspace.replaceText \(scenario): verified")
            }
            return true
        } catch {
            smokeRunDiagnostics.append("workspace.replaceText fixture: \(error.localizedDescription)")
            if isSending { stop(); _ = await waitForSmokeRun() }
            return false
        }
    }

    private static func smokePreviousVersions(in folder: URL) throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".floe-previous-") })
    }

    func verifyPlanningSmoke(project: WorkspaceRecord) async -> (planSaved: Bool, goalSaved: Bool) {
        guard vault == nil, let runtime, !isSending,
              let planner = smokeProvider(.submitPlan), let worker = smokeProvider(.workOnGoal) else {
            return (false, false)
        }
        await select(nil)
        guard beginSend("Plan how to verify this project", runtime: runtime, provider: planner,
                        workspaceID: project.id, mode: .plan), await waitForSmokeRun(),
              let proposal = plan, proposal.title == "Fixture plan", proposal.status == .ready,
              let conversationID = selectedID,
              await acceptPlan(proposal) else { return (false, false) }
        await select(nil)
        await select(conversationID)
        guard plan?.id == proposal.id, plan?.status == .accepted,
              let confirmed = pendingAcceptedPlan,
              let executor = smokeProvider(.executePlan),
              beginSend(confirmed.executionPrompt, runtime: runtime, provider: executor,
                        mode: .agent, acceptedPlan: confirmed), await waitForSmokeRun(),
              messages.first(where: { $0.id == confirmed.messageID })?.runID == confirmed.executionRunID else {
            return (false, false)
        }
        let planSaved = pendingAcceptedPlan == nil
        let criterion = "Read the saved file and verify the requested text."
        guard beginSend("Verify the project output", runtime: runtime, provider: worker,
                        mode: .goal, criterion: criterion), await waitForSmokeRun(),
              let stored = goal, stored.acceptanceCriteria.contains(where: { $0.text == criterion }),
              stored.evidence.contains(where: { $0.kind == .toolResult }),
              (try? await runtime.recentRuns(conversationID: conversationID, limit: 1))?.first?.goalID == stored.id else {
            return (planSaved, false)
        }
        await select(nil)
        await select(conversationID)
        return (planSaved, goal?.id == stored.id)
    }

    private func waitForSmokeRun() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while isSending && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        return !isSending && notice == nil && pendingApproval == nil
    }

    private func smokeProvider(_ action: SmokeTaskAdapter.Action) -> FloeMacSelfProviderBinding? {
        guard let config = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                    protocolKind: .openAIChatCompletions, modelID: "mac-task-smoke", apiKey: "",
                    supportsTools: true) else { return nil }
        return .init(provider: config.profile, model: config.model,
                     adapter: SmokeTaskAdapter(action: action), credentials: .init())
    }

    private struct SmokeTaskAdapter: ProviderAdapter {
        enum Action: Sendable { case createFile(String), replaceText(String, String), submitPlan, executePlan, workOnGoal }
        let action: Action
        let protocolKind: ModelProtocol = .openAIChatCompletions

        func stream(request: ProviderStreamRequest,
                    credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { stream in
                do {
                    if case .submitPlan = action,
                       !MacAgentWorkspaceTools.writeToolNames.isDisjoint(with: request.allToolNames) {
                        throw FloeError.validationFailed("Plan mode offered a workspace write")
                    }
                    let call = try firstCall()
                    if !request.toolResults.contains(where: { $0.callID == call.id }),
                       !request.replayedToolPairs.contains(where: { $0.call.id == call.id }) {
                        guard request.allToolNames.contains(call.toolName)
                            || request.toolSchemas.contains(where: { $0.name == call.toolName }) else {
                            throw FloeError.validationFailed("Smoke tool was not offered: \(call.toolName)")
                        }
                        stream.yield(.toolRequest(call))
                        stream.yield(.completed(.init(stopReason: .toolUse)))
                    } else {
                        let wasDeclined = request.replayedToolPairs.contains { $0.call.id == call.id && $0.result.status == .denied }
                            || request.toolResults.contains { $0.callID == call.id && $0.output.contains("User declined") }
                        let answer = wasDeclined ? "The operation was declined and the file was not created." : "Synthetic task response."
                        stream.yield(.textDelta(.init(text: answer)))
                        stream.yield(.completed(.init(stopReason: .endTurn)))
                    }
                    stream.finish()
                } catch {
                    stream.finish(throwing: error)
                }
            }
        }

        private func firstCall() throws -> ToolCall {
            switch action {
            case .createFile(let file):
                let body = try JSONEncoder().encode(["path": file, "content": "Synthetic workspace output."])
                return try ToolCall(id: "smoke-\(file)", toolName: "workspace.createFile", argumentsJSON: body, scope: .local)
            case .replaceText(let file, let sha256):
                let body = try JSONEncoder().encode([
                    "path": file, "oldText": "before", "newText": "after", "expectedSHA256": sha256,
                ])
                return try ToolCall(id: "smoke-\(file)", toolName: MacAgentWorkspaceTools.replaceTextToolName,
                                    argumentsJSON: body, scope: .local)
            case .submitPlan:
                let plan = PlanSubmission(title: "Fixture plan", summary: "Inspect and verify the project output.",
                    sections: [.init(title: "Inspect output", body: "Read the project output and verify its text.")],
                    acceptanceCriteria: [.init(text: "The output contains the requested text.", verification: "Read the saved file.")])
                return try ToolCall(id: "smoke-plan", toolName: "plan.submit", argumentsJSON: JSONEncoder().encode(plan), scope: .local)
            case .executePlan, .workOnGoal:
                let body = try JSONEncoder().encode(["path": "fixture.md"])
                let id = actionIsPlanExecution ? "smoke-plan-read" : "smoke-goal-read"
                return try ToolCall(id: id, toolName: "workspace.readFile",
                                    argumentsJSON: body, scope: .local)
            }
        }

        private var actionIsPlanExecution: Bool {
            if case .executePlan = action { return true }
            return false
        }

        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    }
    #endif
    #endif
}
