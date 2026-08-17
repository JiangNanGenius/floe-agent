#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloePersistence
import FloeSkills
import FloeTools
import FloeModels
import FloeProviders
import CryptoKit

@MainActor
final class SkillsCenter: ObservableObject {
    struct RuntimeSelection: Sendable {
        var skillIDs: Set<String>
        var allowedToolNames: Set<String>?
        var instructions: String?

        static let none = RuntimeSelection(
            skillIDs: [], allowedToolNames: nil, instructions: nil
        )
    }

    @Published private(set) var installed: [PersistedSkill] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var pendingInstallation: PendingInstallation?

    private unowned let environment: AppEnvironment
    private let installationRoot: URL

    var rewriteModels: [ModelProfile] { environment.conversationCenter.availableAgentModels }
    var defaultRewriteModelID: UUID? {
        environment.conversationCenter.modelPreferences.defaultAgentModelID
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        installationRoot = support.appendingPathComponent("FloeAgent/Skills", isDirectory: true)
    }

    func load() async {
        installed = (try? await environment.skillStore.all()) ?? []
    }

    func create(name: String, description: String, instructions: String) async {
        await perform {
            _ = try await self.createSkill(SkillCreationRequest(
                name: name, description: description, instructions: instructions
            ))
        }
    }

    /// Throwing core shared by the UI authoring flow and the `skill.create`
    /// tool. Returns the created skill's identity so callers can report it.
    func createSkill(
        _ request: SkillCreationRequest,
        enabled: Bool = true
    ) async throws -> CreatedSkill {
        let id = try Self.identifier(request.name)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let safeDescription = request.description.replacingOccurrences(of: "\n", with: " ")
        let markdown = """
            ---
            name: \(id)
            description: \(safeDescription)
            ---
            \(request.instructions)
            """
        let manifest = SkillManifest(id: id, version: "1.0.0")
        try Data(markdown.utf8).write(to: temporary.appendingPathComponent("SKILL.md"), options: .atomic)
        try JSONEncoder().encode(manifest).write(to: temporary.appendingPathComponent("floe.json"), options: .atomic)
        let agents = temporary.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let openAIYAML = """
            interface:
              display_name: "\(Self.yaml(request.name))"
              short_description: "\(Self.yaml(String(safeDescription.prefix(64))))"
              default_prompt: "Use $\(id) to help with this task."
            policy:
              allow_implicit_invocation: true
            """
        try Data(openAIYAML.utf8).write(to: agents.appendingPathComponent("openai.yaml"), options: .atomic)
        try await self.installCanonicalPackage(
            at: temporary,
            sourceURL: URL(string: "floe-creator://local/\(id)")!,
            initialStatus: enabled ? "enabled" : "disabled"
        )
        return CreatedSkill(id: id, name: request.name, version: "1.0.0")
    }

    /// Finder v1 accepts a small HTTPS JSON envelope containing the rewritten
    /// `skillMarkdown` and `manifest`. Downloaded bytes live only in the
    /// temporary directory and are deleted after static validation/install.
    func installFromFinder(urlText: String, rewriteModelID: UUID?) async {
        await perform {
            let url = try BrowserURLPolicy.validate(urlText)
            guard url.scheme?.lowercased() == "https" else {
                throw FloeError.validationFailed("Skill Finder requires an HTTPS URL")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let session = URLSession(
                configuration: .ephemeral,
                delegate: FinderRedirectDelegate(),
                delegateQueue: nil
            )
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count <= 262_144 else {
                throw FloeError.validationFailed("Skill Finder response is unavailable or too large")
            }
            let sourceEnvelope = try JSONDecoder().decode(FinderEnvelope.self, from: data)
            let envelope = try await self.rewriteForCurrentDevice(
                sourceEnvelope, sourceURL: url, modelID: rewriteModelID
            )
            guard Set(envelope.manifest.capabilities).isSubset(of: Set(sourceEnvelope.manifest.capabilities)),
                  Set(envelope.manifest.tools).isSubset(of: Set(sourceEnvelope.manifest.tools)) else {
                throw FloeError.validationFailed("The rewrite attempted to expand skill permissions")
            }
            let sourceDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-finder-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try Data(envelope.skillMarkdown.utf8).write(to: temporary.appendingPathComponent("SKILL.md"), options: .atomic)
            try JSONEncoder().encode(envelope.manifest).write(to: temporary.appendingPathComponent("floe.json"), options: .atomic)
            let package = try SkillPackageValidator().validate(packageAt: temporary)
            try await self.requireCompatibility(package)
            if SkillAutomaticInstallPolicy.mayInstallWithoutConfirmation(
                package,
                descriptors: ToolCatalog.allDescriptors
            ) {
                try await self.installCanonicalPackage(
                    at: temporary, sourceURL: url, sourceDigest: sourceDigest,
                    rewriteModelID: rewriteModelID?.uuidString
                )
            } else {
                self.pendingInstallation = PendingInstallation(
                    sourceURL: url,
                    skillMarkdown: envelope.skillMarkdown,
                    manifest: envelope.manifest,
                    capabilityNames: package.declaredCapabilities.map(\.rawValue).sorted(),
                    toolNames: package.manifest.tools.sorted(),
                    containsScripts: package.containsScripts,
                    sourceDigest: sourceDigest,
                    rewriteModelID: rewriteModelID?.uuidString
                )
            }
        }
    }

    func confirmPendingInstallation() async {
        guard let pending = pendingInstallation else { return }
        pendingInstallation = nil
        await perform {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-confirmed-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try Data(pending.skillMarkdown.utf8).write(to: temporary.appendingPathComponent("SKILL.md"), options: .atomic)
            try JSONEncoder().encode(pending.manifest).write(to: temporary.appendingPathComponent("floe.json"), options: .atomic)
            try await self.installCanonicalPackage(
                at: temporary, sourceURL: pending.sourceURL,
                sourceDigest: pending.sourceDigest,
                rewriteModelID: pending.rewriteModelID
            )
        }
    }

    /// Resolves the enabled skills into the exact runtime authority for one
    /// run. The provider schema and the executor both receive this same tool
    /// ceiling; SKILL.md text never grants authority by itself.
    func runtimeSelection() async -> RuntimeSelection {
        guard let skills = try? await environment.skillStore.all() else { return .none }
        let enabled = skills.filter { $0.status == "enabled" }
        guard !enabled.isEmpty else { return .none }

        let descriptors = Dictionary(
            ToolCatalog.allDescriptors.map { ($0.name, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        var activeIDs: Set<String> = []
        var allowedTools: Set<String> = []
        var instructionBlocks: [String] = []
        let decoder = JSONDecoder()

        for skill in enabled {
            guard let manifestData = skill.manifestJSON.data(using: .utf8),
                  let manifest = try? decoder.decode(SkillManifest.self, from: manifestData)
            else { continue }
            let granted = (try? await environment.skillStore.allowedCapabilities(skillID: skill.id)) ?? []
            let effective = Set(manifest.capabilities).intersection(granted)
            activeIDs.insert(skill.id)
            instructionBlocks.append("## Skill: \(skill.name)\n\(skill.skillMarkdown)")

            for name in manifest.tools {
                guard let descriptor = descriptors[name] else { continue }
                let required = Self.requiredCapabilities(for: descriptor)
                guard required.isSubset(of: effective),
                      !descriptor.isSideEffecting || !required.isEmpty else { continue }
                allowedTools.insert(name)
            }
        }
        guard !activeIDs.isEmpty else { return .none }
        return RuntimeSelection(
            skillIDs: activeIDs,
            allowedToolNames: allowedTools,
            instructions: instructionBlocks.joined(separator: "\n\n")
        )
    }

    func cancelPendingInstallation() { pendingInstallation = nil }

    func setEnabled(_ enabled: Bool, skill: PersistedSkill) async {
        await perform { try await self.environment.skillStore.setEnabled(enabled, id: skill.id) }
    }

    /// Curator: disables agent-created skills that have been untouched for a
    /// long time. Only local/agent-authored skills are touched — never
    /// official or community-installed packages. Never deletes.
    func curate(now: Date = Date()) async {
        let installed = (try? await environment.skillStore.all()) ?? []
        let stale = installed.filter { skill in
            guard skill.sourceURL?.hasPrefix("floe-creator") == true else { return false }
            guard skill.status == "enabled" else { return false }
            return now.timeIntervalSince(skill.updatedAt) > 90 * 24 * 60 * 60
        }
        for skill in stale {
            try? await environment.skillStore.setEnabled(false, id: skill.id)
        }
    }

    func remove(_ skill: PersistedSkill) async {
        await perform {
            try await self.environment.skillStore.remove(id: skill.id)
            let package = self.installationRoot.appendingPathComponent(skill.id, isDirectory: true)
            if FileManager.default.fileExists(atPath: package.path) {
                try FileManager.default.removeItem(at: package)
            }
        }
    }

    private func installCanonicalPackage(
        at url: URL,
        sourceURL: URL,
        sourceDigest: String? = nil,
        rewriteModelID: String? = nil,
        initialStatus: String = "enabled"
    ) async throws {
        let validator = SkillPackageValidator()
        let package = try validator.validate(packageAt: url)
        try await requireCompatibility(package)
        let provenance = SkillInstallProvenance(
            sourceURL: sourceURL,
            originalSHA256: sourceDigest ?? package.canonicalSHA256,
            expectedRewrittenSHA256: package.canonicalSHA256,
            rewriteModelID: rewriteModelID ?? (sourceURL.scheme == "floe-creator" ? "local-skill-creator" : "finder-rewrite"),
            compatibilitySummary: "Validated for iOS against the compiled Floe tool catalog"
        )
        let record = try await SkillInstallStagingService(installationRoot: installationRoot)
            .installRewrittenPackage(at: url, provenance: provenance, replaceExisting: false)
        let markdown = try String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let manifestData = try Data(contentsOf: url.appendingPathComponent("floe.json"))
        let capabilities = try String(data: JSONEncoder().encode(package.manifest.capabilities), encoding: .utf8) ?? "[]"
        try await environment.skillStore.save(PersistedSkill(
            id: record.skillID,
            name: package.metadata.name,
            version: record.version,
            status: initialStatus,
            skillMarkdown: markdown,
            manifestJSON: String(decoding: manifestData, as: UTF8.self),
            declaredCapabilitiesJSON: capabilities,
            effectiveCapabilitiesJSON: capabilities,
            sourceURL: record.provenance.sourceURL.absoluteString,
            sourceDigest: record.provenance.originalSHA256,
            rewrittenDigest: record.canonicalSHA256,
            rewriteModelID: record.provenance.rewriteModelID,
            compatibilityReportJSON: #"{"status":"compatible"}"#
        ))
        // This grant authorizes the skill's declared ceiling only. Every
        // side-effecting invocation still passes the normal per-run approval
        // policy and catastrophic-action gate.
        for capability in package.declaredCapabilities {
            try await environment.skillStore.setPermission(
                skillID: record.skillID,
                capability: capability.rawValue,
                decision: "allow"
            )
        }
    }

    /// The model performs relevance/normalization only. Deterministic code
    /// owns trust, compatibility, permission-diff checks and installation.
    /// One repair attempt is allowed for invalid JSON; both calls have no
    /// tools, so a skill source can never execute during rewrite.
    private func rewriteForCurrentDevice(
        _ source: FinderEnvelope,
        sourceURL: URL,
        modelID: UUID?
    ) async throws -> FinderEnvelope {
        guard let (provider, model) = environment.conversationCenter.providerAndModel(modelID: modelID) else {
            throw FloeError.invalidConfiguration("Choose a configured text model to rewrite this skill for iOS")
        }
        let sourceData = try JSONEncoder().encode(source)
        let sourceJSON = String(decoding: sourceData, as: UTF8.self)
        let instruction = """
        Rewrite the candidate Floe skill for an iOS App Store build. Return only strict JSON with exactly
        {"skillMarkdown":"...","manifest":{...}}. Preserve the user's intent. You may remove unsupported
        capabilities or tools, but must never add either. Local JavaScript, native binaries, WASM and install
        hooks are unavailable. Scripts are reference text only and cannot execute locally. Source: \(sourceURL.absoluteString)

        Candidate:
        \(sourceJSON)
        """
        let first = try await requestRewrite(provider: provider, model: model, prompt: instruction)
        if let decoded = try? Self.decodeFinderEnvelope(first) { return decoded }
        let repair = """
        Convert the following invalid response to the exact strict JSON schema requested previously. Do not
        add capabilities or tools. Return JSON only.

        \(String(first.prefix(262_144)))
        """
        let second = try await requestRewrite(provider: provider, model: model, prompt: repair)
        return try Self.decodeFinderEnvelope(second)
    }

    private func requestRewrite(
        provider: ProviderProfile,
        model: ModelProfile,
        prompt: String
    ) async throws -> String {
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [
                (role: "system", content: "You normalize declarative Floe skill packages. You have no tools and return strict JSON only."),
                (role: "user", content: prompt)
            ],
            toolSchemas: []
        )
        let adapter = ProviderAdapterFactory().adapter(for: provider)
        let credentials = environment.conversationCenter.resolveCredentials(for: provider)
        var output = ""
        for try await event in adapter.stream(request: request, credentials: credentials) {
            switch event {
            case .textDelta(let delta):
                guard output.utf8.count + delta.text.utf8.count <= 512 * 1024 else {
                    throw FloeError.validationFailed("Skill rewrite response is too large")
                }
                output += delta.text
            case .error(let error):
                throw FloeError.internalError("Skill rewrite failed: \(error.providerMessage)")
            default:
                break
            }
        }
        guard !output.isEmpty else { throw FloeError.internalError("The rewrite model returned no package") }
        return output
    }

    private static func decodeFinderEnvelope(_ text: String) throws -> FinderEnvelope {
        try JSONDecoder().decode(FinderEnvelope.self, from: Data(text.utf8))
    }

    private func requireCompatibility(_ package: ValidatedSkillPackage) async throws {
        let hasRemoteHost = ((try? await environment.remoteHostStore.hosts()) ?? []).isEmpty == false
        var supported: Set<SkillCapability> = [
            .workspaceRead, .workspaceWrite, .workspaceDelete, .network,
            .browserObserve, .browserInteract
        ]
        if hasRemoteHost { supported.insert(.remoteExecution) }
        let environmentSnapshot = SkillRuntimeEnvironment(
            platform: .iOS,
            supportedCapabilities: supported,
            registeredTools: Set(ToolCatalog.allDescriptors.map(\.name)),
            // JavaScriptCore availability is not an executable tool.
            supportsJavaScriptCore: false,
            hasRemoteExecutionHost: hasRemoteHost
        )
        let compatibility = SkillCompatibility.evaluate(package, in: environmentSnapshot)
        guard compatibility.isRunnable else {
            throw FloeError.invalidConfiguration("This skill requests capabilities unavailable on this iPhone/iPad")
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do { try await operation(); await load() }
        catch { errorMessage = error.localizedDescription }
    }

    private static func identifier(_ name: String) throws -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        let normalized = latin.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let id = String(normalized).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        guard !id.isEmpty, id.count < 64, id.first?.isLetter == true else {
            throw FloeError.validationFailed("Skill name must begin with a letter and use fewer than 64 characters")
        }
        return id
    }

    private static func yaml(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func requiredCapabilities(
        for descriptor: ToolCatalog.Descriptor
    ) -> Set<String> {
        var result: Set<String> = []
        let labels = descriptor.riskLabels
        if labels.contains(.readsFiles) { result.insert(SkillCapability.workspaceRead.rawValue) }
        if labels.contains(.writesFiles) { result.insert(SkillCapability.workspaceWrite.rawValue) }
        if labels.contains(.deletesFiles) { result.insert(SkillCapability.workspaceDelete.rawValue) }
        if labels.contains(.networkAccess) { result.insert(SkillCapability.network.rawValue) }
        if labels.contains(.accessesCredentials) { result.insert(SkillCapability.credentials.rawValue) }
        if !labels.isDisjoint(with: [.executesRemoteCommand, .modifiesRemoteSystem]) {
            result.insert(SkillCapability.remoteExecution.rawValue)
        }
        if descriptor.name.hasPrefix("browser.") && !descriptor.isSideEffecting {
            result.insert(SkillCapability.browserObserve.rawValue)
        }
        if descriptor.name.hasPrefix("browser.") && descriptor.isSideEffecting {
            result.insert(SkillCapability.browserInteract.rawValue)
        }
        return result
    }

    struct PendingInstallation: Identifiable {
        let id = UUID()
        var sourceURL: URL
        var skillMarkdown: String
        var manifest: SkillManifest
        var capabilityNames: [String]
        var toolNames: [String]
        var containsScripts: Bool
        var sourceDigest: String
        var rewriteModelID: String?
    }

    private struct FinderEnvelope: Codable {
        var skillMarkdown: String
        var manifest: SkillManifest
    }

    private final class FinderRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let value = request.url?.absoluteString,
                  let validated = try? BrowserURLPolicy.validate(value),
                  validated.scheme?.lowercased() == "https" else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
#endif
