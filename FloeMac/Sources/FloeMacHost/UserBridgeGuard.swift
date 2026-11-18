// Floe Mac M00 — read-only identity of the user's standalone Bridge data.
//
// SPDX-License-Identifier: MPL-2.0
//
// This file only locates and snapshots the real data root. It never writes it.
// Moving it out of HostProbes lets controller tests link the real guard without
// importing the CLI probe surface.

import Foundation

struct UserBridgeSnapshot: Equatable {
    var exists: Bool
    var rootModification: TimeInterval?
    var stateModification: TimeInterval?
    var stateEntryCount: Int
}

enum UserBridgeGuard {
    static var realHomeDirectory: URL {
        if let password = getpwuid(getuid()) {
            let path = String(cString: password.pointee.pw_dir)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var userBridgeRoot: URL {
        realHomeDirectory.appendingPathComponent("Library/Application Support/Floe Bridge", isDirectory: true)
    }

    static func capture() -> UserBridgeSnapshot {
        let fileManager = FileManager.default
        let root = userBridgeRoot
        guard fileManager.fileExists(atPath: root.path) else {
            return UserBridgeSnapshot(exists: false, rootModification: nil, stateModification: nil, stateEntryCount: 0)
        }
        let rootAttributes = try? fileManager.attributesOfItem(atPath: root.path)
        let rootModification = (rootAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        let state = root.appendingPathComponent("State", isDirectory: true)
        let stateAttributes = try? fileManager.attributesOfItem(atPath: state.path)
        let stateModification = (stateAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        let stateEntryCount = (try? fileManager.contentsOfDirectory(atPath: state.path).count) ?? -1
        return UserBridgeSnapshot(
            exists: true,
            rootModification: rootModification,
            stateModification: stateModification,
            stateEntryCount: stateEntryCount
        )
    }
}
