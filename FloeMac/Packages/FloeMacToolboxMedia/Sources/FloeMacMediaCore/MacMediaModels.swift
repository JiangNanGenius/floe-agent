import Foundation
import CoreGraphics

// MARK: - Permission

/// Media hardware the toolbox can ask for. Photo-library access is deliberately
/// absent: image import uses a user-selected file (NSOpenPanel) and never the
/// Photos library, so no photo-library permission is requested or required.
public enum MacMediaKind: String, Sendable, Hashable, CaseIterable {
    case microphone
    case camera
}

/// Mirrors the AVFoundation authorization states without exposing AV types to
/// the testable core.
public enum MacMediaAuthorization: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable

    public var isAuthorized: Bool { self == .authorized }
    /// A system prompt may only be shown from `notDetermined`.
    public var canRequest: Bool { self == .notDetermined }
}

/// Abstraction over `AVCaptureDevice.authorizationStatus`/`requestAccess`.
/// The system implementation lives in `FloeMacMediaSystem`; tests inject a
/// deterministic authorizer and never touch TCC.
public protocol MacMediaAuthorizing: Sendable {
    func authorization(for kind: MacMediaKind) -> MacMediaAuthorization
    func requestAuthorization(for kind: MacMediaKind) async -> MacMediaAuthorization
}

/// Deterministic authorizer for previews and tests.
public struct MacFixedAuthorizer: MacMediaAuthorizing {
    public var statuses: [MacMediaKind: MacMediaAuthorization]
    /// Result returned by a request, and persisted so a second request is stable.
    public var requestResult: MacMediaAuthorization

    public init(
        statuses: [MacMediaKind: MacMediaAuthorization] = [:],
        requestResult: MacMediaAuthorization = .denied
    ) {
        self.statuses = statuses
        self.requestResult = requestResult
    }

    public func authorization(for kind: MacMediaKind) -> MacMediaAuthorization {
        statuses[kind] ?? .notDetermined
    }

    public func requestAuthorization(for kind: MacMediaKind) async -> MacMediaAuthorization {
        requestResult
    }
}

// MARK: - Failures

/// Stable failure codes. User-facing copy is localized in the UI layer; these
/// raw cases are what tests and diagnostics assert against.
public enum MacMediaFailure: Error, Equatable, Sendable {
    case notAuthorized
    case noDevice
    case deviceBusy
    case invalidFormat
    case mediaServicesReset
    case engine(String)
    case captureFailed(String)
    /// A scan page would exceed `OpticsScanExport.maximumPages`.
    case pageLimit
    /// Imported bytes exceed the shared image ceilings.
    case fileTooLarge
    case fileNotRegular
    case fileIsSymbolicLink
    case unreadable
    case emptyExport
    case exportTooLarge
    case writeFailed(String)

    /// Diagnostics only. Views must never display this string directly.
    public var diagnosticCode: String {
        switch self {
        case .notAuthorized: "not-authorized"
        case .noDevice: "no-device"
        case .deviceBusy: "device-busy"
        case .invalidFormat: "invalid-format"
        case .mediaServicesReset: "media-services-reset"
        case .engine(let code): "engine:\(code)"
        case .captureFailed(let code): "capture:\(code)"
        case .pageLimit: "page-limit"
        case .fileTooLarge: "file-too-large"
        case .fileNotRegular: "file-not-regular"
        case .fileIsSymbolicLink: "file-symbolic-link"
        case .unreadable: "unreadable"
        case .emptyExport: "empty-export"
        case .exportTooLarge: "export-too-large"
        case .writeFailed(let code): "write:\(code)"
        }
    }
}

// MARK: - Exclusive device lease

/// Identifies one window's hold on a capture device. `generation` increases on
/// every successful acquisition so stale callbacks can be fenced out.
public struct MacDeviceLease: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: MacMediaKind
    public let owner: UUID
    public let generation: UInt64

    public init(id: UUID = UUID(), kind: MacMediaKind, owner: UUID, generation: UInt64) {
        self.id = id
        self.kind = kind
        self.owner = owner
        self.generation = generation
    }
}

/// One hold across every toolbox window, matching the iOS `OpticsCaptureService`
/// contract: exactly one capture owner at a time, and a stale release never
/// disturbs a newer owner. A second window receives `nil` and must present the
/// busy state instead of stealing the device.
@MainActor
public final class MacDeviceLeaseBroker {
    public private(set) var activeLease: MacDeviceLease?
    private var counter: UInt64 = 0

    public init() {}

    public func acquire(_ kind: MacMediaKind, owner: UUID) -> MacDeviceLease? {
        guard activeLease == nil else { return nil }
        counter &+= 1
        let lease = MacDeviceLease(kind: kind, owner: owner, generation: counter)
        activeLease = lease
        return lease
    }

    public func owns(_ lease: MacDeviceLease?) -> Bool {
        guard let lease else { return false }
        return activeLease == lease
    }

    /// Releases only when `lease` is still the active one.
    @discardableResult
    public func release(_ lease: MacDeviceLease) -> Bool {
        guard activeLease == lease else { return false }
        activeLease = nil
        return true
    }

    @discardableResult
    public func releaseAll(owner: UUID) -> Bool {
        guard let activeLease, activeLease.owner == owner else { return false }
        self.activeLease = nil
        return true
    }

    public func isBusy(for owner: UUID) -> Bool {
        guard let activeLease else { return false }
        return activeLease.owner != owner
    }

    public func activeLease(for kind: MacMediaKind) -> MacDeviceLease? {
        guard let activeLease, activeLease.kind == kind else { return nil }
        return activeLease
    }
}

// MARK: - Camera surface

public enum MacCameraIssue: Equatable, Sendable {
    case none
    /// The device exists but another client (system camera, another app) owns it.
    case inUseByAnotherApplication
    case interrupted
    case failed(String)

    public var isBusy: Bool { self == .inUseByAnotherApplication }
}

/// What the magnifier/scanner window should present. Mirrors the iOS
/// `OpticsMagnifierView.Surface` ordering so both platforms read the same way.
public enum MacCameraSurface: String, Sendable, Equatable {
    case idle
    case denied
    case noDevice
    case busy
    case interrupted
    case failed
    case starting
    case running
    case frozen
}

public struct MacCameraInputs: Sendable, Equatable {
    public var holdsLease: Bool
    /// A start attempt found the single lease taken by another window.
    public var leaseConflict: Bool
    public var authorization: MacMediaAuthorization
    public var deviceAvailable: Bool
    /// A start attempt completed authorization but found no camera.
    public var deviceProbeFailed: Bool
    public var running: Bool
    public var issue: MacCameraIssue
    public var frozen: Bool

    public init(
        holdsLease: Bool = false,
        leaseConflict: Bool = false,
        authorization: MacMediaAuthorization = .notDetermined,
        deviceAvailable: Bool = false,
        deviceProbeFailed: Bool = false,
        running: Bool = false,
        issue: MacCameraIssue = .none,
        frozen: Bool = false
    ) {
        self.holdsLease = holdsLease
        self.leaseConflict = leaseConflict
        self.authorization = authorization
        self.deviceAvailable = deviceAvailable
        self.deviceProbeFailed = deviceProbeFailed
        self.running = running
        self.issue = issue
        self.frozen = frozen
    }
}

public enum MacCameraSurfaceResolver {
    /// Precedence: active lease state first, then terminal failures that can
    /// happen before a lease exists. A window that lost the lease race must see
    /// `busy`, not `idle`; a denied/absent device must stay visible instead of
    /// silently looking like an unopened tool.
    public static func surface(for inputs: MacCameraInputs) -> MacCameraSurface {
        if inputs.holdsLease {
            switch inputs.authorization {
            case .denied, .restricted, .unavailable: return .denied
            case .notDetermined, .authorized: break
            }
            guard inputs.deviceAvailable else { return .noDevice }
            switch inputs.issue {
            case .inUseByAnotherApplication: return .busy
            case .interrupted: return .interrupted
            case .failed: return .failed
            case .none: break
            }
            if inputs.frozen { return .frozen }
            if inputs.running { return .running }
            return .starting
        }
        if inputs.leaseConflict { return .busy }
        switch inputs.authorization {
        case .denied, .restricted, .unavailable: return .denied
        case .notDetermined, .authorized: break
        }
        if inputs.deviceProbeFailed { return .noDevice }
        if case .failed = inputs.issue { return .failed }
        return .idle
    }
}

// MARK: - Scan

/// One machine-readable code delivered by the live camera. The candidate keeps
/// its own value type because `OpticsCapturedCode` is iOS-only in the shared
/// module; it converts to `OpticsScanItem` through `MacScanSession`.
public struct MacCapturedCode: Sendable, Equatable {
    public let payload: String
    public let symbology: String

    public init(payload: String, symbology: String) {
        self.payload = payload
        self.symbology = symbology
    }
}

public enum MacScanPageSource: String, Sendable, Equatable {
    case imported
    case camera
}

public struct MacScanPage: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let image: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let wasDownsampled: Bool
    public let source: MacScanPageSource
    /// Bounded per-page OCR text, filled by `recognizePages()`.
    public internal(set) var text: String?

    public init(
        id: UUID = UUID(),
        image: CGImage,
        pixelWidth: Int,
        pixelHeight: Int,
        wasDownsampled: Bool,
        source: MacScanPageSource,
        text: String? = nil
    ) {
        self.id = id
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.wasDownsampled = wasDownsampled
        self.source = source
        self.text = text
    }
}

/// Stable, localized-by-the-view outcomes. The core never builds user copy.
public enum MacScanNotice: Equatable, Sendable {
    case recognized(Int)
    case noResults
    case resultsTruncated
    case pageAdded(Int)
    case pagesTruncated(dropped: Int)
    case pagesComplete(Int)
    case pageRemoved
    case cleared
}
