import Foundation

// FloeCore — Typed adapter capabilities for the design workflow.
//
// Only operations that are genuinely connected may be advertised; every
// unavailable operation must carry a clear reason. Consumers (UI and agent
// tools) must consult this before offering an operation, and content-specific
// editors/exports are only marked available when a real call path exists.

public enum DesignOperation: String, Codable, Sendable, CaseIterable {
    case importSource
    case generate
    case editRegion
    case preview
    case anchoredFeedback
    case candidateRevision
    case compareAdopt
    case sourceExport
    case verifiedExport
}

public struct DesignAdapterCapability: Sendable, Equatable {
    public let contentType: DesignContentType
    /// Only operations that are genuinely connected in this build.
    public let available: Set<DesignOperation>
    /// Reason shown for each unavailable operation.
    public let unavailableReasons: [DesignOperation: String]

    public init(
        contentType: DesignContentType,
        available: Set<DesignOperation>,
        unavailableReasons: [DesignOperation: String] = [:]
    ) {
        self.contentType = contentType
        self.available = available
        var reasons = unavailableReasons
        for operation in DesignOperation.allCases where !available.contains(operation) {
            if reasons[operation] == nil {
                reasons[operation] = "Not connected in this build"
            }
        }
        self.unavailableReasons = reasons
    }

    public func supports(_ operation: DesignOperation) -> Bool {
        available.contains(operation)
    }

    public func reason(for operation: DesignOperation) -> String? {
        available.contains(operation) ? nil : unavailableReasons[operation]
    }
}

/// Registry the app populates from its actual services.
public struct DesignCapabilityRegistry: Sendable {
    private let capabilities: [DesignContentType: DesignAdapterCapability]

    public init(capabilities: [DesignContentType: DesignAdapterCapability]) {
        self.capabilities = capabilities
    }

    /// Nothing connected: every operation reports a reason.
    public static func disconnected(reason: String = "Not connected in this build") -> DesignCapabilityRegistry {
        var caps: [DesignContentType: DesignAdapterCapability] = [:]
        for type in DesignContentType.allCases {
            var reasons: [DesignOperation: String] = [:]
            for operation in DesignOperation.allCases { reasons[operation] = reason }
            caps[type] = DesignAdapterCapability(contentType: type, available: [], unavailableReasons: reasons)
        }
        return DesignCapabilityRegistry(capabilities: caps)
    }

    public func capability(for contentType: DesignContentType) -> DesignAdapterCapability {
        capabilities[contentType]
            ?? DesignAdapterCapability(contentType: contentType, available: [])
    }

    public func supports(_ operation: DesignOperation, for contentType: DesignContentType) -> Bool {
        capability(for: contentType).supports(operation)
    }

    public func reason(_ operation: DesignOperation, for contentType: DesignContentType) -> String? {
        capability(for: contentType).reason(for: operation)
    }
}

// MARK: - Real capability matrix (mode × family × operation × environment × live)
//
// The registry above is static build wiring. What the UI and the agent tools
// must show is whether the exact request is available RIGHT NOW: the same
// family/operation can be unavailable because the Office engine session is
// not connected, the Linux guest is down, or no media model is configured.
// `DesignCapabilityMatrix` combines the static wiring with a live probe the
// app supplies from its real services; a missing capability is ALWAYS false
// with an honest reason and a recovery action — never a static "ready".

/// Live signal for one concrete query, returned by the app's probe. A probe
/// MUST re-derive availability from the live services (connected sessions,
/// configured providers, environment state) on every call.
public struct DesignLiveAvailability: Sendable, Equatable {
    public var connected: Bool
    /// Honest reason when not connected (never nil when connected == false).
    public var reason: String?
    /// What the user can do to make this available (open the document in the
    /// editor, start the engine session, configure a model...).
    public var recovery: String?

    public init(connected: Bool, reason: String? = nil, recovery: String? = nil) {
        self.connected = connected
        self.reason = reason
        self.recovery = recovery
    }

    public static func available() -> DesignLiveAvailability {
        DesignLiveAvailability(connected: true)
    }

    public static func unavailable(
        reason: String, recovery: String? = nil
    ) -> DesignLiveAvailability {
        DesignLiveAvailability(connected: false, reason: reason, recovery: recovery)
    }
}

/// Well-known live environment/configuration keys the app's probe reads.
/// Office must distinguish offline-executable OOXML operations from
/// operations that need a live engine session; the other keys cover the
/// families whose availability genuinely depends on runtime state.
public enum DesignCapabilityEnvironmentKey: String, Codable, Sendable, CaseIterable {
    /// "connected" when the shared Office engine session is open and holds
    /// the document; offline OOXML operations must NOT require this.
    case officeEngineSession
    /// "available" when the Linux guest can actually run (web serve/build).
    case linuxGuest
    /// "configured" when a real image/video generation model is configured.
    case mediaGenerationModel
    /// "connected" when the CAD kernel session is live (3D features).
    case cadKernelSession
    /// "connected" when the Notes/PDF services are available.
    case notesPDFService
}

/// One concrete capability question.
public struct DesignCapabilityQuery: Sendable, Equatable, Hashable {
    public var mode: DesignWorkMode
    public var family: DesignContentType
    public var operation: DesignOperation
    /// Live environment/configuration tags from the app (e.g. whether the
    /// Office engine session is connected or a media model is configured).
    /// Use `DesignCapabilityEnvironmentKey` raw values for the well-known
    /// services; the probe interprets the tags it knows and fails closed on
    /// the rest.
    public var environment: [String: String]

    public init(
        mode: DesignWorkMode,
        family: DesignContentType,
        operation: DesignOperation,
        environment: [String: String] = [:]
    ) {
        self.mode = mode
        self.family = family
        self.operation = operation
        self.environment = environment
    }
}

/// The honest answer for one query. `available` is true ONLY when the static
/// wiring AND the live probe both agree; any gap carries the reason of the
/// first failing layer and the recovery action to fix it.
public struct DesignCapabilityAssessment: Sendable, Equatable {
    public let query: DesignCapabilityQuery
    public let available: Bool
    public let reason: String?
    public let recovery: String?
    /// Capture-as-revision operations (freezing existing content, e.g. a
    /// webpage import) are reported separately from real generation so a
    /// capture is never presented as 制作.
    public let isCaptureOperation: Bool

    public init(
        query: DesignCapabilityQuery,
        available: Bool,
        reason: String?,
        recovery: String?,
        isCaptureOperation: Bool
    ) {
        self.query = query
        self.available = available
        self.reason = reason
        self.recovery = recovery
        self.isCaptureOperation = isCaptureOperation
    }
}

/// Real availability matrix over the approved work modes. Construct it with
/// the app's populated registry plus a live probe; without a probe every
/// query reports the static layer and a "connect the live probe" recovery.
public struct DesignCapabilityMatrix: Sendable {
    public static let liveProbeMissingRecovery = "connect the live capability probe"

    private let registry: DesignCapabilityRegistry
    private let live: @Sendable (DesignCapabilityQuery) -> DesignLiveAvailability

    public init(
        registry: DesignCapabilityRegistry = .disconnected(),
        live: @escaping @Sendable (DesignCapabilityQuery) -> DesignLiveAvailability = { _ in
            .unavailable(
                reason: "no live capability probe is connected",
                recovery: DesignCapabilityMatrix.liveProbeMissingRecovery
            )
        }
    ) {
        self.registry = registry
        self.live = live
    }

    /// The operations each work mode can meaningfully offer, given the
    /// wiring exists. Create centers on real generation (and preview/export
    /// of what was made); modify/restructure center on scoped edits,
    /// anchored feedback and compare/adopt. Capture (`importSource`) is
    /// offered to create as an EXISTING-source entry, never as generation.
    public static func operations(for mode: DesignWorkMode) -> Set<DesignOperation> {
        switch mode {
        case .create:
            return [.generate, .importSource, .preview, .sourceExport, .verifiedExport]
        case .modify, .restructure:
            return [
                .editRegion, .anchoredFeedback, .candidateRevision,
                .compareAdopt, .preview, .sourceExport, .verifiedExport
            ]
        }
    }

    public func assess(_ query: DesignCapabilityQuery) -> DesignCapabilityAssessment {
        let staticCapability = registry.capability(for: query.family)
        let capture = query.operation == .importSource
        guard staticCapability.supports(query.operation) else {
            return DesignCapabilityAssessment(
                query: query,
                available: false,
                reason: staticCapability.reason(for: query.operation),
                recovery: DesignCapabilityMatrix.liveProbeMissingRecovery,
                isCaptureOperation: capture
            )
        }
        let liveState = live(query)
        guard liveState.connected else {
            return DesignCapabilityAssessment(
                query: query,
                available: false,
                reason: liveState.reason ?? "not available in the current environment/configuration",
                recovery: liveState.recovery,
                isCaptureOperation: capture
            )
        }
        return DesignCapabilityAssessment(
            query: query,
            available: true,
            reason: nil,
            recovery: nil,
            isCaptureOperation: capture
        )
    }

    /// Full sweep used by tools/UI to render the matrix; every combination
    /// is answered explicitly (missing → false), never omitted.
    public func assessAll(
        modes: [DesignWorkMode] = DesignWorkMode.allCases,
        families: [DesignContentType] = DesignContentType.allCases
    ) -> [DesignCapabilityAssessment] {
        var results: [DesignCapabilityAssessment] = []
        for mode in modes {
            for family in families {
                for operation in Self.operations(for: mode) {
                    results.append(assess(DesignCapabilityQuery(
                        mode: mode, family: family, operation: operation
                    )))
                }
            }
        }
        return results
    }
}

/// Typed derivation of what a source IS, before any capability question.
/// Layout objects and unknown bytes are typed honestly instead of being
/// flattened into `webpage`.
public enum DesignSourceClassification: Sendable, Equatable {
    /// Verified bytes classify into a real design family.
    case typed(DesignContentType)
    /// A Canvas composition/layout object (shape/group/card/audio/generation
    /// task). Never webpage content; its "design" is the layout itself.
    case composition
    /// A known, real document format this build has no design capability
    /// for (e.g. an archive or executable). Preserved, never guessed.
    case unsupported(format: String)
    /// Unrecognized format/metadata: ask or inspect; never a webpage guess.
    case unknown
}
