// FloeApp — app-side archive decoder seam.
//
// The archive tool itself is native inside `FloeWorkspace` (zip, tar,
// tar.gz, tar.bz2, tar.xz, gzip, bzip2, xz and 7z read). This bridge exists
// only for the one format that needs a framework the SwiftPM module cannot
// import: RAR, decoded by the vendored signed libarchive build (CArchive).
//
// It used to route compressed tar and single-file gzip/bzip2/xz into the task
// environment's guest Python. That path is gone: those formats are produced
// and read on the host, so a device-local archive operation no longer starts a
// Linux guest, needs a pool slot, or depends on guest packages.

#if canImport(UIKit)
import Foundation
import FloeCore
import FloeExecution
import FloeTools
import FloeWorkspace

/// Formats and naming for the workspace multi-select Compress action. Pure
/// value logic (no UI, no filesystem writes beyond the injected existence
/// check) so the surface stays a thin caller of `ArchiveBrowserService`.
enum WorkspaceArchiveCompression {
    /// One selectable output format. Container formats only: a single-file
    /// gzip/bzip2/xz holds exactly one payload, so the multi-select surface
    /// does not offer them.
    struct Format: Identifiable, Hashable, Sendable {
        /// Engine format id (`ArchiveEngine.create(format:)`).
        let id: String
        /// Technical display label (not translated).
        let title: String
        let fileExtension: String

        static let zip = Format(id: "zip", title: "ZIP", fileExtension: "zip")
        static let tar = Format(id: "tar", title: "TAR", fileExtension: "tar")
        static let tarballGzip = Format(id: "tgz", title: "TAR.GZ", fileExtension: "tar.gz")
        static let tarballBzip2 = Format(id: "tbz2", title: "TAR.BZ2", fileExtension: "tar.bz2")
        static let tarballXz = Format(id: "txz", title: "TAR.XZ", fileExtension: "tar.xz")

        /// Selection order shown by the picker; zip is the default.
        static let all: [Format] = [.zip, .tar, .tarballGzip, .tarballBzip2, .tarballXz]
        static let `default` = Format.zip

        static func format(id: String) -> Format {
            all.first { $0.id == id } ?? .default
        }
    }

    /// Default archive name for a selection: a single directory keeps its
    /// name, a single file drops its own extension (`report.pdf` →
    /// `report.zip`), and a multi-selection is named `Archive`.
    static func defaultName(
        singleSourceName: String?,
        singleSourceIsDirectory: Bool,
        format: Format
    ) -> String {
        var base = "Archive"
        if let singleSourceName, !singleSourceName.isEmpty {
            if singleSourceIsDirectory {
                base = singleSourceName
            } else {
                let stem = (singleSourceName as NSString).deletingPathExtension
                base = stem.isEmpty ? singleSourceName : stem
            }
        }
        return "\(base).\(format.fileExtension)"
    }

    /// First non-conflicting variant of `name`: inserts " 2", " 3", … before
    /// the first dot of the last path component (`report.zip` →
    /// `report 2.zip`), so an existing archive is never overwritten and the
    /// caller does not have to resolve the conflict itself.
    static func uniqueName(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let path = name as NSString
        let directory = path.deletingLastPathComponent
        let component = path.lastPathComponent
        let dot = component.firstIndex(of: ".")
        let stem = dot.map { String(component[..<$0]) } ?? component
        let suffix = dot.map { String(component[$0...]) } ?? ""
        for index in 2...999 {
            let candidate = "\(stem) \(index)\(suffix)"
            let full = directory.isEmpty ? candidate : "\(directory)/\(candidate)"
            if !isTaken(full) { return full }
        }
        return name
    }
}

enum ArchiveCompressedBridge {
    /// Wiring-compatible factory. `service` is kept so the app assembly in
    /// `AppEnvironment` stays untouched while no compressed format needs the
    /// guest Python runtime any more; the resulting handler is host-native.
    static func makeHandler(service: LocalPythonService) -> ArchiveCompressedHandler {
        _ = service
        return makeHandler()
    }

    static func makeHandler() -> ArchiveCompressedHandler {
        { request in
            switch request.format {
            case "rar":
                return try await RARArchiveService.run(request)
            default:
                // The native engine handles these before any handler is
                // consulted; reaching here means the caller bypassed it.
                throw FloeError.invalidConfiguration(
                    "\(request.format) archives are handled natively by the workspace archive tool"
                )
            }
        }
    }
}

/// Environment 9p shares exposed to the bridge. A guest path outside the
/// declared shares maps to nil and is refused by the bridge.
struct LinuxGuestArchivePathMapping: HostArchivePathMapping {
    let pathMap: LinuxGuestPathMap

    init(pathMap: LinuxGuestPathMap) {
        self.pathMap = pathMap
    }

    func hostURL(forGuestPath path: String) -> URL? {
        pathMap.hostPath(forGuestPath: path)
    }

    func guestPath(forHostPath path: String) -> String? {
        pathMap.guestPath(forHostPath: path)
    }
}

enum ArchiveHostBridgeFactory {
    /// All actions the host archive engine can serve. The guest only uses what
    /// the HELLO advertisement contained.
    static let defaultCapabilities: Set<HostArchiveCapability> = Set(HostArchiveCapability.allCases)

    static func make(
        environmentID: String,
        token: String,
        pathMap: LinuxGuestPathMap,
        capabilities: Set<HostArchiveCapability> = ArchiveHostBridgeFactory.defaultCapabilities
    ) -> HostArchiveBridge {
        HostArchiveBridge(
            environmentID: environmentID,
            token: token,
            capabilities: capabilities,
            mapping: LinuxGuestArchivePathMapping(pathMap: pathMap)
        )
    }

    /// The HELLO argument that advertises the bridge (empty set advertises
    /// nothing and keeps the guest command disabled).
    static func helloCapabilityArgument(
        capabilities: Set<HostArchiveCapability> = ArchiveHostBridgeFactory.defaultCapabilities
    ) -> String {
        "archive=" + HostArchiveCapability.wireValue(capabilities)
    }

    /// Builds the guest-service handler for one environment's declared 9p
    /// shares. The shell the app installs with
    /// `TinyEMULinuxCommandService.installHostRequestHandlerFactory`.
    ///
    /// One bridge is built per guest command token: the runner's control
    /// payload carries the token of the live command it belongs to, and the
    /// bridge refuses a payload whose token does not match — so a request can
    /// only ever act for the connection that sent it. The path mapping is the
    /// environment's own `LinuxGuestPathMap`; every guest path outside those
    /// shares is refused before any filesystem access. An empty capability
    /// set advertises nothing (the guest fails the command closed) instead of
    /// advertising a bridge that would refuse every action.
    static func makeHandler(
        environmentID: String,
        pathMap: LinuxGuestPathMap,
        capabilities: Set<HostArchiveCapability> = ArchiveHostBridgeFactory.defaultCapabilities
    ) -> LinuxGuestHostRequestHandler {
        let argument = capabilities.isEmpty ? "" : helloCapabilityArgument(capabilities: capabilities)
        return LinuxGuestHostRequestHandler(helloArgument: argument) { request, cancellation in
            let bridge = make(
                environmentID: environmentID,
                token: request.token,
                pathMap: pathMap,
                capabilities: capabilities
            )
            return await bridge.handle(request.payload, cancellation: cancellation)
        }
    }
}
#endif
