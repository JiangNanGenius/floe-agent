// SPDX-License-Identifier: MPL-2.0
//
// Queue-only host hooks on the exact-run session handle. These extensions add
// no new authority: they forward to the session's narrow queue-only methods,
// which validate the immutable session identity and the durable row state
// before touching the runtime.

import Foundation

/// Withdrawal of one accepted-but-unconsumed guidance row so the host can
/// demote it back to the ordinary message queue (the "Back to queue" action).
extension FloeMacSelfSessionHandle {

    /// Withdraws the guidance row `id` from this exact run and restores it to
    /// the ordinary queue. Returns true only when the row is now `queued`;
    /// false means the row was already consumed, already changed, bound to
    /// another run, or this session is no longer live — in every false case
    /// the durable row keeps its honest status and the host must only refresh.
    public func withdrawSteer(id: UUID) async -> Bool {
        await session.withdrawSteerForQueueDemotion(id: id)
    }
}
