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
