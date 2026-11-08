import Foundation
import FloeExecution
import FloeCore
import FloeTools

/// Runtime/native UI provenance, never decoded from a mail tool argument.
struct NativeMailOAuthUse: Sendable {
    enum Operation: Sendable, Equatable { case read, modify, send, settingsTest }
    let operation: Operation
    let runID: UUID?
    let conversationID: UUID?
    let approvalGrantID: UUID?
    let checkCancellation: @Sendable () throws -> Void
    /// Kept only in native memory. IDs above describe the call; the original
    /// runtime context supplies its real cancellation and permission ceiling.
    var toolContext: ToolContext? = nil

    func validate() throws {
        try Task.checkCancellation(); try checkCancellation()
        if operation != .settingsTest {
            guard runID != nil else { throw MailFailure.authenticationFailed }
            if operation == .modify || operation == .send {
                guard approvalGrantID != nil else { throw MailFailure.authenticationFailed }
            }
        }
    }
    static var settingsTest: Self {
        .init(operation: .settingsTest, runID: nil, conversationID: nil, approvalGrantID: nil,
              checkCancellation: { try Task.checkCancellation() })
    }
}

struct NativeMailOAuthConnectionChoice: Identifiable, Sendable {
    let reference: ExternalOAuthConnectionReference
    /// A native display label/profile, not a claim of provider-verified email.
    let title: String
    var id: String { [reference.skillID, reference.installationID, reference.profile, reference.partition, reference.credentialID.uuidString, String(reference.revision)].joined(separator: ":") }
}

/// Concrete cached-token consumer. AppEnvironment supplies its existing
/// current Skill/native-task checks, the original vault-backed reader and
/// quiet refresh composition. No permissive defaults or interactive sign-in.
struct NativeMailOAuthConsumer: Sendable {
    typealias Reader = @Sendable (ExternalOAuthConnectionReference, NativeMailOAuthUse) async throws -> ExternalOAuthNativeTokenReader
    typealias Validate = @Sendable (ExternalOAuthConnectionReference, NativeMailOAuthUse) async throws -> Void
    typealias QuietRefresh = @Sendable (ExternalOAuthConnectionReference, NativeMailOAuthUse) async throws -> Void
    let makeReader: Reader
    let validateUse: Validate
    let quietRefresh: QuietRefresh

    func credential(reference: ExternalOAuthConnectionReference, server: MailServer,
                    service: MailOAuthService, use: NativeMailOAuthUse) async throws -> MailCredential {
        let provider = try MailOAuthProvider(reference: reference)
        try MailOAuthPolicy.validate(server: server, provider: provider, service: service)
        try use.validate()
        do {
            try await validateUse(reference, use)
            let reader = try await makeReader(reference, use)
            let token: ExternalOAuthNativeAccessToken
            do {
                token = try await read(reader, reference: reference, provider: provider, service: service)
            } catch ExternalOAuthNativeTokenFailure.needsRefresh {
                try use.validate(); try await validateUse(reference, use)
                // Exactly one quiet refresh of the same immutable binding.
                // The existing refresh API keeps credential ID/revision;
                // reconnect/rekey is a different binding and fails readback.
                try await quietRefresh(reference, use)
                try use.validate(); try await validateUse(reference, use)
                token = try await read(reader, reference: reference, provider: provider, service: service)
            }
            try use.validate(); try await validateUse(reference, use)
            return try MailCredential.xoauth2(accessToken: token.bytes, provider: provider, service: service, server: server)
        } catch is CancellationError { throw MailFailure.cancelled }
        catch FloeError.cancelled { throw MailFailure.cancelled }
        catch let failure as MailFailure { throw failure }
        catch {
            // Token responses, native worker/vault errors and provider text
            // never enter model-visible errors or a printable credential.
            throw MailFailure.authenticationFailed
        }
    }

    private func read(_ reader: ExternalOAuthNativeTokenReader, reference: ExternalOAuthConnectionReference,
                      provider: MailOAuthProvider, service: MailOAuthService) async throws -> ExternalOAuthNativeAccessToken {
        try await reader.validateConsumer()
        let snapshot = try await reader.persistence.snapshot()
        guard let grant = try ExternalOAuthSavedGrant.decode(snapshot.payload) else { throw ExternalOAuthNativeTokenFailure.changed }
        // v2 scopes carry the Outlook resource URL. No separate resource is
        // required when absent; any explicitly saved resources must still be
        // mail-only, and are rechecked by the real reader against the grant.
        let resources = grant.clientProfile.resources
        let allowed: Set<String> = provider == .google
            ? ["https://mail.google.com/", "https://mail.google.com"]
            : ["https://outlook.office.com/", "https://outlook.office.com", "https://outlook.office365.com/", "https://outlook.office365.com"]
        guard resources.isSubset(of: allowed) else { throw ExternalOAuthNativeTokenFailure.insufficientScope }
        return try await reader.read(reference: reference, provider: provider == .google ? .google : .microsoft,
            scopes: MailOAuthPolicy.scopes(provider: provider, service: service), resources: resources)
    }
}
