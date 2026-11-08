import Foundation
import FloeExecution

/// Constructed only from the existing runtime center's current, verified
/// installed-Skill staging result. validateAuthority rechecks that same
/// source/installation/environment ownership before executing the component.
struct LinuxOrtieWorkerBridge: ExternalOAuthPrivateWorkerOpening {
    let service: any LinuxGuestOAuthPrivateWorkerOpening
    let environmentID: String
    let executablePath: String
    let executableSHA256: String
    let validateAuthority: @Sendable () async throws -> Void

    func open(_ request: ExternalOAuthPrivateWorkerRequest) async throws -> any ExternalOAuthPrivateWorker {
        guard request.environmentID == environmentID else { throw ExternalOAuthFailure.invalidAuthorization }
        try await validateAuthority()
        let worker = try await service.openOAuthPrivateWorker(configuration: .init(
            environmentID: environmentID, ownershipKey: request.ownershipKey,
            executablePath: executablePath, executableSHA256: executableSHA256,
            account: request.account, configurationTOML: request.configurationTOML,
            useClientSecret: request.useClientSecret, readToken: request.readToken,
            writeToken: request.writeToken, readClientSecret: request.readClientSecret,
            invalidateAndJoin: request.invalidateAndJoin))
        return NativeWorker(worker: worker)
    }

    private struct NativeWorker: ExternalOAuthPrivateWorker {
        let worker: any LinuxGuestOAuthPrivateWorker
        func exchange(_ request: Data) async throws -> Data { try await worker.exchange(request) }
        func stop() async -> Bool { await worker.stop() }
    }
}
