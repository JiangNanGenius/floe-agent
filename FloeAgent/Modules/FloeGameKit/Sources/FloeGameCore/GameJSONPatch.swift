// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum GameJSONPathComponent: Sendable { case key(String), index(Int) }

/// Structural edits preserve unrelated/unknown values. No engine schema is invented.
public enum GameJSONPatch {
    public static func replacing(_ source: Data, at path: [GameJSONPathComponent], with value: Data) throws -> Data {
        guard source.count <= 16 * 1_024 * 1_024, value.count <= 1_024 * 1_024,
              !path.isEmpty, path.count <= 64 else { throw GameProjectError.invalidEdit }
        let original = try JSONSerialization.jsonObject(with: source, options: [.fragmentsAllowed])
        let replacement = try JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
        func apply(_ object: Any, _ index: Int) throws -> Any {
            guard index < path.count else { return replacement }
            switch path[index] {
            case .key(let key):
                guard var dictionary = object as? [String: Any], let child = dictionary[key] else { throw GameProjectError.invalidEdit }
                dictionary[key] = try apply(child, index + 1)
                return dictionary
            case .index(let position):
                guard var array = object as? [Any], array.indices.contains(position) else { throw GameProjectError.invalidEdit }
                array[position] = try apply(array[position], index + 1)
                return array
            }
        }
        return try JSONSerialization.data(withJSONObject: apply(original, 0), options: [.sortedKeys, .fragmentsAllowed])
    }
}
