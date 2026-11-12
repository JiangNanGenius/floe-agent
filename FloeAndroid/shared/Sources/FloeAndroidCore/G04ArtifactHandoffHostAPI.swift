// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Typed request seam for the read-only artifact handoff.
///
/// The transport is the EXISTING `ExternalEditHostMailbox` (BridgeV29): one
/// Android OS work queue, the same settled-ticket/canCommit/settle lifetime
/// and the same native-root epoch fence as `workspace.externalEdit`. This
/// type only builds the closed request dictionary; it carries no URI, path
/// authority, grant or model-selected task/workspace identity.
enum G04ArtifactHandoffHostAPI {
    static let lane = "handoff"

    static func request(
        action: String,
        source: String,
        path: String?,
        outputID: String?,
        taskID: UUID,
        workspaceID: UUID,
        runID: UUID,
        callID: String,
        sessionID: String?,
        targetPackage: String?,
        targetComponent: String?
    ) throws -> Data {
        var object: [String: Any] = [
            "lane": lane,
            "action": action,
            "source": source,
            "taskID": taskID.uuidString.lowercased(),
            "workspaceID": workspaceID.uuidString.lowercased(),
            "runID": runID.uuidString.lowercased(),
            "callID": callID,
        ]
        if let path { object["path"] = path }
        if let outputID { object["outputID"] = outputID.lowercased() }
        if let sessionID { object["sessionID"] = sessionID.lowercased() }
        if let targetPackage { object["targetPackage"] = targetPackage }
        if let targetComponent { object["targetComponent"] = targetComponent }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
