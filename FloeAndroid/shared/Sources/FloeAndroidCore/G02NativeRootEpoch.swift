// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — TRUE native rootEpoch status/readback.
//
// Authority (MAIN_TEMP_ACK_NATIVE_EPOCH_DECISION_20261019.json):
//   * "epoch is the ACTUAL trusted native root-generation epoch associated
//     with that native temporary incarnation and admitted temp.end command,
//     never UI holder/session AtomicLong or guessed 0."
//   * "Keep App holder sessionEpoch for UIcallback/session/disposal fencing.
//     Add/bind a separate nativeRootEpoch to TemporarySessionRef from
//     authoritative temp.start/lifecycle/bootstrap value; missing readback
//     fails closed."
//   * "Map safely to existing JNI positiveLong range, no lossyfloat/
//     coercion."
//
// What exists TODAY (read at authoring time):
//   * `floe_runtime_status` already exposes the accepted root epoch as
//     `generation` (UInt64) — lock-only, no path/token.
//   * The RB5 temporary domain runs under ONE accepted epoch
//     (`TemporaryDomainComponents.epoch`); its `temp.start` accepted value
//     did NOT expose that epoch — the App had nothing authoritative to bind.
//
// What this file delivers:
//   1. `G02NativeRootEpoch.readback(epoch:)` — the narrow native readback:
//      the CURRENT accepted epoch, validated against the live generation.
//      This is the same value the existing status snapshot reports as
//      `generation`; it is re-exposed here so the trusted host can bind the
//      temp.start response epoch WITHOUT polling the whole status frame.
//   2. `app-deltas/RuntimeFacadeTemporary.g02-root-epoch.patch` — the ONE
//      additive delta to the RB5 temp source: the `temp.start` accepted
//      value gains `"rootEpoch": <components.epoch>`. The navigation-fence
//      acknowledgement (`value.navigationFence.epoch`, produced by the RB5
//      TMP-NAV-2 repair) MUST carry this same epoch; the App then binds it
//      to `TemporarySessionRef.nativeRootEpoch`.
//   3. The Kotlin minimal adapter deltas under `app-deltas/`:
//      `TemporarySessionRef.nativeRootEpoch` + `temp.start` mapping +
//      `Acknowledgement.matches` nativeRootEpoch comparison, with the UI
//      `sessionEpoch` preserved separately.
//
// Honesty: until the RB5 delta is applied by the serialized qualifier, the
// App-side binding fails closed (no fabricated 0, no UI-counter echo).
//
// This source is NOT compiled/executed by the authoring package.
import Foundation

public enum G02NativeRootEpoch {

    /// The ACTUAL trusted native root-generation epoch for the live
    /// generation, or nil when no generation is starting (never 0-as-epoch
    /// and never a UI counter).
    public static func readback() -> UInt64? {
        guard let pumps = AndroidRuntimeBootstrap.currentPumps(),
              !pumps.mailbox.isAdmissionFenced else {
            return nil
        }
        return pumps.epoch
    }
}

// MARK: - Trusted-host native readback (narrow; clearly identified)

private func g02CopyEpochCString(_ value: UInt64,
                                 buffer: UnsafeMutablePointer<CChar>?,
                                 capacity: Int32) -> Int32 {
    // Decimal string inside the positive Int64 JNI range (epochs are small
    // practical counters; the contract forbids lossy float coercion).
    let text = String(value)
    guard capacity >= 0, let buffer else { return RuntimeFacadeStatus.invalidArguments }
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return RuntimeFacadeStatus.bufferTooSmall }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

/// Narrow trusted-host readback of the CURRENT native root epoch. Returns
/// `RuntimeFacadeStatus.notInstalled` when no live generation exists — the
/// host MUST fail closed (never bind 0). Distinct from
/// `floe_runtime_status`: this carries ONLY the epoch, no other status.
@_cdecl("floe_g02_native_root_epoch")
public func floeG02NativeRootEpoch(
    _ outBuffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard let epoch = G02NativeRootEpoch.readback() else {
        return RuntimeFacadeStatus.notInstalled
    }
    return g02CopyEpochCString(epoch, buffer: outBuffer, capacity: capacity)
}
