// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — privileged design-authority C ABI (App-process JNI only).
//
// This is NOT a V6 action, has no command/label/tool/permission entry and is
// unreachable from model-authored bridge JSON. The App calls it only from the
// explicit preservation-confirmation action with its live accepted Root epoch
// + full process owner token. Native re-validates the owner proof, binds the
// exact live target/operation/base revision, and returns only display data +
// an opaque confirmation token. `confirm` mints the existing single-use
// approval grant; the design service burns it immediately before an effect.
import Foundation
import FloeCore

private enum DesignAuthorityABI {
    static let maximumOwnerTokenBytes = 64

    static func cString(
        _ pointer: UnsafePointer<CChar>?, maximum: Int
    ) -> String? {
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

    static func ownerProofValid(_ epoch: Int64, _ token: UnsafePointer<CChar>?) -> Bool {
        guard epoch > 0,
              let value = cString(token, maximum: maximumOwnerTokenBytes),
              value.count >= 8, value.count <= maximumOwnerTokenBytes,
              value.allSatisfy({
                  ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
              }) else { return false }
        return AndroidRuntimeBootstrap.g02OwnerProofValid(
            epoch: UInt64(epoch), token: value)
    }

    static func copyJSON(
        _ data: Data, to out: UnsafeMutablePointer<CChar>?, capacity: Int32
    ) -> Int32 {
        guard let out, capacity > 0 else {
            return G09R2DesignAuthorityStatus.invalidArgument
        }
        guard data.count + 1 <= Int(capacity) else {
            return G09R2DesignAuthorityStatus.invalidArgument
        }
        for (index, byte) in data.enumerated() {
            out[index] = CChar(bitPattern: byte)
        }
        out[data.count] = 0
        return G09R2DesignAuthorityStatus.ok
    }
}

/// Small synchronous bridge for the C ABI. The prepare operation must inspect
/// live design state; the App calls this off-main. A fixed blocker is used
/// instead of a detached Task so the JNI call returns exactly one result.
private final class DesignAuthorityResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock(); value = result; lock.unlock()
    }

    func get() -> Result<T, Error>? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

private func designAuthorityBlocking<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = DesignAuthorityResultBox<T>()
    Task {
        do {
            box.set(.success(try await body()))
        } catch {
            box.set(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.get() ?? .failure(G09R2Error(.designTargetUnavailable, detail: "authorityUnavailable"))
}

/// Prepare ONE trusted restructure confirmation. Input is bounded JSON; output
/// is the display DTO JSON (never a claim/authority flag).
@_cdecl("floe_design_authority_prepare")
public func floeDesignAuthorityPrepare(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ requestJSON: UnsafePointer<CChar>?,
    _ outJSON: UnsafeMutablePointer<CChar>?,
    _ outCapacity: Int32
) -> Int32 {
    guard outCapacity >= 1024,
          DesignAuthorityABI.ownerProofValid(ownerEpoch, ownerToken) else {
        return DesignAuthorityABI.ownerProofValid(ownerEpoch, ownerToken)
            ? G09R2DesignAuthorityStatus.invalidArgument
            : G09R2DesignAuthorityStatus.ownerProofInvalid
    }
    guard let raw = DesignAuthorityABI.cString(
        requestJSON, maximum: G09R2DesignAuthorityLimits.maximumPrepareJSONBytes),
          !raw.isEmpty,
          raw.utf8.count <= G09R2DesignAuthorityLimits.maximumPrepareJSONBytes else {
        return G09R2DesignAuthorityStatus.invalidArgument
    }
    let input: G09R2DesignAuthorityPrepareInput
    do {
        input = try G09CreativeWire.decoder().decode(
            G09R2DesignAuthorityPrepareInput.self, from: Data(raw.utf8))
    } catch {
        return G09R2DesignAuthorityStatus.invalidArgument
    }
    guard let entry = G09R2DesignAuthorityRegistry.shared.entry(
        epoch: UInt64(ownerEpoch)),
          entry.store.epoch == UInt64(ownerEpoch),
          let service = entry.service else {
        return G09R2DesignAuthorityStatus.notReady
    }
    let result = designAuthorityBlocking {
        try await service.prepareTrustedRestructure(input)
    }
    switch result {
    case .failure(let error):
        if let typed = error as? G09R2Error {
            switch typed.code {
            case "designConflict":
                return G09R2DesignAuthorityStatus.mismatch
            case "designTargetUnavailable":
                return G09R2DesignAuthorityStatus.notReady
            default:
                return G09R2DesignAuthorityStatus.invalidArgument
            }
        }
        if error is DesignTargetError {
            return G09R2DesignAuthorityStatus.mismatch
        }
        if error is DesignRestructureAuthorityError {
            return G09R2DesignAuthorityStatus.mismatch
        }
        return G09R2DesignAuthorityStatus.invalidArgument
    case .success(let dto):
        do {
            let data = try G09CreativeWire.encoder().encode(dto)
            guard data.count + 1
                <= G09R2DesignAuthorityLimits.maximumDisplayJSONBytes else {
                return G09R2DesignAuthorityStatus.invalidArgument
            }
            return DesignAuthorityABI.copyJSON(
                data, to: outJSON, capacity: outCapacity)
        } catch {
            return G09R2DesignAuthorityStatus.invalidArgument
        }
    }
}

@_cdecl("floe_design_authority_confirm")
public func floeDesignAuthorityConfirm(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ token: UnsafePointer<CChar>?
) -> Int32 {
    guard DesignAuthorityABI.ownerProofValid(ownerEpoch, ownerToken) else {
        return G09R2DesignAuthorityStatus.ownerProofInvalid
    }
    guard let value = DesignAuthorityABI.cString(
        token, maximum: G09R2DesignAuthorityLimits.maximumTokenBytes),
          G09R2DesignRestructureAuthorityStore.isValidToken(value) else {
        return G09R2DesignAuthorityStatus.invalidArgument
    }
    guard let store = G09R2DesignAuthorityRegistry.shared.store(
        epoch: UInt64(ownerEpoch)) else {
        return G09R2DesignAuthorityStatus.notReady
    }
    return store.confirm(token: value)
}

@_cdecl("floe_design_authority_revoke")
public func floeDesignAuthorityRevoke(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ token: UnsafePointer<CChar>?
) -> Int32 {
    guard DesignAuthorityABI.ownerProofValid(ownerEpoch, ownerToken) else {
        return G09R2DesignAuthorityStatus.ownerProofInvalid
    }
    guard let value = DesignAuthorityABI.cString(
        token, maximum: G09R2DesignAuthorityLimits.maximumTokenBytes),
          G09R2DesignRestructureAuthorityStore.isValidToken(value) else {
        return G09R2DesignAuthorityStatus.invalidArgument
    }
    guard let store = G09R2DesignAuthorityRegistry.shared.store(
        epoch: UInt64(ownerEpoch)) else {
        return G09R2DesignAuthorityStatus.notReady
    }
    return store.revoke(token: value)
        ? G09R2DesignAuthorityStatus.ok
        : G09R2DesignAuthorityStatus.notFound
}

/// Root-stop helper for the App. The design service also retires its own store
/// through the aggregate design drain; this export is the explicit cancel path.
@_cdecl("floe_design_authority_retire")
public func floeDesignAuthorityRetire(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?
) -> Int32 {
    guard DesignAuthorityABI.ownerProofValid(ownerEpoch, ownerToken) else {
        return G09R2DesignAuthorityStatus.ownerProofInvalid
    }
    guard let store = G09R2DesignAuthorityRegistry.shared.store(
        epoch: UInt64(ownerEpoch)) else {
        return G09R2DesignAuthorityStatus.notReady
    }
    store.retire()
    return G09R2DesignAuthorityStatus.ok
}
