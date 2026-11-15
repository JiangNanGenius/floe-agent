// ARM64VideoStatus.swift — stable primary-consumed video service snapshot.
//
// One value shape serves every owner: the standard virtio-media V4L2 nodes
// and the additive typed broker are aggregated by the engine; this Swift
// type only describes what the machine actually reports. Hardware and native
// software outputs stay separate because a proven public software path (for
// example ImageIO JPEG) is never hardware. `present` is false for a running
// machine whose verified image did not opt into video acceleration; that is
// an honest "unavailable", not a failure to query.

import Foundation

public struct ARM64VideoStatus: Sendable, Equatable {
    /// The engine built the video service for this machine. False on an image
    /// whose manifest did not declare video acceleration or when no machine
    /// is running (callers receive nil for a powered-off machine).
    public var present: Bool
    /// Completed outputs that the host reported as hardware-accelerated.
    public var hardwareOutputs: UInt64
    /// Completed outputs from a proven native software path (VideoToolbox
    /// software session or the ImageIO JPEG fallback). Never hardware.
    public var nativeSoftwareOutputs: UInt64
    /// The live policy allows proven native software formats. Default false
    /// (strict hardware-only), matching the C ABI default.
    public var nativeSoftwareEnabled: Bool
    /// Number of codec/direction formats currently proven as native software
    /// on this machine (0 when the host measured none).
    public var nativeSoftwareFormats: Int
    /// Live codec sessions across both V4L2 nodes and the typed broker.
    public var sessions: UInt32
    /// Submitted work items not yet completed.
    public var inflight: UInt32
    /// Native host bytes currently owned by video work/output queues.
    public var hostOwnedBytes: UInt64
    /// Cumulative engine-side session errors.
    public var errorCount: UInt64

    public init(
        present: Bool,
        hardwareOutputs: UInt64 = 0,
        nativeSoftwareOutputs: UInt64 = 0,
        nativeSoftwareEnabled: Bool = false,
        nativeSoftwareFormats: Int = 0,
        sessions: UInt32 = 0,
        inflight: UInt32 = 0,
        hostOwnedBytes: UInt64 = 0,
        errorCount: UInt64 = 0
    ) {
        self.present = present
        self.hardwareOutputs = hardwareOutputs
        self.nativeSoftwareOutputs = nativeSoftwareOutputs
        self.nativeSoftwareEnabled = nativeSoftwareEnabled
        self.nativeSoftwareFormats = nativeSoftwareFormats
        self.sessions = sessions
        self.inflight = inflight
        self.hostOwnedBytes = hostOwnedBytes
        self.errorCount = errorCount
    }

    /// Honest unavailable value for a running machine without video. It
    /// preserves the saved user preference so a future capable image can
    /// apply it, without pretending any device exists.
    public static func unavailable(nativeSoftwareEnabled: Bool) -> ARM64VideoStatus {
        ARM64VideoStatus(present: false, nativeSoftwareEnabled: nativeSoftwareEnabled)
    }
}
