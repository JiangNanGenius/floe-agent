// SPDX-License-Identifier: MPL-2.0

import Foundation

@main
private enum LegacyBridgeModeTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModePreferenceStore(rootURL: root)

        let first = store.resolve(commandLineMode: nil, environment: [:])
        precondition(first.mode == .agent && first.isFirstRun && first.source == .firstRunDefault)
        let inherited = store.resolve(commandLineMode: nil, environment: [:], inheritedBridgeSetup: true)
        precondition(inherited.mode == .bridge && !inherited.isFirstRun && inherited.source == .inheritedBridge)
        precondition(store.load() == nil)

        let explicit = store.resolve(commandLineMode: .agent, environment: [:], inheritedBridgeSetup: true)
        precondition(explicit.mode == .agent && explicit.source == .commandLine)
        let environment = store.resolve(commandLineMode: nil,
            environment: [ModePreferenceStore.environmentModeKey: "agent"], inheritedBridgeSetup: true)
        precondition(environment.mode == .agent && environment.source == .environment)

        try store.save(.agent)
        let chosen = store.resolve(commandLineMode: nil, environment: [:], inheritedBridgeSetup: true)
        precondition(chosen.mode == .agent && !chosen.isFirstRun && chosen.source == .savedPreference)
        print("Fresh, inherited, explicit and saved mode cases passed.")
    }
}
