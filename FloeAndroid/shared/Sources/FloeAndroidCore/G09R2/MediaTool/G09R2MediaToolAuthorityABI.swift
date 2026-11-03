// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — privileged media task-binding / proposal-grant C ABI
// (job-385365036e904fb1).
//
// App-process JNI only. This is NOT a V6 action, not a model tool and not a
// command label: no provider payload or model-authored JSON can reach it.
// Every entry requires the live accepted Root epoch AND the full process
// owner token, validated synchronously against the SAME generation identity
// used by the privacy/design authority ingress. The token never enters a
// return value, log, UI state or stored record.
//
//  * select: records the explicit trusted task/project association (pending;
//    no model access) after native derives project storage and validates the
//    real task/workspace.
//  * revoke: retires the association by project id (optionally exact binding/
//    task) so a revoked project cannot be reached through it again.
//  * issue grant: re-authorizes the PINNED association and issues the original
//    single-use `MediaProposalGrantStore` grant for an existing proposal. The
//    model never receives a mint action.
import Foundation
import FloeCore

enum G09R2MediaToolAuthorityStatus {
    static let ok: Int32 = 0
    static let ownerProofInvalid: Int32 = -121
    static let notReady: Int32 = -122
    static let invalidArgument: Int32 = -123
    static let bufferTooSmall: Int32 = -124
}

enum G09R2MediaToolAuthorityABI {
    static let maximumOwnerTokenBytes = 64
    static let maximumRequestBytes = 16 * 1024
    static let maximumReplyBytes = 8 * 1024

    static func cString(_ pointer: UnsafePointer<CChar>?, maximum: Int) -> String? {
        guard let pointer else { return nil }
        var length = 0
        while length <= maximum {
            if pointer[length] == 0 {
                guard length > 0 else { return "" }
                return String(
                    decoding: UnsafeBufferPointer(start: pointer, count: length)
                        .map { UInt8(bitPattern: $0) },
                    as: UTF8.self)
            }
            length += 1
        }
        return nil
    }

    static func ownerProofValid(_ epoch: Int64,
                                _ token: UnsafePointer<CChar>?) -> Bool {
        guard epoch > 0,
              let value = cString(token, maximum: maximumOwnerTokenBytes),
              value.count >= 8, value.count <= maximumOwnerTokenBytes,
              value.allSatisfy({
                  ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
              }) else {
            return false
        }
        return AndroidRuntimeBootstrap.g02OwnerProofValid(
            epoch: UInt64(epoch), token: value)
    }

    static func copyJSON(_ data: Data,
                         to out: UnsafeMutablePointer<CChar>?,
                         capacity: Int32) -> Int32 {
        guard let out, capacity > 0, data.count + 1 <= Int(capacity) else {
            return G09R2MediaToolAuthorityStatus.bufferTooSmall
        }
        for (index, byte) in data.enumerated() {
            out[index] = CChar(bitPattern: byte)
        }
        out[data.count] = 0
        return G09R2MediaToolAuthorityStatus.ok
    }

    static func replyData(_ reply: G09R2MediaToolAuthorityReply) throws -> Data {
        let data = try G09CreativeWire.encoder().encode(reply)
        guard data.count + 1 <= maximumReplyBytes else {
            throw G09R2MediaTaskBindingFailure.storageUnresolved
        }
        return data
    }

    static func errorReply(_ error: Error) -> G09R2MediaToolAuthorityReply {
        let failure = error as? G09R2MediaTaskBindingFailure ?? .notReady
        return G09R2MediaToolAuthorityReply(
            ok: false, error: failure.code, message: failure.message,
            binding: nil, grantID: nil, projectID: nil, proposalID: nil,
            revision: nil)
    }
}

/// Small synchronous bridge for the C ABI. The selection/grant work is actor
/// isolated; the App calls this off-main and receives exactly one result.
private final class MediaToolAuthorityResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock(); value = result; lock.unlock()
    }

    func get() -> Result<T, Error>? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

private func mediaToolAuthorityBlocking<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = MediaToolAuthorityResultBox<T>()
    Task {
        do {
            box.set(.success(try await body()))
        } catch {
            box.set(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.get() ?? .failure(G09R2MediaTaskBindingFailure.notReady)
}

private func requireMediaAuthorityService(
    _ service: G09CreativeDomainService,
    epoch: UInt64
) async throws {
    guard let cluster = await service.r2BoundCluster(),
          cluster.epoch == epoch,
          await service.r2IsGenerationLive(epoch: epoch),
          !(await service.r2IsRootStopping(epoch: epoch)) else {
        throw G09R2MediaTaskBindingFailure.notReady
    }
}

private func mediaToolWrite(_ reply: G09R2MediaToolAuthorityReply,
                            out: UnsafeMutablePointer<CChar>?,
                            capacity: Int32) -> Int32 {
    do {
        let data = try G09R2MediaToolAuthorityABI.replyData(reply)
        return G09R2MediaToolAuthorityABI.copyJSON(
            data, to: out, capacity: capacity)
    } catch {
        return G09R2MediaToolAuthorityStatus.bufferTooSmall
    }
}

@_cdecl("floe_media_task_binding_select")
public func floeMediaTaskBindingSelect(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ requestJSON: UnsafePointer<CChar>?,
    _ outJSON: UnsafeMutablePointer<CChar>?,
    _ outCapacity: Int32
) -> Int32 {
    guard G09R2MediaToolAuthorityABI.ownerProofValid(ownerEpoch, ownerToken) else {
        return G09R2MediaToolAuthorityStatus.ownerProofInvalid
    }
    guard outCapacity >= 512 else {
        return G09R2MediaToolAuthorityStatus.bufferTooSmall
    }
    guard let raw = G09R2MediaToolAuthorityABI.cString(
        requestJSON, maximum: G09R2MediaToolAuthorityABI.maximumRequestBytes),
          !raw.isEmpty,
          raw.utf8.count <= G09R2MediaToolAuthorityABI.maximumRequestBytes,
          let request = try? G09CreativeWire.decoder().decode(
            G09R2MediaTaskSelectionRequest.self, from: Data(raw.utf8)) else {
        return G09R2MediaToolAuthorityStatus.invalidArgument
    }
    let service = BridgeV5.service
    let acceptedEpoch = UInt64(ownerEpoch)
    let result = mediaToolAuthorityBlocking {
        try await requireMediaAuthorityService(service, epoch: acceptedEpoch)
        return try await G09R2MediaTaskBindingCoordinator.select(
            service: service, request: request)
    }
    switch result {
    case .success(let record):
        let reply = G09R2MediaToolAuthorityReply(
            ok: true, error: nil, message: nil, binding: record.view,
            grantID: nil, projectID: nil, proposalID: nil, revision: nil)
        return mediaToolWrite(reply, out: outJSON, capacity: outCapacity)
    case .failure(let error):
        return mediaToolWrite(
            G09R2MediaToolAuthorityABI.errorReply(error),
            out: outJSON, capacity: outCapacity)
    }
}

@_cdecl("floe_media_task_binding_revoke")
public func floeMediaTaskBindingRevoke(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ requestJSON: UnsafePointer<CChar>?,
    _ outJSON: UnsafeMutablePointer<CChar>?,
    _ outCapacity: Int32
) -> Int32 {
    guard G09R2MediaToolAuthorityABI.ownerProofValid(ownerEpoch, ownerToken) else {
        return G09R2MediaToolAuthorityStatus.ownerProofInvalid
    }
    guard outCapacity >= 256 else {
        return G09R2MediaToolAuthorityStatus.bufferTooSmall
    }
    guard let raw = G09R2MediaToolAuthorityABI.cString(
        requestJSON, maximum: G09R2MediaToolAuthorityABI.maximumRequestBytes),
          !raw.isEmpty,
          raw.utf8.count <= G09R2MediaToolAuthorityABI.maximumRequestBytes,
          let request = try? G09CreativeWire.decoder().decode(
            G09R2MediaTaskRevokeRequest.self, from: Data(raw.utf8)) else {
        return G09R2MediaToolAuthorityStatus.invalidArgument
    }
    let service = BridgeV5.service
    let acceptedEpoch = UInt64(ownerEpoch)
    let result = mediaToolAuthorityBlocking {
        try await requireMediaAuthorityService(service, epoch: acceptedEpoch)
        return try await G09R2MediaTaskBindingCoordinator.revoke(
            service: service, request: request)
    }
    switch result {
    case .success(let revoked):
        let reply = G09R2MediaToolAuthorityReply(
            ok: revoked, error: revoked ? nil : "bindingMissing",
            message: revoked ? nil : G09R2MediaTaskBindingFailure.bindingMissing.message,
            binding: nil, grantID: nil,
            projectID: request.projectID.uuidString.lowercased(),
            proposalID: nil, revision: nil)
        return mediaToolWrite(reply, out: outJSON, capacity: outCapacity)
    case .failure(let error):
        return mediaToolWrite(
            G09R2MediaToolAuthorityABI.errorReply(error),
            out: outJSON, capacity: outCapacity)
    }
}

@_cdecl("floe_media_project_tool_issue_grant")
public func floeMediaProjectToolIssueGrant(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ requestJSON: UnsafePointer<CChar>?,
    _ outJSON: UnsafeMutablePointer<CChar>?,
    _ outCapacity: Int32
) -> Int32 {
    guard G09R2MediaToolAuthorityABI.ownerProofValid(ownerEpoch, ownerToken) else {
        return G09R2MediaToolAuthorityStatus.ownerProofInvalid
    }
    guard outCapacity >= 512 else {
        return G09R2MediaToolAuthorityStatus.bufferTooSmall
    }
    guard let raw = G09R2MediaToolAuthorityABI.cString(
        requestJSON, maximum: G09R2MediaToolAuthorityABI.maximumRequestBytes),
          !raw.isEmpty,
          raw.utf8.count <= G09R2MediaToolAuthorityABI.maximumRequestBytes,
          let request = try? G09CreativeWire.decoder().decode(
            G09R2MediaProjectGrantRequest.self, from: Data(raw.utf8)) else {
        return G09R2MediaToolAuthorityStatus.invalidArgument
    }
    let service = BridgeV5.service
    let acceptedEpoch = UInt64(ownerEpoch)
    let result = mediaToolAuthorityBlocking {
        try await requireMediaAuthorityService(service, epoch: acceptedEpoch)
        return try await G09R2MediaTaskBindingCoordinator.issueGrant(
            service: service,
            grants: G09R2MediaToolGrants.shared,
            proposals: G09R2MediaToolProposalStore.shared,
            request: request)
    }
    switch result {
    case .success(let grantID):
        let reply = G09R2MediaToolAuthorityReply(
            ok: true, error: nil, message: nil, binding: nil,
            grantID: grantID,
            projectID: request.projectID.uuidString.lowercased(),
            proposalID: request.proposalID.uuidString.lowercased(),
            revision: request.revision)
        return mediaToolWrite(reply, out: outJSON, capacity: outCapacity)
    case .failure(let error):
        return mediaToolWrite(
            G09R2MediaToolAuthorityABI.errorReply(error),
            out: outJSON, capacity: outCapacity)
    }
}
