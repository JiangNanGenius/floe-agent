import Foundation

/// Which Apple test runtime image supplies `_XCTestMain`.
public enum BridgeDDIRuntime: String, Codable, Sendable {
    case xctest
    case xctestCore
}

/// One concrete executable candidate for a DDI layout.
public struct BridgeDDIRuntimeCandidate: Equatable, Sendable {
    public var layout: BridgeDDILayout
    public var runtime: BridgeDDIRuntime
    public var path: String

    public init(layout: BridgeDDILayout, runtime: BridgeDDIRuntime, path: String) {
        self.layout = layout
        self.runtime = runtime
        self.path = path
    }
}

/// Filesystem classification for one candidate path.
public enum BridgeDDICandidateState: String, Equatable, Sendable {
    case readable
    case unreadable
    case directory
    case missing
}

public struct BridgeDDICandidateInspection: Equatable, Sendable {
    public var path: String
    public var state: BridgeDDICandidateState
    public var bytes: UInt64

    public init(path: String, state: BridgeDDICandidateState, bytes: UInt64 = 0) {
        self.path = path
        self.state = state
        self.bytes = bytes
    }
}

/// Read-only DDI observation. A readable framework directory proves nothing;
/// only a readable executable image makes a runtime candidate usable. This is
/// still not engine readiness: the coordinator requires the real matching-PID
/// test entry before it reports ready.
public enum BridgeDDIProbe {
    public struct Status: Sendable, Equatable {
        public var mounted: Bool
        public var layout: BridgeDDILayout?
        public var runtime: BridgeDDIRuntime?
        public var developerDirectoryExists: Bool
        public var xctestPath: String?
        public var xctestReadable: Bool
        public var xctestBytes: UInt64
        public var xctestCorePath: String?
        public var xctestCoreReadable: Bool
        public var checkedAt: String

        public var summary: String {
            if mounted { return "mounted:\(layout?.rawValue ?? "unknown")" }
            return developerDirectoryExists ? "not-mounted" : "developer-mode-unavailable"
        }
    }

    /// XCTest images are preferred in every layout so the test bundle's
    /// `@rpath/XCTest.framework/XCTest` load reuses the image the host loaded.
    /// XCTestCore is only the explicit fallback the bootstrap shim attempts for
    /// cryptex and system layouts; the legacy layout has no core candidate.
    public static var runtimeCandidates: [BridgeDDIRuntimeCandidate] {
        let layouts = BridgeDDILayout.allCases
        var candidates = layouts.map {
            BridgeDDIRuntimeCandidate(layout: $0, runtime: .xctest, path: $0.executablePath)
        }
        candidates += [BridgeDDILayout.cryptex, .system].map {
            BridgeDDIRuntimeCandidate(layout: $0, runtime: .xctestCore, path: $0.coreExecutablePath)
        }
        return candidates
    }

    /// Classifies one actual filesystem entry. Size is reported as diagnostic
    /// metadata only; it is never used as a readiness heuristic.
    public static func inspect(path: String,
                               fileManager: FileManager = .default) -> BridgeDDICandidateInspection {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return BridgeDDICandidateInspection(path: path, state: .missing)
        }
        guard !isDirectory.boolValue else {
            return BridgeDDICandidateInspection(path: path, state: .directory)
        }
        guard access(path, R_OK) == 0 else {
            return BridgeDDICandidateInspection(path: path, state: .unreadable)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        return BridgeDDICandidateInspection(path: path, state: .readable, bytes: size)
    }

    public static func status(
        candidates: [BridgeDDIRuntimeCandidate] = BridgeDDIProbe.runtimeCandidates,
        fileManager: FileManager = .default
    ) -> Status {
        var selected: (candidate: BridgeDDIRuntimeCandidate, inspection: BridgeDDICandidateInspection)?
        for candidate in candidates {
            let inspection = inspect(path: candidate.path, fileManager: fileManager)
            if inspection.state == .readable {
                selected = (candidate, inspection)
                break
            }
        }

        let developerDirectoryExists = BridgeDDILayout.allCases.contains {
            fileManager.fileExists(atPath: $0.developerDirectory)
        }
        let corePath = selected?.candidate.layout.coreExecutablePath
        let coreReadable = corePath.map {
            inspect(path: $0, fileManager: fileManager).state == .readable
        } ?? false

        return Status(
            mounted: selected != nil,
            layout: selected?.candidate.layout,
            runtime: selected?.candidate.runtime,
            developerDirectoryExists: developerDirectoryExists,
            xctestPath: selected?.inspection.path,
            xctestReadable: selected != nil,
            xctestBytes: selected?.inspection.bytes ?? 0,
            xctestCorePath: corePath,
            xctestCoreReadable: coreReadable,
            checkedAt: BridgeClock.timestamp()
        )
    }

    public static func dictionary(_ status: Status) -> [String: Any] {
        var value: [String: Any] = [
            "mounted": status.mounted,
            "developerDirectoryExists": status.developerDirectoryExists,
            "xctestReadable": status.xctestReadable,
            "xctestBytes": status.xctestBytes,
            "xctestCoreReadable": status.xctestCoreReadable,
            "checkedAt": status.checkedAt,
            "summary": status.summary,
        ]
        value["layout"] = status.layout?.rawValue
        value["runtime"] = status.runtime?.rawValue
        value["xctestPath"] = status.xctestPath
        value["xctestCorePath"] = status.xctestCorePath
        return value
    }
}
