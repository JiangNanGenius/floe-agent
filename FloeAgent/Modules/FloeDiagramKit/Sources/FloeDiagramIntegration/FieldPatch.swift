// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

public enum DiagramFieldPatch {
    /// Applies only fields edited in a local form; a simultaneous edit to that same field requires review.
    public static func apply<T: Codable>(base: T, draft: T, current: T) throws -> T {
        func object(_ value: T) throws -> [String: Any] { try JSONSerialization.jsonObject(with: DiagramCodec.encode(value)) as! [String: Any] }
        func bytes(_ value: Any?) throws -> Data? { guard let value else { return nil }; return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.fragmentsAllowed]) }
        let before = try object(base), changed = try object(draft); var latest = try object(current)
        for key in Set(before.keys).union(changed.keys) {
            let a = try bytes(before[key]), b = try bytes(changed[key])
            guard a != b else { continue }
            let c = try bytes(latest[key])
            guard c == a || c == b else { throw DiagramError.invalid("The \(key) field changed while this draft was open. Your draft is retained.") }
            latest[key] = changed[key]
        }
        return try DiagramCodec.decode(T.self, from: JSONSerialization.data(withJSONObject: latest, options: [.sortedKeys]))
    }
}
