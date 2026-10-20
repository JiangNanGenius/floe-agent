// SPDX-License-Identifier: MPL-2.0
//
// RB-6 additive port extraction for host compilation (Main admission
// 2026-10-19: "The exact RunOwnedToolCancellation source protocol may be
// published additively from the reviewed real run source when required for
// module types; no fake run producer/ready").
//
// Source authority: runtime-runs-native-assembly-repair-source (job-047bee7a
// 3eff4941) candidate RuntimeFacadeRunIngress.swift:188 — the REVIEWED repair
// candidate, not the older input/ copy. The declaration below is byte-exact
// (comments included) and depends only on Foundation.UUID. The later actual
// Run domain publication owns the wire handler and the run producer; it must
// NOT redeclare this protocol (remove the duplicate from its
// RuntimeFacadeRunIngress.swift at publication). This file supplies ONLY the
// type FacadeToolWorkCoordinator conforms to; nothing here produces a run,
// registers a command, or grants capability from a protocol/no-op presence.
import Foundation

/// RB6-owned: cancellation of ACTUAL owned tool work started under the
/// facade's run (skill/MCP/registry-bound workers). Never a fabricated
/// Linux job id; G02 web/cloud runs carry no Linux role and this port must
/// not invent one (contract scopes.taskExecution).
public protocol RunOwnedToolCancellation: Sendable {
    /// Returns true when a live owned worker for that exact run (+optional
    /// provider call id) accepted cooperative cancellation. False means no
    /// such owned work exists (nothing to cancel) — never a fake success.
    func cancelOwnedTool(runID: UUID, callID: String?, epoch: UInt64) async -> Bool
}
