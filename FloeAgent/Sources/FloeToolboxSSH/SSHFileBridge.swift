import Foundation
import Citadel
import FloeSSH
import FloeToolboxCore
import FloeToolboxRemoteFiles
import FloeToolboxFileTransports

public enum ToolboxSSHFileBridge {
    public static func sftp(handle: SSHSessionHandle,lease: SessionLease,machine: MachineReference,root: RemoteFilePath,
                            authorize: @escaping RemoteFileAuthorizer) async throws -> RemoteFileSession {
        guard try await authorize(RemoteFileAuthorizationRequest(lease:lease,machine:machine,effect:.list,source:root)) else { throw RemoteFileError.denied }
        try Task.checkCancellation()
        let channel = try await SSHRemoteFileByteChannel.open { initialize in try await handle.openToolboxFileChannel(.sftp,initialize:initialize) }
        do { let backend = try await SFTPRemoteFileBackend.connect(channel:channel)
            return try RemoteFileSession(lease:lease,machine:machine,root:root,backend:backend,authorize:authorize)
        } catch { await channel.close(); throw error }
    }
    public static func scp(handle: SSHSessionHandle,lease: SessionLease,machine: MachineReference,root: RemoteFilePath,
                           authorize: @escaping RemoteFileAuthorizer) throws -> SCPTransferClient {
        try SCPTransferClient(lease:lease,machine:machine,root:root,factory:{ expected,target,command in
            guard expected == lease,target == machine,command.executable == "scp",command.arguments.count == 3,
                  command.arguments[1] == "--",["-t","-f"].contains(command.arguments[0]),
                  try RemoteFilePath(command.arguments[2]).isWithin(root) else { throw RemoteFileError.denied }
            let request: FloeSSHFileChannelRequest = command.arguments[0] == "-t" ? .scpUpload(path:command.arguments[2]) : .scpDownload(path:command.arguments[2])
            return try await SSHRemoteFileByteChannel.open { initialize in try await handle.openToolboxFileChannel(request,initialize:initialize) }
        },authorize:authorize)
    }
}
