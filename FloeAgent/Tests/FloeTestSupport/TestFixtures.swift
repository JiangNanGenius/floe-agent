// FloeTestSupport — Shared fixtures, mocks, and golden-file loading.

import Foundation
import FloeCore
import FloeModels

/// Shared test fixtures usable across all test targets.
public enum TestFixtures {

    /// Deterministic provider profile (localhost HTTPS, no secret).
    public static func localhostProvider(
        wireProtocol: ModelProtocol = .openAIResponses
    ) -> ProviderProfile {
        ProviderProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .custom,
            wireProtocol: wireProtocol,
            baseURL: URL(string: "https://localhost:8443")!,
            secretRef: nil,
            region: nil,
            nonSecretHeaders: [:],
            isEnabled: true,
            allowsPlainHTTP: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncRevision: 0
        )
    }

    /// Deterministic model profile.
    public static func testModel(providerID: UUID) -> ModelProfile {
        ModelProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            providerID: providerID,
            remoteModelID: "test-model-1",
            displayName: "Test Model",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8192),
            pricing: nil,
            capabilities: [.text, .tools],
            isEnabled: true
        )
    }

    /// A minimal valid tool call.
    public static func toolCall(
        id: String = "call_1",
        toolName: String = "test.echo",
        arguments: String = #"{"text":"hello"}"#
    ) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: toolName,
            argumentsJSON: Data(arguments.utf8),
            scope: .local
        )
    }

    /// A deterministic device secret for audit-chain tests.
    public static let testDeviceSecret = Data("floe-test-device-secret-0123456789".utf8)
}

/// Loads golden files bundled as test-target resources.
public enum GoldenFileLoader {
    /// Loads a resource from a test bundle. Throws when missing — golden
    /// files are part of the contract and must exist.
    public static func data(
        named name: String,
        extension ext: String,
        in bundle: Bundle
    ) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw FloeError.notFound("golden file \(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }

    public static func string(
        named name: String,
        extension ext: String,
        in bundle: Bundle
    ) throws -> String {
        String(decoding: try data(named: name, extension: ext, in: bundle), as: UTF8.self)
    }
}
