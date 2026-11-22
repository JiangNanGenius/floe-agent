// SPDX-License-Identifier: MPL-2.0

import FloePersistence
import Foundation

/// Resolves the active workbench database when settings or a task needs it.
struct MacWorkbenchDatabaseSkills: MacWorkbenchSkillStore {
    let resolveStore: @Sendable () async throws -> SQLiteSkillStore

    func all() async throws -> [PersistedSkill] {
        try await resolveStore().all()
    }

    func skill(id: String) async throws -> PersistedSkill? {
        try await resolveStore().skill(id: id)
    }

    func save(_ skill: PersistedSkill, grantCapabilities: [String],
              officialPublication: OfficialSkillPublicationRecord?) async throws {
        try await resolveStore().save(skill, grantCapabilities: grantCapabilities,
                                      officialPublication: officialPublication)
    }

    func setEnabled(_ enabled: Bool, id: String, expectedDigest: String?) async throws {
        try await resolveStore().setEnabled(enabled, id: id, expectedDigest: expectedDigest)
    }

    func remove(id: String, expectedDigest: String?) async throws {
        try await resolveStore().remove(id: id, expectedDigest: expectedDigest)
    }

    func wasExplicitlyRemoved(id: String) async throws -> Bool {
        try await resolveStore().wasExplicitlyRemoved(id: id)
    }
}
