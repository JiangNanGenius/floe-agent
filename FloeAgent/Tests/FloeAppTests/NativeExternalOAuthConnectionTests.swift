import Foundation
import Testing
import FloeSync
@testable import FloeApp

private actor NativeOAuthValidationFixture {
    var enabled = true
    var changed = false
    var reads = 0
    var checks = 0
    func deny() { enabled = false }
    func replace() { changed = true }
    func read(_ data: Data, replace: Bool) -> Data { reads += 1; if replace { changed = true }; return data }
    func authorize(_ payload: Data?) throws {
        checks += 1
        if !enabled || changed { throw ExternalOAuthFailure.storageUnavailable }
    }
}

@Suite struct NativeExternalOAuthConnectionTests: Sendable {
    private let now = Date(timeIntervalSince1970: 1_700_000_100)
    private func client() throws -> ExternalOAuthClientProfile {
        try .init(provider: .google, clientID: "fixture.apps.googleusercontent.com",
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            scopes: ["https://mail.google.com/"])
    }
    private func payload(expires: Bool = true) throws -> Data {
        let client = try client(), account = UUID()
        let context = try ExternalOAuthCredentialContext(connectorID: "floe-google-auth", installationID: "fixture-installation",
            profile: "default", accountID: account, location: .linuxEnvironment("fixture-environment"), client: client)
        var token: [String: Any] = ["access_token": "synthetic_local_fixture_token", "token_type": "Bearer", "issued_at": 1_700_000_000]
        if expires { token["expires_in"] = 3_600 }
        return try JSONEncoder().encode(ExternalOAuthSavedGrant(schemaVersion: 1, partition: context.vaultPartition,
            accountID: account, registrationClientID: client.clientID,
            registrationIssuer: client.authorizationEndpoint.absoluteString, clientProfile: client,
            location: context.location, token: JSONSerialization.data(withJSONObject: token), clientSecret: nil))
    }
    private func request(_ data: Data, fixture: NativeOAuthValidationFixture, replace: Bool = false,
                         profile: String = "default", kind: String = "oauth.external") -> SkillConfigurationValidationRequest {
        .init(skillID: "floe-google-auth", installationID: "fixture-installation", profile: profile, target: "local-linux",
            revision: 7, fieldKey: "connection", connectionKind: kind, variables: [:], environment: [:], secretEnvironment: [],
            readSecret: { await fixture.read(data, replace: replace) })
    }

    @Test func noQualificationClientOrPermissionDefaults() throws {
        let draft = NativeExternalOAuthDraft(provider: .google)
        #expect(draft.clientID.isEmpty && draft.scopes.isEmpty && draft.environmentID.isEmpty)
        #expect(throws: (any Error).self) { try draft.profile() }
    }
    @Test func profilePreservesExplicitServiceAndEnvironment() throws {
        var draft = NativeExternalOAuthDraft(provider: .google)
        draft.clientID = "fixture.apps.googleusercontent.com"; draft.scopes = "https://mail.google.com/"
        draft.environmentID = "explicit-environment"
        let profile = try draft.profile()
        #expect(profile.scopes == ["https://mail.google.com/"])
        #expect(profile.authorizationExtras == ["access_type": "offline"])
        #expect(draft.environmentID == "explicit-environment")
        #expect(!profile.scopes.contains("https://www.googleapis.com/auth/drive"))
    }
    @Test func microsoftTenantCannotSupplyAnotherAuthorizationHost() throws {
        var draft = NativeExternalOAuthDraft(provider: .microsoft)
        draft.clientID = UUID().uuidString; draft.scopes = "User.Read"
        draft.tenant = "common/../../other.invalid"
        #expect(throws: (any Error).self) { try draft.profile() }
        draft.tenant = "consumers"
        #expect(try draft.profile().scopes == ["User.Read", "offline_access"])
        draft.keepSignedIn = false
        #expect(try draft.profile().scopes == ["User.Read"])
    }
    @Test func restoreHasNoSecretOrSilentEnvironmentReplacement() throws {
        var draft = NativeExternalOAuthDraft(provider: .google)
        draft.clientSecret = "synthetic_ephemeral_secret"
        draft.restore(client: try client(), environmentID: "saved-environment")
        #expect(draft.clientSecret.isEmpty && draft.environmentID == "saved-environment")
        #expect(try draft.profile().clientID == client().clientID)
    }
    @Test func validatorOnlyRecordsLocalProvenance() async throws {
        let fixture = NativeOAuthValidationFixture()
        let validator = NativeExternalOAuthConnectionValidator(authorize: { _, data in try await fixture.authorize(data) }, now: { self.now })
        let result = try await validator.validate(request(try payload(), fixture: fixture))
        guard case .valid = result else { Issue.record("valid local grant rejected"); return }
        #expect(validator.identifier == "oauth.external.local-token.v1")
        #expect(await fixture.checks == 2)
    }
    @Test func expiredOrUnknownExpiryNeedsRefresh() async throws {
        let fixture = NativeOAuthValidationFixture()
        for data in [try payload(expires: false), try payload()] {
            let validator = NativeExternalOAuthConnectionValidator(authorize: { _, value in try await fixture.authorize(value) },
                now: { Date(timeIntervalSince1970: 1_700_003_600) })
            guard case .invalid = try await validator.validate(request(data, fixture: fixture)) else {
                Issue.record("expiry was treated as an online valid authorization"); return
            }
        }
    }
    @Test func staleRevisionOrCredentialReplacementIsRejectedAfterRead() async throws {
        let fixture = NativeOAuthValidationFixture()
        let validator = NativeExternalOAuthConnectionValidator(authorize: { _, value in try await fixture.authorize(value) }, now: { self.now })
        guard case .invalid = try await validator.validate(request(try payload(), fixture: fixture, replace: true)) else {
            Issue.record("changed binding accepted"); return
        }
        #expect(await fixture.reads == 1)
        #expect(await fixture.checks == 2)
    }
    @Test func disabledSkillCannotReadTheGrant() async throws {
        let fixture = NativeOAuthValidationFixture(); await fixture.deny()
        let validator = NativeExternalOAuthConnectionValidator(authorize: { _, value in try await fixture.authorize(value) }, now: { self.now })
        guard case .invalid = try await validator.validate(request(try payload(), fixture: fixture)) else {
            Issue.record("disabled source accepted"); return
        }
        #expect(await fixture.reads == 0)
    }
    @Test func anotherProfileCannotReuseTheGrant() async throws {
        let fixture = NativeOAuthValidationFixture()
        let validator = NativeExternalOAuthConnectionValidator(authorize: { _, value in try await fixture.authorize(value) }, now: { self.now })
        guard case .invalid = try await validator.validate(request(try payload(), fixture: fixture, profile: "other-profile")) else {
            Issue.record("profile partition ignored"); return
        }
    }
    @Test func invalidPayloadDoesNotLeakProviderOrTokenText() async throws {
        let fixture = NativeOAuthValidationFixture()
        let marker = "synthetic_private_provider_marker"
        let validator = NativeExternalOAuthConnectionValidator(authorize: { _, value in try await fixture.authorize(value) })
        let result = try await validator.validate(request(Data(marker.utf8), fixture: fixture))
        guard case .invalid(let message) = result else { Issue.record("invalid payload accepted"); return }
        #expect(!message.contains(marker))
    }
    @Test func unknownKindDoesNotReadCredential() async throws {
        let fixture = NativeOAuthValidationFixture()
        let validator = NativeExternalOAuthConnectionValidator(authorize: { _, value in try await fixture.authorize(value) })
        guard case .unsupported = try await validator.validate(request(try payload(), fixture: fixture, kind: "other.connection")) else {
            Issue.record("unknown kind accepted"); return
        }
        #expect(await fixture.reads == 0)
        #expect(await fixture.checks == 0)
    }
    @Test func quietRefreshCannotDisplaceForegroundOwner() async throws {
        let lifecycle = NativeExternalOAuthLifecycle()
        let scope = NativeExternalOAuthLifecycle.Scope(skillID: "floe-google-auth", profile: "default", target: "local-linux")
        let ticket = try await lifecycle.begin(scope)
        await #expect(throws: NativeExternalOAuthLifecycle.Failure.self) { try await lifecycle.begin(scope) }
        #expect(await lifecycle.isCurrent(ticket))
        try await lifecycle.finish(ticket, stopped: true)
    }
    @Test func unconfirmedStopRetainsOwnerAndPreventsReplacement() async throws {
        let lifecycle = NativeExternalOAuthLifecycle()
        let scope = NativeExternalOAuthLifecycle.Scope(skillID: "floe-google-auth", profile: "default", target: "local-linux")
        let ticket = try await lifecycle.begin(scope)
        await #expect(throws: NativeExternalOAuthLifecycle.Failure.self) { try await lifecycle.finish(ticket, stopped: false) }
        #expect(await lifecycle.current() == ticket)
        await #expect(throws: NativeExternalOAuthLifecycle.Failure.self) { try await lifecycle.begin(scope) }
        try await lifecycle.finish(ticket, stopped: true)
        #expect(await lifecycle.current() == nil)
    }
    @Test func mutationFenceSpansStopAndActualStoreTransaction() async throws {
        let lifecycle = NativeExternalOAuthLifecycle()
        let scope = NativeExternalOAuthLifecycle.Scope(skillID: "floe-google-auth", profile: "default", target: "local-linux")
        let ticket = try await lifecycle.begin(scope)
        let mutation = await lifecycle.beginMutation(skillID: scope.skillID)
        #expect(!(await lifecycle.isCurrent(ticket)))
        try await lifecycle.finish(ticket, stopped: true)
        await #expect(throws: NativeExternalOAuthLifecycle.Failure.self) { try await lifecycle.begin(scope) }
        await lifecycle.finishMutation(skillID: scope.skillID, id: mutation)
        let replacement = try await lifecycle.begin(scope)
        #expect(replacement != ticket)
        #expect(await lifecycle.current(ownerID: ticket.id) == nil)
        #expect(await lifecycle.current(ownerID: replacement.id) == replacement)
        await #expect(throws: NativeExternalOAuthLifecycle.Failure.self) { try await lifecycle.finish(ticket, stopped: true) }
        #expect(await lifecycle.current() == replacement)
    }
    @Test func nestedMutationAndOtherAccountRemainPreciselyScoped() async throws {
        let lifecycle = NativeExternalOAuthLifecycle()
        let scope = NativeExternalOAuthLifecycle.Scope(skillID: "floe-microsoft-auth", profile: "work", target: "local-linux")
        let ticket = try await lifecycle.begin(scope)
        let one = await lifecycle.beginMutation(skillID: "floe-google-auth")
        let two = await lifecycle.beginMutation(skillID: "floe-google-auth")
        #expect(await lifecycle.isCurrent(ticket))
        await lifecycle.finishMutation(skillID: "floe-google-auth", id: one)
        #expect(!(await lifecycle.allowsUse(skillID: "floe-google-auth")))
        await lifecycle.finishMutation(skillID: "floe-google-auth", id: two)
        #expect(await lifecycle.allowsUse(skillID: "floe-google-auth"))
        try await lifecycle.finish(ticket, stopped: true)
    }
    @Test func concurrentOldCleanupCannotRetireReplacementOwner() async throws {
        let lifecycle = NativeExternalOAuthLifecycle()
        let scope = NativeExternalOAuthLifecycle.Scope(skillID: "floe-google-auth", profile: "default", target: "local-linux")
        let first = try await lifecycle.begin(scope)
        #expect(await lifecycle.retire(first, stopped: true))
        let next = try await lifecycle.begin(scope)
        #expect(await lifecycle.retire(first, stopped: true))
        #expect(await lifecycle.current() == next)
        #expect(!(await lifecycle.retire(next, stopped: false)))
        #expect(await lifecycle.current() == next)
        #expect(await lifecycle.retire(next, stopped: true))
    }
}
