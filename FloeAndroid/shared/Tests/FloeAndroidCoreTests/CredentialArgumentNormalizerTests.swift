import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
@testable import FloeAndroidCore

/// Authored-only mirror tests for the original credential-argument
/// normalizer. The only production mirror change is the concrete vault
/// parameter -> `any CredentialCapturing`; these tests keep the original
/// recursive capture, sensitive-key, semantic-label, authority and placeholder
/// semantics observable.
final class CredentialArgumentNormalizerTests: XCTestCase {
    private struct CaptureCall: Sendable, Equatable {
        let secret: Data
        let kind: CredentialKind
        let owner: CredentialOwner
        let label: String
        let hostID: UUID?
        let origin: String?
    }

    /// Test-only capturing double. It never stores secret bytes beyond the
    /// in-process call record used by this test.
    private actor SpyVault: CredentialCapturing {
        private let handleID: UUID
        private(set) var calls: [CaptureCall] = []

        init(handleID: UUID) { self.handleID = handleID }

        func capture(
            _ secret: Data,
            kind: CredentialKind,
            owner: CredentialOwner,
            label: String,
            hostID: UUID?,
            origin: String?
        ) async throws -> CredentialHandle {
            calls.append(CaptureCall(
                secret: secret, kind: kind, owner: owner,
                label: label, hostID: hostID, origin: origin))
            return CredentialHandle(id: handleID)
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Recursive capture

    func testNestedVNCPasswordBecomesPlaceholderWithSemanticMetadata() async throws {
        let handleID = UUID()
        let spy = SpyVault(handleID: handleID)
        let hostID = UUID()
        let rawPassword = "nested-vnc-secret-\(UUID().uuidString)"
        let input = try jsonData([
            "hostID": hostID.uuidString,
            "vncConnections": [[
                "displayName": "Direct VNC",
                "transport": "direct",
                "host": "192.0.2.10",
                "port": 5_900,
                "credentialInput": rawPassword,
            ]],
        ])

        let output = try await CredentialArgumentNormalizer.normalize(
            input, toolName: "ssh.updateHost", vault: spy)

        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains(rawPassword))
        let object = try jsonObject(output)
        let connections = try XCTUnwrap(object["vncConnections"] as? [[String: Any]])
        let placeholder = try XCTUnwrap(connections.first?["credentialInput"] as? String)
        XCTAssertEqual(placeholder, CapturedSecret.placeholder(for: handleID))

        let calls = await spy.calls
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.secret, Data(rawPassword.utf8))
        XCTAssertEqual(call.kind, .vncPassword)
        XCTAssertEqual(call.owner, .vault)
        XCTAssertEqual(call.hostID, hostID)
        XCTAssertTrue(call.label.contains("Direct VNC"))
        XCTAssertTrue(call.label.contains("192.0.2.10"))
        XCTAssertTrue(call.label.contains("5900"))
        XCTAssertFalse(call.label.contains(rawPassword))
        XCTAssertFalse((call.origin ?? "").contains(rawPassword))
        XCTAssertEqual(call.origin,
                       "model-tool-call:ssh.updateHost.vncConnections.0.credentialInput")
    }

    func testCaptureRecursesThroughArraysAndLeavesOtherFieldsAlone() async throws {
        let handleID = UUID()
        let spy = SpyVault(handleID: handleID)
        let input = try jsonData([
            "steps": [
                ["command": "connect", "password": "array-secret"],
                ["command": "list"],
            ],
        ])

        let output = try await CredentialArgumentNormalizer.normalize(
            input, toolName: "ssh.updateHost", vault: spy)
        let object = try jsonObject(output)
        let steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.first?["password"] as? String,
                       CapturedSecret.placeholder(for: handleID))
        XCTAssertEqual(steps.last?["command"] as? String, "list")

        let calls = await spy.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.origin,
                       "model-tool-call:ssh.updateHost.steps.0.password")
    }

    func testExistingCredentialPlaceholderIsNeverRecaptured() async throws {
        let spy = SpyVault(handleID: UUID())
        let existingID = UUID()
        let placeholder = CapturedSecret.placeholder(for: existingID)
        let input = try jsonData(["credentialInput": placeholder])

        let output = try await CredentialArgumentNormalizer.normalize(
            input, toolName: "vnc.typeCredential", vault: spy)

        XCTAssertEqual(output, input)
        let calls = await spy.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSafeArgumentsAreReturnedByteForByte() async throws {
        let spy = SpyVault(handleID: UUID())
        let input = Data(
            #"{"path":"/var/app/file.txt","content":"hello world","count":3}"#.utf8)

        let output = try await CredentialArgumentNormalizer.normalize(
            input, toolName: "workspace.writeFile", vault: spy)

        XCTAssertEqual(output, input)
        let calls = await spy.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Sensitive key / kind semantics

    func testSensitiveKeyKindsMatchTheOriginalMapping() async throws {
        let providerSpy = SpyVault(handleID: UUID())
        _ = try await CredentialArgumentNormalizer.normalize(
            try jsonData([
                "apiKey": "provider-api-key",
                "password": "provider-password",
                "token": "provider-token",
            ]),
            toolName: "config.saveProvider",
            vault: providerSpy)
        let providerCalls = await providerSpy.calls
        XCTAssertEqual(providerCalls.count, 3)
        XCTAssertEqual(Set(providerCalls.map(\.kind)),
                       Set<CredentialKind>([.providerAPIKey, .websitePassword, .genericToken]))

        let sshSpy = SpyVault(handleID: UUID())
        let sshOutput = try await CredentialArgumentNormalizer.normalize(
            try jsonData([
                "password": "ssh-password",
                "privateKey": "ssh-private-key",
                "api_key": "ssh-key-material",
            ]),
            toolName: "ssh.updateHost",
            vault: sshSpy)
        let sshCalls = await sshSpy.calls
        // ORIGINAL MAPPING (source-mirror truth): only the original sensitive
        // keys are captured. `privateKey` is NOT one of them and therefore
        // passes through untouched; for ssh.* tools a sensitive key that
        // contains "key" (`api_key`) maps to `.sshPrivateKey`, while the
        // plain password maps to `.sshPassword`.
        XCTAssertEqual(sshCalls.count, 2)
        XCTAssertEqual(Set(sshCalls.map(\.kind)),
                       Set<CredentialKind>([.sshPassword, .sshPrivateKey]))
        let sshObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sshOutput) as? [String: Any])
        XCTAssertEqual(sshObject["privateKey"] as? String, "ssh-private-key",
                       "non-sensitive fields are never captured")

        let vncSpy = SpyVault(handleID: UUID())
        _ = try await CredentialArgumentNormalizer.normalize(
            try jsonData(["password": "vnc-password"]),
            toolName: "vnc.typeCredential",
            vault: vncSpy)
        let vncCalls = await vncSpy.calls
        XCTAssertEqual(vncCalls.count, 1)
        XCTAssertEqual(vncCalls.first?.kind, CredentialKind.vncPassword)
    }

    func testSemanticLabelUsesNearestNonSecretScope() async throws {
        let spy = SpyVault(handleID: UUID())
        _ = try await CredentialArgumentNormalizer.normalize(
            try jsonData(["name": "Gateway", "apiKey": "provider-secret"]),
            toolName: "config.saveProvider",
            vault: spy)

        let calls = await spy.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.kind, CredentialKind.providerAPIKey)
        XCTAssertEqual(calls.first?.label, "Provider API key for Gateway")
        XCTAssertFalse((calls.first?.label ?? "").contains("provider-secret"))
        XCTAssertEqual(calls.first?.origin,
                       "model-tool-call:config.saveProvider.apiKey")
        XCTAssertFalse((calls.first?.origin ?? "").contains("provider-secret"))
    }

    func testEmptyAndNonStringSensitiveValuesAreNotCaptured() async throws {
        let spy = SpyVault(handleID: UUID())
        let input = try jsonData([
            "password": "   ",
            "token": 123,
        ])

        let output = try await CredentialArgumentNormalizer.normalize(
            input, toolName: "config.saveProvider", vault: spy)

        XCTAssertEqual(output, input)
        let calls = await spy.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Run credential authority

    func testMatchingAuthorityPermitsCapture() async throws {
        let spy = SpyVault(handleID: UUID())
        let authority = RunCredentialAuthority(
            runID: UUID(), toolName: "ssh.updateHost",
            targetScope: .local, allowedFieldNames: ["credentialinput"])

        _ = try await CredentialArgumentNormalizer.normalize(
            try jsonData(["credentialInput": "authorized-secret"]),
            toolName: "ssh.updateHost", targetScope: .local,
            vault: spy, authority: authority)

        let calls = await spy.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testWrongToolAuthorityRefusesBeforeCapture() async throws {
        let spy = SpyVault(handleID: UUID())
        let authority = RunCredentialAuthority(
            runID: UUID(), toolName: "ssh.updateHost",
            targetScope: .local, allowedFieldNames: ["credentialinput"])

        do {
            _ = try await CredentialArgumentNormalizer.normalize(
                try jsonData(["credentialInput": "refused-secret"]),
                toolName: "vnc.typeCredential", targetScope: .local,
                vault: spy, authority: authority)
            XCTFail("mismatched tool authority must refuse")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
        let calls = await spy.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWrongScopeAuthorityRefusesBeforeCapture() async throws {
        let spy = SpyVault(handleID: UUID())
        let authority = RunCredentialAuthority(
            runID: UUID(), toolName: "ssh.updateHost",
            targetScope: .local, allowedFieldNames: ["credentialinput"])

        do {
            _ = try await CredentialArgumentNormalizer.normalize(
                try jsonData(["credentialInput": "refused-secret"]),
                toolName: "ssh.updateHost", targetScope: .host(UUID()),
                vault: spy, authority: authority)
            XCTFail("mismatched target scope must refuse")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
        let calls = await spy.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testExpiredAuthorityRefusesBeforeCapture() async throws {
        let spy = SpyVault(handleID: UUID())
        let now = Date()
        let authority = RunCredentialAuthority(
            runID: UUID(), toolName: "ssh.updateHost",
            targetScope: .local, allowedFieldNames: ["credentialinput"],
            createdAt: now.addingTimeInterval(-120),
            expiresAt: now.addingTimeInterval(-60))

        do {
            _ = try await CredentialArgumentNormalizer.normalize(
                try jsonData(["credentialInput": "refused-secret"]),
                toolName: "ssh.updateHost", targetScope: .local,
                vault: spy, authority: authority)
            XCTFail("expired authority must refuse")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
        let calls = await spy.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testUnauthorizedFieldsRefuseBeforeCapture() async throws {
        let spy = SpyVault(handleID: UUID())
        let authority = RunCredentialAuthority(
            runID: UUID(), toolName: "ssh.updateHost",
            targetScope: .local, allowedFieldNames: ["password"])

        do {
            _ = try await CredentialArgumentNormalizer.normalize(
                try jsonData(["credentialInput": "refused-secret"]),
                toolName: "ssh.updateHost", targetScope: .local,
                vault: spy, authority: authority)
            XCTFail("a field outside the authority must refuse")
        } catch let error as FloeError {
            XCTAssertEqual(error, .unauthorized)
        }
        let calls = await spy.calls
        XCTAssertTrue(calls.isEmpty)
    }
}
