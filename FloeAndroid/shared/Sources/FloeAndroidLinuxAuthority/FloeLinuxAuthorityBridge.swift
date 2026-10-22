// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 — additive C ABI for the Linux environment authority.
//
//   const char* floe_linux_authority_exchange(const char* request_utf8);
//   void        floe_linux_authority_free(const char* response);
//
// Contract (matches Main's `LinuxAuthorityNative` JNI: standardUTF8, max
// 64 KiB, calls arrive on a SERIALIZED native IO executor):
// - The request pointer must be a NUL-terminated UTF-8 JSON envelope of at
//   most 65536 bytes. Anything larger fails closed with a typed
//   `requestTooLarge` reply; malformed/non-UTF8 traffic gets `invalidWire`.
//   Only a nil input returns nil — every non-nil call returns a valid
//   UTF-8 NUL-terminated JSON reply buffer that the caller MUST pass to
//   `floe_linux_authority_free` exactly once.
// - Threading/lifetime: this function performs ONE bounded hop into the
//   `FloeLinuxAuthority` actor (global concurrent executor) and blocks the
//   CALLER thread until the reply exists. No MainActor is ever involved:
//   nothing in this path can enqueue work on the main thread, so a main
//   thread could deadlock only by ALSO owning work the actor awaits, which
//   the authority never does (no network, no process waits, bounded local
//   filesystem operations only). The intended caller is the serialized
//   native IO executor thread; concurrent calls from multiple threads are
//   safe (actor-serialized) but not required.
// - Deliberately NO synthetic timeout: every authority operation is bounded
//   (registry prepare/acquire are local filesystem + actor hops). A fake
//   timeout would report failure for an operation that may still commit
//   (e.g. an acquired lease), creating an orphan state the caller then has
//   to guess about. If the underlying authority ever hangs, that hang is
//   observable on the serialized executor instead of being masked.
// - The bridge owns nothing beyond reply allocation: the returned buffer is
//   a fresh malloc'd C string (matching the qualified `floe_bridge_*`
//   pattern); the request memory stays owned by the caller/JNI layer.

import Foundation
import FloeCore
import FloeTools
import FloeEnvironments

/// Synchronous access helpers for Main's native ingress (JNI/other C
/// callers) plus the process-wide shared authority instance.
public enum FloeLinuxAuthorityBridge {
    /// The instance behind the C entry points (one per runtime process).
    public static var sharedAuthority: FloeLinuxAuthority { .shared }

    /// Blocking, bounded exchange for non-async callers. Safe to call from a
    /// dedicated native IO thread; never from inside the authority itself.
    public static func blockingExchange(_ request: Data, authority: FloeLinuxAuthority = .shared) -> Data {
        let gate = DispatchSemaphore(value: 0)
        let box = BlockingReplyBox()
        Task.detached(priority: .userInitiated) {
            let reply = await authority.exchange(request)
            box.set(reply)
            gate.signal()
        }
        gate.wait()
        return box.take()
    }
}

/// One-shot reply slot synchronized by the semaphore's happens-before; the
/// lock makes the hand-off explicit for strict-concurrency checking.
private final class BlockingReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: Data?

    func set(_ data: Data) {
        lock.lock()
        reply = data
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return reply ?? Data()
    }
}

/// C entry: exchange one bounded version-1 JSON envelope with the shared
/// authority. The result is heap-allocated UTF-8 JSON (NUL-terminated);
/// free it with `floe_linux_authority_free` exactly once.
@_cdecl("floe_linux_authority_exchange")
public func floe_linux_authority_exchange(_ request: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    guard let request else { return nil }
    let length = strnlen(request, LinuxAuthorityWire.maximumBytes + 1)
    let reply: Data
    if length == 0 {
        reply = LinuxAuthorityWire.failureData(code: .invalidWire, message: "empty request", requestID: nil)
    } else if length > LinuxAuthorityWire.maximumBytes {
        reply = LinuxAuthorityWire.failureData(code: .requestTooLarge,
                                               message: "request exceeds the \(LinuxAuthorityWire.maximumBytes)-byte wire ceiling",
                                               requestID: nil)
    } else {
        let data = Data(bytes: request, count: length)
        reply = FloeLinuxAuthorityBridge.blockingExchange(data)
    }
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: reply.count + 1)
    reply.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: reply.count))
    buffer[reply.count] = 0
    return UnsafePointer(buffer)
}

/// C entry: release a buffer returned by `floe_linux_authority_exchange`
/// exactly once. nil is ignored so a JNI cleanup path can stay simple.
@_cdecl("floe_linux_authority_free")
public func floe_linux_authority_free(_ response: UnsafePointer<CChar>?) {
    guard let response else { return }
    UnsafeMutablePointer(mutating: response).deallocate()
}
