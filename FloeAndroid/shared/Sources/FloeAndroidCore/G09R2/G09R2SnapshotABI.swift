// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — trusted-host snapshot lease ABI (job-b72b2978320e484e).
//
// The frozen `floe.creative/6` action list has no snapshot action, so the App
// host reaches the native lease authority through this narrow host-only C ABI
// (the same reviewed shape as the render-ticket pump). It is NOT a bridge
// version, NOT a model tool and NOT a second project store: every request is
// validated against the SAME bound `G09CreativeDomainService` cluster and the
// exact epoch/root/revision/timeline digest.
//
// Acquire returns a bounded JSON lease (or a typed failure object); release
// returns 0 or a typed negative. The App must never construct a lease by
// value — only these functions issue one.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func g09r2SnapshotEncode(_ object: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]) else { return nil }
    return data
}

private func g09r2SnapshotFailure(_ error: Error) -> [String: Any] {
    if let typed = error as? G09R2Error {
        return BridgeV6Handler.failure(typed)
    }
    return G09CreativeWire.failure(G09CreativeError.map(error))
}

private func g09r2SnapshotCopy(_ data: Data,
                               _ buffer: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return -106 }
    guard data.count + 1 <= Int(capacity) else { return -106 }
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        memcpy(buffer, base, data.count)
    }
    buffer[data.count] = 0
    return Int32(data.count)
}

/// Blocking host entry. `requestJSON` is the exact
/// `G09R2RenderSnapshotRequestDTO` (context + expectedRevision +
/// expectedTimelineDigest). The reply is the native-issued
/// `G09R2RenderSnapshotLeaseDTO` object or a typed failure object.
@_cdecl("floe_media_snapshot_acquire")
public func floeMediaSnapshotAcquire(
    _ epoch: UInt64,
    _ requestJSON: UnsafePointer<CChar>?,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard epoch > 0, let requestJSON else { return -105 }
    let length = strnlen(requestJSON, 16_385)
    guard length > 0, length <= 16_384 else { return -107 }
    let bytes = UnsafeRawPointer(requestJSON).assumingMemoryBound(to: UInt8.self)
    let data = Data(bytes: bytes, count: length)
    let request: G09R2RenderSnapshotRequestDTO
    do {
        request = try G09CreativeWire.decoder().decode(
            G09R2RenderSnapshotRequestDTO.self, from: data)
    } catch {
        let object = g09r2SnapshotFailure(G09CreativeError.invalidPayload("malformedPayload"))
        guard let encoded = g09r2SnapshotEncode(object) else { return -108 }
        return g09r2SnapshotCopy(encoded, buffer, capacity)
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = SnapshotResultBox()
    Task {
        do {
            let lease = try await G09R2MediaFoundation.shared.acquireSnapshot(
                service: BridgeV5.service, epoch: epoch, request: request)
            var object = try G09CreativeWire.object(lease)
            object["ok"] = true
            box.set(.success(object))
        } catch {
            box.set(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    let object: [String: Any]
    switch box.get() {
    case .success(let value): object = value
    case .failure(let error): object = g09r2SnapshotFailure(error)
    case .none:
        object = g09r2SnapshotFailure(G09CreativeError.storageUnavailable)
    }
    guard let encoded = g09r2SnapshotEncode(object) else { return -108 }
    return g09r2SnapshotCopy(encoded, buffer, capacity)
}

/// Idempotent release of an exact lease object (JSON). 0 = released/unknown
/// (idempotent), negative = stale epoch / mismatch.
@_cdecl("floe_media_snapshot_release")
public func floeMediaSnapshotRelease(
    _ epoch: UInt64,
    _ leaseJSON: UnsafePointer<CChar>?
) -> Int32 {
    guard epoch > 0, let leaseJSON else { return -105 }
    let length = strnlen(leaseJSON, 16_385)
    guard length > 0, length <= 16_384 else { return -107 }
    let bytes = UnsafeRawPointer(leaseJSON).assumingMemoryBound(to: UInt8.self)
    let data = Data(bytes: bytes, count: length)
    let lease: G09R2RenderSnapshotLeaseDTO
    do {
        lease = try G09CreativeWire.decoder().decode(
            G09R2RenderSnapshotLeaseDTO.self, from: data)
    } catch {
        return -105
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = SnapshotStatusBox()
    Task {
        do {
            try await G09R2MediaFoundation.shared.releaseSnapshot(
                service: BridgeV5.service, epoch: epoch, lease: lease)
            box.set(0)
        } catch let typed as G09R2Error {
            box.set(typed.code == G09R2WireError.renderTicketNotFound.code ? -101 : -105)
        } catch {
            box.set(-105)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.get()
}

private final class SnapshotResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[String: Any], Error>?
    func set(_ result: Result<[String: Any], Error>) {
        lock.lock(); value = result; lock.unlock()
    }
    func get() -> Result<[String: Any], Error>? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

private final class SnapshotStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = -105
    func set(_ status: Int32) { lock.lock(); value = status; lock.unlock() }
    func get() -> Int32 { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Prepared render binding (plain App host seam)

/// Exact `prepareRenderBinding` request. It carries only the trusted context,
/// the immutable revision the UI is displaying and a bounded attempt identity;
/// the native side loads the project itself and returns the canonical digest
/// plus an immutable native lease. The App never rebuilds canonical JSON.
public struct G09R2PrepareRenderBindingRequest: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public var expectedRevision: Int64
    public var attemptID: String
}

/// Resolves BOTH image and video projects through the SAME native load and
/// snapshot authority, in one bounded call. Reply is the frozen
/// `G09R2MediaExportBindingDTO` object or a typed failure object.
@_cdecl("floe_media_render_prepare")
public func floeMediaRenderPrepare(
    _ epoch: UInt64,
    _ requestJSON: UnsafePointer<CChar>?,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard epoch > 0, let requestJSON else { return -105 }
    let length = strnlen(requestJSON, 16_385)
    guard length > 0, length <= 16_384 else { return -107 }
    let bytes = UnsafeRawPointer(requestJSON).assumingMemoryBound(to: UInt8.self)
    let data = Data(bytes: bytes, count: length)
    let request: G09R2PrepareRenderBindingRequest
    do {
        request = try G09CreativeWire.decoder().decode(
            G09R2PrepareRenderBindingRequest.self, from: data)
    } catch {
        let object = g09r2SnapshotFailure(
            G09CreativeError.invalidPayload("malformedPayload"))
        guard let encoded = g09r2SnapshotEncode(object) else { return -108 }
        return g09r2SnapshotCopy(encoded, buffer, capacity)
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = SnapshotResultBox()
    Task {
        do {
            let binding = try await G09R2MediaFoundation.shared.prepareRenderBinding(
                service: BridgeV5.service, epoch: epoch,
                context: request.context,
                expectedRevision: request.expectedRevision,
                attemptID: request.attemptID)
            var object = try G09CreativeWire.object(binding)
            object["ok"] = true
            box.set(.success(object))
        } catch {
            box.set(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    let object: [String: Any]
    switch box.get() {
    case .success(let value): object = value
    case .failure(let error): object = g09r2SnapshotFailure(error)
    case .none:
        object = g09r2SnapshotFailure(G09CreativeError.storageUnavailable)
    }
    guard let encoded = g09r2SnapshotEncode(object) else { return -108 }
    return g09r2SnapshotCopy(encoded, buffer, capacity)
}
