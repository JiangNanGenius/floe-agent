// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GameCIWorkflowProvenance: Equatable, Sendable {
    /// Documented engine/tool documentation URLs backing the template commands.
    public let documentation: [URL]
    /// Third-party actions/containers referenced with an explicit pin.
    public let actionReferences: [String]
    /// License/provenance notes for embedded engine assumptions.
    public let notes: [String]
}

/// One selectable output target of a template. A target is atomic: selecting it
/// opts into its job and requires every artifact it declares. This prevents a
/// Web-only request from inheriting Android/native jobs, and prevents a native
/// project ZIP from being reported as the installable output.
public struct GameCIWorkflowTarget: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let job: String
    public let artifacts: [String]
    public let defaultSelected: Bool
    public let requires: [String]

    public init(id: String, label: String, job: String, artifacts: [String],
                defaultSelected: Bool, requires: [String] = []) {
        self.id = id
        self.label = label
        self.job = job
        self.artifacts = artifacts
        self.defaultSelected = defaultSelected
        self.requires = requires
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        job = try values.decode(String.self, forKey: .job)
        artifacts = try values.decode([String].self, forKey: .artifacts)
        defaultSelected = try values.decodeIfPresent(Bool.self, forKey: .defaultSelected) ?? false
        requires = try values.decodeIfPresent([String].self, forKey: .requires) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, job, artifacts, defaultSelected = "default", requires
    }
}

/// The typed result of selecting concrete requested output names against the
/// template's target contract. It is passed to CI as the `targets` input and is
/// also used to verify that the returned provenance attests exactly this set.
public struct GameCIWorkflowTargetSelection: Equatable, Sendable {
    public let targetIDs: [String]
    public let artifactNames: [String]

    public init(targetIDs: [String], artifactNames: [String]) {
        self.targetIDs = targetIDs.sorted()
        self.artifactNames = artifactNames.sorted()
    }

    public var dispatchValue: String { targetIDs.joined(separator: ",") }
    public var artifactSet: Set<String> { Set(artifactNames) }
    public var targetIDSet: Set<String> { Set(targetIDs) }
    public var isEmpty: Bool { targetIDs.isEmpty || artifactNames.isEmpty }
}

/// An exportable GitHub Actions workflow template. The YAML is deterministic
/// (no timestamps) so hosts can diff and cache it. Templates are data: this
/// package never dispatches them; the host binds the explicit source transport
/// and dispatches through its existing jobs service. `actuallyDispatched` stays
/// false until a host port does a real dispatch.
public struct GameCIWorkflowTemplate: Equatable, Sendable {
    public let id: String
    public let engine: GameEngineID
    public let fileName: String
    /// Template body; hosts may draft modifications before export validation.
    public var yaml: String
    /// Engine secrets only (for example UNITY_LICENSE); values live in the
    /// user's CI secrets.
    public let requiredSecrets: [String]
    /// Transport-only secrets (currently FLOE_SOURCE_TOKEN for an explicit
    /// cross-run artifact download). Never a credential value.
    public let transportSecrets: [String]
    public let inputs: [String]
    public let provenance: GameCIWorkflowProvenance
    public let sourceTransportKinds: [GameBuildSourceTransportKind]
    public let expectedArtifacts: [String]
    public let runnerPrerequisites: [String]
    /// Selectable targets and their atomic artifact sets.
    public let targets: [GameCIWorkflowTarget]
    public let actuallyDispatched: Bool

    public init(id: String, engine: GameEngineID, fileName: String, yaml: String,
                requiredSecrets: [String], transportSecrets: [String], inputs: [String],
                provenance: GameCIWorkflowProvenance,
                sourceTransportKinds: [GameBuildSourceTransportKind],
                expectedArtifacts: [String], runnerPrerequisites: [String],
                actuallyDispatched: Bool = false,
                targets: [GameCIWorkflowTarget] = []) {
        self.id = id; self.engine = engine; self.fileName = fileName; self.yaml = yaml
        self.requiredSecrets = requiredSecrets; self.transportSecrets = transportSecrets
        self.inputs = inputs; self.provenance = provenance
        self.sourceTransportKinds = sourceTransportKinds
        self.expectedArtifacts = expectedArtifacts; self.runnerPrerequisites = runnerPrerequisites
        self.targets = targets
        self.actuallyDispatched = actuallyDispatched
    }

    public var defaultTargetIDs: [String] {
        targets.filter(\.defaultSelected).map(\.id)
    }

    /// Resolve a template artifact placeholder such as
    /// `${{ inputs.artifact_prefix }}-web.zip` against concrete dispatch inputs.
    public func resolvedArtifactName(_ raw: String, inputs: [String: String]) throws -> String {
        var value = raw
        if value.contains("{{FLOE_ARTIFACT_PREFIX}}") {
            guard let prefix = inputs["artifact_prefix"], !prefix.isEmpty else {
                throw GameCIWorkflowError.placeholderUnresolved(raw)
            }
            value = value.replacingOccurrences(of: "{{FLOE_ARTIFACT_PREFIX}}", with: prefix)
        }
        while let start = value.range(of: "${{ inputs.") {
            guard let end = value.range(of: " }}", range: start.upperBound..<value.endIndex) else {
                throw GameCIWorkflowError.placeholderUnresolved(raw)
            }
            let name = String(value[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard let replacement = inputs[name], !replacement.isEmpty else {
                throw GameCIWorkflowError.placeholderUnresolved(raw)
            }
            value.replaceSubrange(start.lowerBound..<end.upperBound, with: replacement)
        }
        return value
    }

    /// Select the atomic targets that produce every requested concrete output.
    /// A requested output that no target can produce is rejected instead of
    /// being silently dropped or approximated by an unrelated artifact.
    public func selection(forRequestedArtifacts requested: Set<String>,
                          inputs: [String: String]) throws -> GameCIWorkflowTargetSelection {
        guard !requested.isEmpty else { throw GameCIWorkflowError.missingRequestedTarget }
        let resolved = try targets.map { target in
            (target, try target.artifacts.map { try resolvedArtifactName($0, inputs: inputs) })
        }
        var selectedIDs = Set<String>()
        for name in requested.sorted() {
            let matches = resolved.filter { $0.1.contains(name) }
            guard !matches.isEmpty else { throw GameCIWorkflowError.unsupportedTarget(name) }
            selectedIDs.formUnion(matches.map { $0.0.id })
        }
        let selected = targets.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { throw GameCIWorkflowError.missingRequestedTarget }
        var artifacts = Set<String>()
        for target in selected {
            for raw in target.artifacts {
                artifacts.insert(try resolvedArtifactName(raw, inputs: inputs))
            }
        }
        return .init(targetIDs: selected.map(\.id), artifactNames: Array(artifacts))
    }

    public func defaultSelection(inputs: [String: String]) throws -> GameCIWorkflowTargetSelection {
        let defaultArtifacts = try targets
            .filter(\.defaultSelected)
            .flatMap(\.artifacts)
            .map { try resolvedArtifactName($0, inputs: inputs) }
        guard !defaultArtifacts.isEmpty else { throw GameCIWorkflowError.missingRequestedTarget }
        return try selection(forRequestedArtifacts: Set(defaultArtifacts), inputs: inputs)
    }
}

public enum GameCIWorkflowError: Error, Equatable, Sendable {
    case missingHeader
    case missingDispatchTrigger
    case missingDigestVerification
    case missingProvenanceStep
    case missingSourceTransport
    case missingSelectionContract
    case missingProvenanceJobIdentity
    case unpinnedAction(String)
    case embeddedSecretValue(String)
    case placeholderUnresolved(String)
    case missingExpectedArtifact(String)
    case missingTargetContract
    case duplicateTarget(String)
    case unsafeTarget(String)
    case unsupportedTarget(String)
    case missingRequestedTarget
    case targetJobMissing(String)
    case targetArtifactMismatch(String)
}

struct GameCIWorkflowContract: Decodable, Equatable, Sendable {
    let id: String
    let requiredSecrets: [String]
    let engineSecrets: [String]
    let transportSecrets: [String]
    let inputs: [String]
    let expectedArtifacts: [String]
    let provenanceArtifact: String
    let runnerPrerequisites: [String]
    let documentation: [String]
    let sourceTransports: [String]
    let targets: [GameCIWorkflowTarget]

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        requiredSecrets = try values.decode([String].self, forKey: .requiredSecrets)
        engineSecrets = try values.decode([String].self, forKey: .engineSecrets)
        transportSecrets = try values.decode([String].self, forKey: .transportSecrets)
        inputs = try values.decode([String].self, forKey: .inputs)
        expectedArtifacts = try values.decode([String].self, forKey: .expectedArtifacts)
        provenanceArtifact = try values.decode(String.self, forKey: .provenanceArtifact)
        runnerPrerequisites = try values.decode([String].self, forKey: .runnerPrerequisites)
        documentation = try values.decode([String].self, forKey: .documentation)
        sourceTransports = try values.decode([String].self, forKey: .sourceTransports)
        targets = try values.decodeIfPresent([GameCIWorkflowTarget].self, forKey: .targets) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, requiredSecrets, engineSecrets, transportSecrets, inputs, expectedArtifacts
        case provenanceArtifact, runnerPrerequisites, documentation, sourceTransports, targets
    }
}

struct GameCIWorkflowContractCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let contracts: [GameCIWorkflowContract]
}

public enum GameCIWorkflowTemplates {
    public static func template(for engine: GameEngineID) -> GameCIWorkflowTemplate? {
        try? loadTemplate(for: engine)
    }

    public static func all() throws -> [GameCIWorkflowTemplate] {
        let catalog = try GameBuildCatalogLoader.load()
        var seen = Set<String>()
        var templates: [GameCIWorkflowTemplate] = []
        for entry in catalog.engines {
            guard let id = entry.workflowTemplateID, !seen.contains(id) else { continue }
            seen.insert(id)
            if let template = try loadTemplate(for: entry.engine) {
                templates.append(template)
            }
        }
        return templates
    }

    private static func loadTemplate(for engine: GameEngineID) throws -> GameCIWorkflowTemplate? {
        let catalog = try GameBuildCatalogLoader.load()
        guard let entry = catalog.engines.first(where: { $0.engine == engine }),
              let templateID = entry.workflowTemplateID else { return nil }
        return try loadTemplate(id: templateID, engine: engine)
    }

    private static func loadTemplate(id: String, engine: GameEngineID) throws -> GameCIWorkflowTemplate {
        let contract = try contractCatalog().contracts.first { $0.id == id }
        guard let contract else {
            throw GameBuildCapabilityError.invalidRouteCatalog("missing workflow contract \(id)")
        }
        guard let url = GameBuildResourceLocator.url(id, "yml", "Resources/Workflows") else {
            throw GameBuildCapabilityError.invalidRouteCatalog("missing workflow \(id).yml")
        }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let values = try contract.sourceTransports.map {
            guard let kind = GameBuildSourceTransportKind(rawValue: $0) else {
                throw GameBuildCapabilityError.invalidRouteCatalog("unknown transport \($0)")
            }
            return kind
        }
        let references = actionReferences(in: yaml)
        return GameCIWorkflowTemplate(
            id: id, engine: engine, fileName: id + ".yml", yaml: yaml,
            requiredSecrets: contract.engineSecrets,
            transportSecrets: contract.transportSecrets,
            inputs: contract.inputs,
            provenance: .init(documentation: contract.documentation.compactMap(URL.init(string:)),
                              actionReferences: references,
                              notes: ["Engine tools run on the user's CI; Floe does not hold a licence or gate on a developer account.",
                                      "A requested target is atomic: every artifact it declares is required before success.",
                                      "An artifact is uploaded only after an actual file/magic check; provenance is attested separately."]),
            sourceTransportKinds: values,
            expectedArtifacts: contract.expectedArtifacts,
            runnerPrerequisites: contract.runnerPrerequisites,
            actuallyDispatched: false,
            targets: contract.targets)
    }

    private static func contractCatalog() throws -> GameCIWorkflowContractCatalog {
        guard let url = GameBuildResourceLocator.url("workflow-contracts.v1", "json",
                                                     "Resources/Catalog") else {
            throw GameBuildCapabilityError.invalidRouteCatalog("missing workflow-contracts.v1.json")
        }
        return try JSONDecoder().decode(GameCIWorkflowContractCatalog.self, from: Data(contentsOf: url))
    }

    static func actionReferences(in yaml: String) -> [String] {
        var references: [String] = []
        for line in yaml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("uses:") {
                let value = String(trimmed.dropFirst("uses:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { references.append(value) }
            } else if trimmed.hasPrefix("image:") {
                let value = String(trimmed.dropFirst("image:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { references.append(value) }
            }
        }
        return references
    }

    /// Structural validation a host can run before offering export. Checks the
    /// security- and honesty-relevant invariants only; full YAML parsing is the
    /// host's.
    public static func validate(_ template: GameCIWorkflowTemplate) throws {
        guard template.yaml.hasPrefix("# Floe game CI template") else {
            throw GameCIWorkflowError.missingHeader
        }
        guard template.yaml.contains("workflow_dispatch") else {
            throw GameCIWorkflowError.missingDispatchTrigger
        }
        guard template.yaml.contains("Verify source digest") else {
            throw GameCIWorkflowError.missingDigestVerification
        }
        guard template.yaml.contains("Write build provenance") else {
            throw GameCIWorkflowError.missingProvenanceStep
        }
        guard template.yaml.contains("source_commit"),
              template.yaml.contains("source_run_id"),
              template.yaml.contains("source_artifact_name"),
              template.yaml.contains("floe-source-provenance"),
              !template.sourceTransportKinds.isEmpty else {
            throw GameCIWorkflowError.missingSourceTransport
        }
        // A workflow must resolve and verify the selected game root from the
        // checked-out bytes and echo it into provenance; an empty root is the
        // whole project, never an inferred nested game.
        guard template.inputs.contains("game_root"),
              template.inputs.contains("selected_source_sha256"),
              template.yaml.contains("Resolve selected game root"),
              template.yaml.contains("FLOE_GAME_ROOT"),
              template.yaml.contains("selectedSourceSHA256") else {
            throw GameCIWorkflowError.missingSelectionContract
        }
        // A run id is the only identity that binds returned provenance to the
        // exact dispatched job. Schema-2 templates must echo it explicitly.
        guard template.yaml.contains("\\\"schemaVersion\\\": 2"),
              template.yaml.contains("\\\"jobID\\\": os.environ.get(\\\"GITHUB_RUN_ID\\\", \\\"\\\")") else {
            throw GameCIWorkflowError.missingProvenanceJobIdentity
        }
        guard !template.targets.isEmpty,
              template.inputs.contains("targets"),
              template.yaml.contains("needs.prepare.outputs.targets"),
              template.yaml.contains("Resolve and validate requested targets") else {
            throw GameCIWorkflowError.missingTargetContract
        }
        var seenTargets = Set<String>()
        var coveredArtifacts = Set<String>()
        for target in template.targets {
            guard !target.id.isEmpty,
                  target.id.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else {
                throw GameCIWorkflowError.unsafeTarget(target.id)
            }
            guard seenTargets.insert(target.id).inserted else {
                throw GameCIWorkflowError.duplicateTarget(target.id)
            }
            guard !target.job.isEmpty,
                  template.yaml.contains("\n  \(target.job):") else {
                throw GameCIWorkflowError.targetJobMissing(target.job)
            }
            guard !target.artifacts.isEmpty,
                  target.artifacts.allSatisfy({ !$0.isEmpty && !$0.contains("..") && !$0.contains("/") && !$0.contains("\\") }) else {
                throw GameCIWorkflowError.unsafeTarget(target.id)
            }
            for artifact in target.artifacts {
                guard template.expectedArtifacts.contains(artifact) else {
                    throw GameCIWorkflowError.targetArtifactMismatch(artifact)
                }
                coveredArtifacts.insert(artifact)
            }
        }
        guard template.targets.contains(where: { $0.defaultSelected }) else {
            throw GameCIWorkflowError.missingTargetContract
        }
        for artifact in template.expectedArtifacts where !coveredArtifacts.contains(artifact) {
            throw GameCIWorkflowError.targetArtifactMismatch(artifact)
        }
        for reference in template.provenance.actionReferences {
            guard isPinned(reference) else {
                throw GameCIWorkflowError.unpinnedAction(reference)
            }
        }
        // Every referenced workflow input must be declared by the template.
        for line in template.yaml.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            var remainder = Substring(trimmed)
            while let marker = remainder.range(of: "${{ inputs.") {
                let after = remainder[marker.upperBound...]
                guard let name = after.components(separatedBy: " }}").first,
                      template.inputs.contains(name) else {
                    throw GameCIWorkflowError.placeholderUnresolved(trimmed)
                }
                remainder = after
            }
        }
        // Any `secrets.X` reference must name a declared engine or transport
        // secret, and no line may embed an obvious literal credential.
        let declaredSecrets = Set(template.requiredSecrets + template.transportSecrets)
        for line in template.yaml.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.contains("${{ secrets.") {
                let parts = trimmed.components(separatedBy: "${{ secrets.")
                for part in parts.dropFirst() {
                    guard let name = part.components(separatedBy: " }}").first,
                          declaredSecrets.contains(name) else {
                        throw GameCIWorkflowError.embeddedSecretValue(trimmed)
                    }
                }
            }
            let lower = trimmed.lowercased()
            if (lower.contains("password:") || lower.contains("token:") || lower.contains("license:")),
               !lower.contains("secrets."), !lower.hasPrefix("#"), !lower.contains("required") {
                throw GameCIWorkflowError.embeddedSecretValue(trimmed)
            }
        }
        // Free-form version/path/target inputs must reach shell steps through
        // environment variables, never through direct `${{ inputs.x }}` text.
        for line in template.yaml.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("run:") || trimmed.hasPrefix("- run:") {
                guard !trimmed.contains("${{ inputs.") else {
                    throw GameCIWorkflowError.placeholderUnresolved(trimmed)
                }
            }
        }
        // A source-only/native-project template must not download or emit an
        // .ipa as its declared artifact. The legitimate "not an IPA" note is
        // allowed; only a real .ipa path/claim is refused.
        if template.yaml.lowercased().contains(".ipa") {
            throw GameCIWorkflowError.missingExpectedArtifact("template must not claim an IPA")
        }
        if template.yaml.contains("cp index.html") {
            throw GameCIWorkflowError.missingExpectedArtifact("unsafe static copy fallback")
        }
    }

    static func isPinned(_ reference: String) -> Bool {
        if reference.hasPrefix("docker://") {
            return reference.contains("@sha256:") || reference.contains(":")
        }
        guard let marker = reference.lastIndex(of: "@") else {
            // Container images are pinned by an explicit version tag.
            return reference.contains(":") && !reference.hasSuffix(":latest")
        }
        let revision = reference[reference.index(after: marker)...]
        return revision.count == 40 && revision.allSatisfy { $0.isHexDigit }
    }
}
