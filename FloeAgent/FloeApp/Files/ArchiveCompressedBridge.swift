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
}
#endif
