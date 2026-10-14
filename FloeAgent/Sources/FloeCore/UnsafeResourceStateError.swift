// FloeCore — shared unsafe-resource-state failure contract.
//
// Some failures leave resources that may still be live: native engine workers,
// a working copy that cannot be safely deleted, or a session whose close was
// never acknowledged. Every consumer (job service, adapters, UI) MUST treat
// such a failure as outranking a cancellation request: the operation did not
// stop cleanly, its staging is retained for recovery, and reporting a clean
// "cancelled" state would hide live work. The protocol lives in FloeCore so
// module boundaries (Documents ↔ Execution) never need a direct dependency.
//
// Conforming to this protocol is NOT by itself proof of an unsafe state: an
// error family may wrap both genuinely unsafe failures and ordinary safe ones
// (documents' `OfficeAutomaticExecutionError` wraps cancellation, output
// conflicts and close-ack failures in one enum). The `isUnsafeResourceState`
// discriminant is the single decision every consumer reads; the default keeps
// new conformers conservative (unsafe) unless they explicitly narrow it.

import Foundation

public protocol UnsafeResourceStateError: Error {
    /// Human-readable reason, safe to show in bounded diagnostics.
    var unsafeResourceReason: String { get }

    /// True ONLY when this specific failure leaves resources that may still be
    /// live (native workers, a retained working copy/staging) and therefore
    /// outranks a cancellation request. A conforming error whose discriminant
    /// is false is an ordinary failure: it must keep the normal error path and
    /// must never be reported with retained-staging/live-worker wording.
    var isUnsafeResourceState: Bool { get }
}

public extension UnsafeResourceStateError {
    /// Conservative default: an unclassified conforming failure is unsafe.
    var isUnsafeResourceState: Bool { true }
}
