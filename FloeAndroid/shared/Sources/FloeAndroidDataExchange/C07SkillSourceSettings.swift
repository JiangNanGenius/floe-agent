// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeSkills

/// Narrow exception to the safe-preferences allowlist. Source intent contains
/// no credential or tool grant; validate the original typed binding rather
/// than allowing arbitrary settings under a broad skills prefix.
public enum C07SkillSourceSettings {
    public static let prefix = "skills.update_source."

    /// Skill ids use the original lowercase identifier grammar, unlike
    /// UUID-backed conversations. A restored reference stays manageable by
    /// the normal skill service and can own its remapped source record.
    public static func freshRestoredSkillID(_ uuid: UUID = UUID()) -> String {
        "restored-" + uuid.uuidString.lowercased()
    }

    public static func skillID(for key: String) -> String? {
        guard key.hasPrefix(prefix), key.utf8.count <= 512 else { return nil }
        let id = String(key.dropFirst(prefix.count))
        guard (try? SkillIdentifier.validate(id)) != nil else { return nil }
        return id
    }

    public static func validatedValue(_ json: String) -> String? {
        guard json.utf8.count <= 16_384, let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: ["source", "installedCommit", "installedContentDigest"]),
              let source = object["source"] as? [String: Any],
              Set(source.keys) == Set(["owner", "repository", "ref", "path"]),
              let binding = try? JSONDecoder().decode(SkillGitHubBinding.self, from: data) else { return nil }
        return encode(binding)
    }

    /// Skills restore as disabled reference rows under new identities.
    /// Keep the user's intent, never transfer proof of an installed package.
    /// An absent/ambiguous mapping is counted and omitted, not attached to
    /// an existing skill just because its old id happens to match.
    public static func remappedForRestore(
        _ values: [String: String], resolveSkillID: (String) -> String?
    ) -> (values: [String: String], omitted: Int) {
        var result = values.filter { !$0.key.hasPrefix(prefix) }
        var omitted = 0
        var ambiguousTargets = Set<String>()
        for key in values.keys.sorted() where key.hasPrefix(prefix) {
            guard let oldID = skillID(for: key), let newID = resolveSkillID(oldID),
                  skillID(for: prefix + newID) == newID,
                  let json = values[key].flatMap(validatedValue),
                  let binding = try? JSONDecoder().decode(SkillGitHubBinding.self, from: Data(json.utf8)),
                  let intent = try? SkillGitHubBinding(source: binding.source,
                                                       installedCommit: nil, installedContentDigest: nil),
                  let encoded = encode(intent) else {
                omitted += 1
                continue
            }
            let target = prefix + newID
            guard !ambiguousTargets.contains(target) else { omitted += 1; continue }
            if result.removeValue(forKey: target) != nil {
                ambiguousTargets.insert(target)
                omitted += 2
                continue
            }
            result[target] = encoded
        }
        return (result, omitted)
    }

    private static func encode(_ binding: SkillGitHubBinding) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(binding)).map { String(decoding: $0, as: UTF8.self) }
    }
}
