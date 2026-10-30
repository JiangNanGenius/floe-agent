// SPDX-License-Identifier: MPL-2.0
//
// FloeAndroidCore — mailbox implementation of the bounded READ-ONLY live guest
// file snapshot transport (G07.3A). It rides the SAME `LinuxShellMailbox` and
// the SAME trusted host pump as shell.start/poll/input: no second socket, no
// second permission store, no host fallback.
//
// The runtime re-proves session/project/environment/generation identity and
// applies its own no-follow containment and byte/entry bounds. This layer only
// validates the closed reply vocabulary; a malformed reply is never read as a
// complete snapshot.

import Foundation
import FloeAndroidShellTools

extension MailboxLinuxShellTransport: LinuxLiveFilesTransport {
    public func filesTree(_ request: LinuxLiveFilesRequest,
                          timeoutMillis: Int = 8_000) async throws -> LinuxLiveTreeSnapshot {
        let reply = try await submitFiles("workspace.files.tree", request, timeoutMillis: timeoutMillis)
        guard let rows = reply["entries"] as? [[String: Any]] else {
            throw LinuxLiveFilesError.replyMalformed
        }
        let parsed = rows.compactMap { row -> LinuxLiveFileEntry? in
            guard let path = row["path"] as? String, let kind = row["kind"] as? String else { return nil }
            return LinuxLiveFileEntry(
                path: path, kind: kind,
                size: (row["size"] as? NSNumber)?.int64Value ?? 0,
                mtimeMillis: (row["mtimeMillis"] as? NSNumber)?.int64Value ?? 0)
        }
        guard parsed.count == rows.count,
              let generation = reply["generation"] as? String, !generation.isEmpty,
              let listingToken = reply["listingToken"] as? String,
              listingToken.count == 64, listingToken.allSatisfy({ $0.isHexDigit }) else {
            throw LinuxLiveFilesError.replyMalformed
        }
        return LinuxLiveTreeSnapshot(entries: parsed,
                                     truncated: reply["truncated"] as? Bool ?? false,
                                     generation: generation,
                                     listingToken: listingToken)
    }

    public func filesRead(_ request: LinuxLiveFilesRequest,
                          timeoutMillis: Int = 8_000) async throws -> LinuxLiveFilePage {
        let reply = try await submitFiles("workspace.files.read", request, timeoutMillis: timeoutMillis)
        guard let path = reply["path"] as? String,
              let encoded = reply["contentBase64"] as? String,
              let content = Data(base64Encoded: encoded),
              let digest = reply["digest"] as? String, digest.count == 64,
              let generation = reply["generation"] as? String, !generation.isEmpty,
              let consistencyToken = reply["consistencyToken"] as? String,
              consistencyToken.count == 64, consistencyToken.allSatisfy({ $0.isHexDigit }) else {
            throw LinuxLiveFilesError.replyMalformed
        }
        return LinuxLiveFilePage(
            path: path,
            offset: (reply["offset"] as? NSNumber)?.int64Value ?? -1,
            bytes: (reply["bytes"] as? NSNumber)?.intValue ?? -1,
            size: (reply["size"] as? NSNumber)?.int64Value ?? -1,
            mtimeMillis: (reply["mtimeMillis"] as? NSNumber)?.int64Value ?? -1,
            digest: digest,
            content: content,
            truncated: reply["truncated"] as? Bool ?? true,
            generation: generation,
            consistencyToken: consistencyToken)
    }

    private func submitFiles(_ operation: String, _ request: LinuxLiveFilesRequest,
                             timeoutMillis: Int) async throws -> [String: Any] {
        guard (1...LinuxLiveFilesRequest.maximumTreeEntries).contains(request.maxEntries),
              (0...LinuxLiveFilesRequest.maximumDepth).contains(request.maxDepth),
              (1...LinuxLiveFilesRequest.maximumReadBytes).contains(request.maxBytes),
              request.offset >= 0,
              request.relativePath.utf8.count <= 1_024,
              !request.sessionID.isEmpty, !request.workspaceKey.isEmpty,
              !request.environmentID.isEmpty, !request.generation.isEmpty else {
            throw LinuxLiveFilesError.refused("invalidBounds")
        }
        let payload: [String: Any] = [
            "sessionID": request.sessionID,
            "workspaceKey": request.workspaceKey,
            "environmentID": request.environmentID,
            "generation": request.generation,
            "relativePath": request.relativePath,
            "maxEntries": request.maxEntries,
            "maxDepth": request.maxDepth,
            "offset": request.offset,
            "maxBytes": request.maxBytes,
        ]
        let replyData: Data
        do {
            replyData = try await mailbox.submit(operation: operation,
                                                 payload: try Self.jsonData(payload),
                                                 timeoutMillis: max(1_000, timeoutMillis))
        } catch let error as LinuxShellTransportError {
            switch error {
            case .notBound: throw LinuxLiveFilesError.notBound
            case .waitBudgetExpired: throw LinuxLiveFilesError.awaitBudgetExpired
            case .payloadTooLarge: throw LinuxLiveFilesError.refused("payloadTooLarge")
            case .saturated: throw LinuxLiveFilesError.refused("saturated")
            case .hostFenced: throw LinuxLiveFilesError.refused("hostFenced")
            case .replyMalformed: throw LinuxLiveFilesError.replyMalformed
            case .remoteFailed(let code): throw LinuxLiveFilesError.transport(code)
            case .remoteFailedWithRestore(let code, _): throw LinuxLiveFilesError.transport(code)
            }
        } catch {
            throw LinuxLiveFilesError.transport(String(describing: type(of: error)))
        }
        let object = try Self.jsonObject(replyData)
        switch object["state"] as? String {
        case "ok":
            return object
        case "retry":
            throw LinuxLiveFilesError.retry((object["code"] as? String) ?? "changedDuringRead")
        case "refused":
            throw LinuxLiveFilesError.refused((object["code"] as? String) ?? "refused")
        default:
            throw LinuxLiveFilesError.replyMalformed
        }
    }
}
