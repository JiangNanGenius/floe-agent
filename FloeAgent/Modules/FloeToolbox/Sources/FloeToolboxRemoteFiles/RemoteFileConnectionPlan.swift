import Foundation
import FloeToolboxCore

public enum FTPSTLSMode: String, Codable, Sendable { case explicit, implicit }
/// A plan for the host's existing credential/mount/environment owners; this is not another saved-host registry.
public struct RemoteFileConnectionPlan: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case environment(MachineReference)
        case workspaceMount(UUID)
        case temporary
    }
    public let source: Source
    public let transport: RemoteFileProtocol
    public let host: String
    public let port: UInt16
    public let root: RemoteFilePath
    public let username: String
    public let credentialReference: UUID?
    public let ftpsMode: FTPSTLSMode
    public init(source: Source, transport: RemoteFileProtocol, host: String, port: UInt16? = nil,
                root: RemoteFilePath, username: String = "", credentialReference: UUID? = nil,
                ftpsMode: FTPSTLSMode = .explicit) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where:{ "@/\\?#".contains($0) }),
              !host.unicodeScalars.contains(where:{ CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              username.utf8.count <= 1024, !username.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw RemoteFileError.invalidPath }
        let chosen = port ?? transport.defaultPort(ftpsMode:ftpsMode)
        guard chosen > 0 else { throw RemoteFileError.invalidPath }
        self.source = source; self.transport = transport; self.host = host; self.port = chosen
        self.root = try root.validated(); self.username = username; self.credentialReference = credentialReference; self.ftpsMode = ftpsMode
    }
}
extension RemoteFileProtocol {
    public func defaultPort(ftpsMode: FTPSTLSMode = .explicit) -> UInt16 {
        switch self {
        case .sftp,.scp: 22
        case .ftp: 21
        case .ftps: ftpsMode == .explicit ? 21 : 990
        case .webDAV: 443
        case .smb: 445
        }
    }
}

/// Structured input to the existing resolved-environment exec.shell/jobs adapter.
/// No host shell is invoked by this module. The host quotes each argument when building its approved script.
public struct RemoteSyncPlan: Sendable, Equatable {
    public let environmentID: String
    public let arguments: [String]
    public let dryRun: Bool
    public init(environmentID: String, source: String, destination: String, dryRun: Bool = true) throws {
        guard !environmentID.isEmpty, environmentID.utf8.count <= 256,
              [source,destination].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32768 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") }) else { throw RemoteFileError.invalidPath }
        self.environmentID = environmentID; self.dryRun = dryRun
        self.arguments = ["--archive","--partial","--protect-args"]+(dryRun ? ["--dry-run","--itemize-changes"] : [])+["--",source,destination]
    }
}
