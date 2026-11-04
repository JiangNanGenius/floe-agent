// ARM64MachineError.swift — typed failures for the ARM64 machine adapter.
//
// Every error is one of: caller configuration problems (fix the request),
// engine refusals mapped 1:1 from FLOE_AE_* codes, lifecycle races surfaced
// honestly (BUSY is never success), or channel-level consumer failures. The
// adapter never invents success for a partial engine result.

import Foundation
import FloeARM64Engine

/// Maps an engine result code to a typed error. `FLOE_AE_OK` never reaches
/// here; callers check the code before mapping.
enum ARM64EngineCode {
    /// Human-stable name for logs (e.g. "BUSY"); the numeric code stays
    /// authoritative in evidence.
    static func name(_ code: Int32) -> String {
        switch code {
        case Int32(FLOE_AE_OK): return "OK"
        case Int32(FLOE_AE_INVALID): return "INVALID"
        case Int32(FLOE_AE_STALE): return "STALE"
        case Int32(FLOE_AE_FAULT): return "FAULT"
        case Int32(FLOE_AE_BUSY): return "BUSY"
        case Int32(FLOE_AE_IO): return "IO"
        case Int32(FLOE_AE_NOMEM): return "NOMEM"
        case Int32(FLOE_AE_VERSION): return "VERSION"
        case Int32(FLOE_AE_UNSUPPORTED): return "UNSUPPORTED"
        default: return "UNKNOWN(\(code))"
        }
    }
}

public enum ARM64MachineError: Error, Equatable, CustomStringConvertible {
    /// The caller's config failed local validation; nothing reached the
    /// engine. `detail` is safe to surface (paths truncated).
    case invalidConfiguration(String)
    /// A verified boot asset digest did not match the caller-authorized
    /// record. The machine is never created from mismatched bytes.
    case assetDigestMismatch(String)
    /// floe_ae_create refused the config (codes VERSION/UNSUPPORTED/INVALID/
    /// IO/NOMEM/FAULT). A second live machine surfaces here as BUSY.
    case createFailed(code: Int32, detail: String)
    /// floe_ae_run_slice reported a guest fault; the engine state is FAILED.
    case guestFault
    /// The machine is not running for an operation that requires it.
    case notRunning
    /// Engine returned BUSY for a lifecycle call that must not be retried
    /// silently (e.g. destroy while a slice is active). Never treated as
    /// success; the owner must reset the session.
    case engineBusy(String)
    /// Stale generation: an enqueued operation belonged to a previous
    /// start/stop generation and was fenced instead of executing.
    case staleGeneration
    /// A console consumer-side failure: the channel was failed closed (stuck
    /// consumer, local stream error). The machine keeps running; the owner
    /// must close that project/console.
    case consoleFailed(channel: UInt32, detail: String)
    /// The console write could not be fully accepted before the deadline or
    /// the machine stopped; the unwritten remainder was discarded, never
    /// executed later.
    case writeIncomplete(channel: UInt32, accepted: Int, requested: Int)
    /// Channel index outside the created channel set.
    case channelUnavailable(UInt32)
    /// stop() timed out waiting for the worker to leave its slice; the
    /// machine was deliberately NOT destroyed (state stays running).
    case stopTimeout
    /// destroy reported an engine failure while the adapter shut the worker
    /// down; the process should treat the machine slot as poisoned.
    case destroyFailed(code: Int32)

    public var description: String {
        switch self {
        case .invalidConfiguration(let detail): return "invalidConfiguration(\(detail))"
        case .assetDigestMismatch(let detail): return "assetDigestMismatch(\(detail))"
        case .createFailed(let code, let detail): return "createFailed(\(ARM64EngineCode.name(code)): \(detail))"
        case .guestFault: return "guestFault"
        case .notRunning: return "notRunning"
        case .engineBusy(let detail): return "engineBusy(\(detail))"
        case .staleGeneration: return "staleGeneration"
        case .consoleFailed(let channel, let detail): return "consoleFailed(\(channel): \(detail))"
        case .writeIncomplete(let channel, let accepted, let requested): return "writeIncomplete(\(channel): \(accepted)/\(requested))"
        case .channelUnavailable(let channel): return "channelUnavailable(\(channel))"
        case .stopTimeout: return "stopTimeout"
        case .destroyFailed(let code): return "destroyFailed(\(ARM64EngineCode.name(code)))"
        }
    }
}

/// Terminal outcome the worker reports after its run loop exits and the
/// engine handle has been destroyed.
public enum ARM64MachineExit: Sendable, Equatable {
    /// Sticky stop requested by the owner.
    case stopped
    /// The guest powered off (ACPI/PSCI path).
    case guestPoweredOff
    /// The guest hit an engine fault; `lastError` holds the engine code.
    case guestFault(Int32)
    /// The worker could not finish creation; nothing ran.
    case createFailed(code: Int32)
}

/// Result of an owner-requested stop.
public enum ARM64StopOutcome: Sendable, Equatable {
    /// The worker joined and the engine handle was destroyed.
    case stopped(ARM64MachineExit)
    /// The worker did not leave its slice within the deadline; the machine
    /// is intentionally left running so the engine is never destroyed under
    /// an active slice.
    case timeoutStillRunning
}
