// SPDX-License-Identifier: MPL-2.0
//
// FloeExecution — legacy native Node install recovery.
//
// Phase 2 (TinyEMU migration): the nodejs-mobile runtime and the host-side
// staged npm installer left the app. Node package installs run the
// environment's guest npm/pnpm through `LinuxGuestLanguagePackages` (which
// keeps the same staged-generation transaction inside the guest layer).
//
// What remains here is pure file recovery for environments that still carry
// an interrupted native-era transaction journal: the next package read/write
// rolls the half-committed generation back without a Node runtime. Old
// installs are never erased by recovery; an unrecoverable state keeps every
// file and reports the reason.

import Foundation
import FloeCore
import FloeTools

public enum LegacyNodeInstallRecovery {
    private struct NodeJournal: Codable { var phase: String; let hadOriginal: Bool }

    private static func contained(_ relative: String, in root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var candidate = base
        for component in relative.split(separator: "/") {
            candidate = candidate.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
            guard candidate.path.hasPrefix(base.path + "/") else { throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.the_dependency_path_is_outside_the")) }
        }
        return candidate
    }

    private static func boundedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.environment_language_package_service.the_package_manifest_is_missing_or"))
        }
        return try Data(contentsOf: url)
    }

    /// A previous native-era process may have died between the two renames.
    /// Restore the old generation. No-op when no transaction exists.
    public static func recover(_ environment: ToolEnvironment) throws {
        let fm = FileManager.default
        let transaction = try contained("var/floe-node-transaction", in: environment.writableLayerURL)
        guard fm.fileExists(atPath: transaction.path) else { return }
        let journalURL = try contained("journal.json", in: transaction)
        guard fm.fileExists(atPath: journalURL.path) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.legacy_node_install_recovery.the_npm_staging_directory_is_missing"))
        }
        let journal = try JSONDecoder().decode(NodeJournal.self, from: boundedData(journalURL))
        let backup = try contained("backup", in: transaction)
        let destination = try contained("usr/lib/node_modules", in: environment.writableLayerURL)
        guard ["prepared", "committing", "committed"].contains(journal.phase) else { throw FloeError.validationFailed(FloeL10n.l("execution.legacy_node_install_recovery.the_npm_restore_record_is_invalid")) }
        if journal.phase == "committing" {
            if fm.fileExists(atPath: backup.path) {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: backup, to: destination)
            } else if !journal.hadOriginal, fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        }
        try fm.removeItem(at: transaction)
    }
}
