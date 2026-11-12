// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Lossless spelling for two complete schemas newly paged into the captured
/// Ark request. Some routed function-schema dialects understand anyOf but
/// not oneOf. Never replace an overlapping union or remove a constraint.
enum ArkToolSchemaProjection {
    static func parameters(_ raw: String, toolName: String) -> String {
        guard ["document.presentation.createInline", "font.install"].contains(toolName),
              let root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return raw }
        var changed = false
        let projected = schema(root, changed: &changed)
        guard changed,
              let data = try? JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys]) else { return raw }
        return String(decoding: data, as: UTF8.self)
    }

    private static func schema(_ input: [String: Any], changed: inout Bool) -> [String: Any] {
        var result = input
        // Traverse schema positions, never enum/default/example values or
        // the property-name map itself (a property can be named "oneOf").
        for key in ["properties", "$defs", "definitions", "patternProperties", "dependentSchemas"] {
            guard var children = result[key] as? [String: Any] else { continue }
            for (name, value) in children {
                if let child = value as? [String: Any] { children[name] = schema(child, changed: &changed) }
            }
            result[key] = children
        }
        for key in ["items", "additionalProperties", "unevaluatedProperties", "contains", "not", "if", "then", "else", "propertyNames"] {
            if let child = result[key] as? [String: Any] { result[key] = schema(child, changed: &changed) }
        }
        for key in ["anyOf", "oneOf", "allOf", "prefixItems"] {
            if let children = result[key] as? [[String: Any]] {
                result[key] = children.map { schema($0, changed: &changed) }
            }
        }
        guard result["anyOf"] == nil, let branches = result["oneOf"] as? [[String: Any]], branches.count > 1 else { return result }
        if Set(result.keys).isSubset(of: ["oneOf", "description"]), disjointTags(branches) {
            result["oneOf"] = nil
            result["anyOf"] = branches
            changed = true
            return result
        }
        // {url?,path?,oneOf:[required url,required path]} means exactly one
        // source. Closed single-source branches retain that XOR: empty,
        // both sources, unknown fields and wrong values remain invalid.
        let permitted: Set<String> = ["type", "properties", "additionalProperties", "oneOf", "description"]
        guard Set(result.keys).isSubset(of: permitted), result["type"] as? String == "object",
              result["additionalProperties"] as? Bool == false,
              let properties = result["properties"] as? [String: Any], properties.count == branches.count else { return result }
        var names = Set<String>()
        var alternatives: [[String: Any]] = []
        for branch in branches {
            guard Set(branch.keys) == ["required"], let required = branch["required"] as? [String],
                  required.count == 1, let name = required.first, let property = properties[name],
                  names.insert(name).inserted else { return result }
            alternatives.append(["type": "object", "properties": [name: property],
                "required": [name], "additionalProperties": false])
        }
        guard names == Set(properties.keys) else { return result }
        result["oneOf"] = nil
        result["properties"] = nil
        result["additionalProperties"] = nil
        result["anyOf"] = alternatives
        changed = true
        return result
    }

    private static func disjointTags(_ branches: [[String: Any]]) -> Bool {
        guard let first = branches.first, let required = first["required"] as? [String] else { return false }
        for key in required {
            var seen = Set<String>()
            var valid = true
            for branch in branches {
                guard branch["type"] as? String == "object",
                      (branch["required"] as? [String])?.contains(key) == true,
                      let properties = branch["properties"] as? [String: Any],
                      let tag = properties[key] as? [String: Any], tag["type"] as? String == "string",
                      let values = tag["enum"] as? [String], !values.isEmpty,
                      seen.isDisjoint(with: values) else { valid = false; break }
                seen.formUnion(values)
            }
            if valid { return true }
        }
        return false
    }
}
