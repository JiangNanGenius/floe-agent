// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

enum CocosSceneJSONError: Error, Equatable, Sendable {
    case invalid(String)
}

/// Strict, byte-preserving patch for a Cocos Creator 3.8 serialized scene.
/// The top-level array, the cc.Scene object and every existing field/component
/// stay byte-identical; only one child id and two new array entries are
/// inserted. The result is re-parsed and compared before it is returned.
enum CocosSceneJSON {
    private static let base64 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    struct PatchResult: Sendable {
        let data: Data
        let alreadyInstalled: Bool
        let nodeIndex: Int?
        let componentIndex: Int?
    }

    static func compressedUUID(_ uuid: String, minimumHead: Bool = false) throws -> String {
        let hex = uuid.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else {
            throw CocosSceneJSONError.invalid("uuid")
        }
        let bytes = Array(hex.utf8)
        let head = minimumHead ? 2 : 5
        var result = String(decoding: bytes[0..<head], as: UTF8.self)
        var index = head
        while index < 32 {
            let group = String(decoding: bytes[index..<(index + 3)], as: UTF8.self)
            guard let value = Int(group, radix: 16) else {
                throw CocosSceneJSONError.invalid("uuid group")
            }
            result.append(Character(UnicodeScalar(base64[value >> 6])))
            result.append(Character(UnicodeScalar(base64[value & 0x3F])))
            index += 3
        }
        return result
    }

    /// Deterministic Cocos node/component id from a stable seed. The 22-character
    /// form matches Creator's compressed UUIDs (two hex head characters).
    static func objectID(seed: String) throws -> String {
        let digest = GameDigest.sha256(Data(seed.utf8))
        return try compressedUUID(uuidFromHex(String(digest.prefix(32))), minimumHead: true)
    }

    static func uuidFromHex(_ hex: String) -> String {
        guard hex.count == 32 else { return hex }
        let value = Array(hex.utf8)
        return String(decoding: value[0..<8], as: UTF8.self) + "-" +
            String(decoding: value[8..<12], as: UTF8.self) + "-" +
            String(decoding: value[12..<16], as: UTF8.self) + "-" +
            String(decoding: value[16..<20], as: UTF8.self) + "-" +
            String(decoding: value[20..<32], as: UTF8.self)
    }

    static func stableScriptUUID(projectID: UUID, path: GameRelativePath, templateSHA256: String) -> String {
        let digest = GameDigest.sha256(Data("\(projectID.uuidString)|\(path.value)|\(templateSHA256)".utf8))
        var bytes = Array(digest.prefix(32).utf8)
        // RFC 4122 version 5 / variant bits in the UUID text form.
        if bytes.count == 32 {
            bytes[12] = Array("5".utf8)[0]
            if (bytes[16] >= 48 && bytes[16] <= 57) || (bytes[16] >= 97 && bytes[16] <= 102) {
                bytes[16] = Array("8".utf8)[0]
            }
        }
        return uuidFromHex(String(decoding: bytes, as: UTF8.self))
    }

    static func patch(data: Data, sceneUUID: String, scriptUUID: String,
                      nodeName: String = "FloeDeveloper") throws -> PatchResult {
        let root = try parse(data)
        guard let array = root as? [Any], array.count >= 2 else {
            throw CocosSceneJSONError.invalid("scene root")
        }
        guard let asset = array[0] as? [String: Any], asset["__type__"] as? String == "cc.SceneAsset",
              let scene = array[1] as? [String: Any], scene["__type__"] as? String == "cc.Scene",
              let sceneID = scene["_id"] as? String,
              sceneID.caseInsensitiveCompare(sceneUUID) == .orderedSame else {
            throw CocosSceneJSONError.invalid("scene identity")
        }
        guard let children = scene["_children"] as? [Any] else {
            throw CocosSceneJSONError.invalid("scene children")
        }
        let scriptType = try compressedUUID(scriptUUID)
        let componentIndices = array.indices.filter { index in
            guard let object = array[index] as? [String: Any] else { return false }
            return object["__type__"] as? String == scriptType
        }
        if let existing = componentIndices.first {
            guard let component = array[existing] as? [String: Any],
                  let nodeRef = component["node"] as? [String: Any],
                  let nodeID = nodeRef["__id__"] as? Int,
                  nodeID >= 0, nodeID < array.count,
                  let node = array[nodeID] as? [String: Any],
                  node["__type__"] as? String == "cc.Node",
                  let parent = node["_parent"] as? [String: Any],
                  (parent["__id__"] as? Int) == 1 else {
                throw CocosSceneJSONError.invalid("existing bridge component")
            }
            return PatchResult(data: data, alreadyInstalled: true,
                               nodeIndex: nodeID, componentIndex: existing)
        }
        for child in children {
            guard let reference = child as? [String: Any], let index = reference["__id__"] as? Int,
                  index >= 0, index < array.count, let node = array[index] as? [String: Any] else {
                throw CocosSceneJSONError.invalid("scene child reference")
            }
            guard node["__type__"] as? String == "cc.Node",
                  let parent = node["_parent"] as? [String: Any],
                  (parent["__id__"] as? Int) == 1 else {
                throw CocosSceneJSONError.invalid("scene child parent")
            }
            if (node["_name"] as? String) == nodeName {
                throw CocosSceneJSONError.invalid("node name collision")
            }
        }
        let nodeIndex = array.count
        let componentIndex = nodeIndex + 1
        let nodeID = try objectID(seed: scriptUUID + "|node|" + nodeName)
        let componentID = try objectID(seed: scriptUUID + "|component|")
        let patched = try insert(data: data, sceneIndex: 1, nodeIndex: nodeIndex,
                                 componentIndex: componentIndex, scriptType: scriptType,
                                 nodeName: nodeName, nodeID: nodeID, componentID: componentID)
        let verification = try parse(patched)
        guard let after = verification as? [Any], after.count == array.count + 2,
              let afterScene = after[1] as? [String: Any],
              let afterChildren = afterScene["_children"] as? [Any],
              afterChildren.count == children.count + 1,
              let newReference = afterChildren.last as? [String: Any],
              (newReference["__id__"] as? Int) == nodeIndex,
              let newNode = after[nodeIndex] as? [String: Any],
              (newNode["_name"] as? String) == nodeName,
              let newComponent = after[componentIndex] as? [String: Any],
              (newComponent["__type__"] as? String) == scriptType,
              let nodeRef = newComponent["node"] as? [String: Any],
              (nodeRef["__id__"] as? Int) == nodeIndex else {
            throw CocosSceneJSONError.invalid("patched scene verification")
        }
        // Preserve every original array element semantically. The scene object
        // is expected to gain exactly one child id; all other fields are equal.
        for index in array.indices where index != 1 {
            guard let original = try? JSONSerialization.data(withJSONObject: array[index], options: [.sortedKeys]),
                  let updated = try? JSONSerialization.data(withJSONObject: after[index], options: [.sortedKeys]),
                  original == updated else {
                throw CocosSceneJSONError.invalid("scene preservation")
            }
        }
        var originalScene = scene
        var updatedScene = afterScene
        originalScene.removeValue(forKey: "_children")
        updatedScene.removeValue(forKey: "_children")
        guard let originalSceneData = try? JSONSerialization.data(withJSONObject: originalScene, options: [.sortedKeys]),
              let updatedSceneData = try? JSONSerialization.data(withJSONObject: updatedScene, options: [.sortedKeys]),
              originalSceneData == updatedSceneData else {
            throw CocosSceneJSONError.invalid("scene field preservation")
        }
        return PatchResult(data: patched, alreadyInstalled: false,
                           nodeIndex: nodeIndex, componentIndex: componentIndex)
    }

    static func parse(_ data: Data) throws -> Any {
        guard data.count > 0, data.count <= GameDeveloperInstrumentationConstants.cocosMaximumSceneBytes else {
            throw CocosSceneJSONError.invalid("scene bytes")
        }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw CocosSceneJSONError.invalid("scene JSON") }
    }

    // MARK: - Byte-preserving insertion

    private static func insert(data: Data, sceneIndex: Int, nodeIndex: Int, componentIndex: Int,
                               scriptType: String, nodeName: String, nodeID: String,
                               componentID: String) throws -> Data {
        var bytes = Array(data)
        guard let elements = topLevelElements(bytes), elements.count > sceneIndex else {
            throw CocosSceneJSONError.invalid("top level")
        }
        let sceneRange = elements[sceneIndex]
        guard let childrenRange = findKeyValue(bytes, in: sceneRange, key: "_children"),
              childrenRange.valueStart < childrenRange.valueEnd,
              bytes[safe: childrenRange.valueStart] == UInt8(ascii: "[") else {
            throw CocosSceneJSONError.invalid("children range")
        }
        let indent = lineIndent(bytes: bytes, at: sceneRange.start)
        let itemIndent = indent + "  "
        let fieldIndent = itemIndent + "  "
        // Insert the child reference before the array's closing bracket.
        let close = childrenRange.valueEnd - 1
        var cursor = close
        while cursor > childrenRange.valueStart + 1 {
            let byte = bytes[cursor - 1]
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { cursor -= 1; continue }
            break
        }
        let hasChildren = cursor > childrenRange.valueStart + 1
        let childText = (hasChildren ? ",\n" : "\n") + itemIndent + "{\n"
            + fieldIndent + "\"__id__\": \(nodeIndex)\n"
            + itemIndent + "}" + (hasChildren ? "" : "\n" + indent)
        bytes.insert(contentsOf: Array(childText.utf8), at: cursor)
        // Insert the node and component before the top-level closing bracket.
        guard let top = topLevelArrayRange(bytes) else {
            throw CocosSceneJSONError.invalid("top level range")
        }
        var topCursor = top.end - 1
        while topCursor > top.start + 1 {
            let byte = bytes[topCursor - 1]
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { topCursor -= 1; continue }
            break
        }
        let nodeText = nodeObject(indent: "  ", field: "    ", nodeIndex: nodeIndex,
                                  componentIndex: componentIndex, nodeName: nodeName,
                                  nodeID: nodeID)
        let componentText = componentObject(indent: "  ", field: "    ",
                                            nodeIndex: nodeIndex, scriptType: scriptType,
                                            componentID: componentID)
        let appended = ",\n" + nodeText + ",\n" + componentText
        bytes.insert(contentsOf: Array(appended.utf8), at: topCursor)
        return Data(bytes)
    }

    private static func nodeObject(indent: String, field: String, nodeIndex: Int,
                                   componentIndex: Int, nodeName: String,
                                   nodeID: String) -> String {
        """
        \(indent){
        \(field)"__type__": "cc.Node",
        \(field)"_name": "\(nodeName)",
        \(field)"_objFlags": 0,
        \(field)"_parent": {
        \(field)  "__id__": 1
        \(field)},
        \(field)"_children": [],
        \(field)"_active": true,
        \(field)"_components": [
        \(field)  {
        \(field)    "__id__": \(componentIndex)
        \(field)  }
        \(field)],
        \(field)"_prefab": null,
        \(field)"_lpos": {
        \(field)  "__type__": "cc.Vec3",
        \(field)  "x": 0,
        \(field)  "y": 0,
        \(field)  "z": 0
        \(field)},
        \(field)"_lrot": {
        \(field)  "__type__": "cc.Quat",
        \(field)  "x": 0,
        \(field)  "y": 0,
        \(field)  "z": 0,
        \(field)  "w": 1
        \(field)},
        \(field)"_lscale": {
        \(field)  "__type__": "cc.Vec3",
        \(field)  "x": 1,
        \(field)  "y": 1,
        \(field)  "z": 1
        \(field)},
        \(field)"_mobility": 0,
        \(field)"_layer": 1073741824,
        \(field)"_euler": {
        \(field)  "__type__": "cc.Vec3",
        \(field)  "x": 0,
        \(field)  "y": 0,
        \(field)  "z": 0
        \(field)},
        \(field)"_id": "\(nodeID)"
        \(indent)}
        """
    }

    private static func componentObject(indent: String, field: String, nodeIndex: Int,
                                        scriptType: String, componentID: String) -> String {
        """
        \(indent){
        \(field)"__type__": "\(scriptType)",
        \(field)"_name": "",
        \(field)"_objFlags": 0,
        \(field)"node": {
        \(field)  "__id__": \(nodeIndex)
        \(field)},
        \(field)"_enabled": true,
        \(field)"__prefab": null,
        \(field)"_id": "\(componentID)"
        \(indent)}
        """
    }

    private struct Range { let start: Int; let end: Int }
    private struct ValueRange { let valueStart: Int; let valueEnd: Int }

    private static func topLevelArrayRange(_ bytes: [UInt8]) -> Range? {
        var index = skipWhitespace(bytes, from: 0)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return nil }
        let start = index
        var depth = 0
        var inString = false
        var escape = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escape { escape = false }
                else if byte == UInt8(ascii: "\\") { escape = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") { inString = true }
            else if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") { depth += 1 }
            else if byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return Range(start: start, end: index + 1) }
            }
            index += 1
        }
        return nil
    }

    private static func topLevelElements(_ bytes: [UInt8]) -> [Range]? {
        guard let top = topLevelArrayRange(bytes) else { return nil }
        var result: [Range] = []
        var index = top.start + 1
        var depth = 1
        var inString = false
        var escape = false
        var elementStart: Int?
        while index < top.end - 1 {
            let byte = bytes[index]
            if inString {
                if escape { escape = false }
                else if byte == UInt8(ascii: "\\") { escape = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") { inString = true }
            else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                if depth == 1 { elementStart = index }
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                if depth == 1, let start = elementStart {
                    result.append(Range(start: start, end: index + 1))
                    elementStart = nil
                }
            }
            index += 1
        }
        return result.isEmpty ? nil : result
    }

    private static func findKeyValue(_ bytes: [UInt8], in range: Range, key: String) -> ValueRange? {
        var index = range.start + 1
        var depth = 1
        var inString = false
        var escape = false
        while index < range.end - 1 {
            let byte = bytes[index]
            if inString {
                if escape { escape = false }
                else if byte == UInt8(ascii: "\\") { escape = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                let stringStart = index + 1
                var cursor = stringStart
                var escaped = false
                while cursor < range.end - 1 {
                    let value = bytes[cursor]
                    if escaped { escaped = false }
                    else if value == UInt8(ascii: "\\") { escaped = true }
                    else if value == UInt8(ascii: "\"") { break }
                    cursor += 1
                }
                let text = String(decoding: bytes[stringStart..<cursor], as: UTF8.self)
                var after = skipWhitespace(bytes, from: cursor + 1)
                if depth == 1, text == key, after < range.end, bytes[after] == UInt8(ascii: ":") {
                    after = skipWhitespace(bytes, from: after + 1)
                    guard after < range.end else { return nil }
                    guard let valueEnd = valueEnd(bytes, from: after, limit: range.end) else { return nil }
                    return ValueRange(valueStart: after, valueEnd: valueEnd)
                }
                index = cursor + 1
                continue
            }
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
            else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") { depth -= 1 }
            index += 1
        }
        return nil
    }

    private static func valueEnd(_ bytes: [UInt8], from start: Int, limit: Int) -> Int? {
        var index = start
        var depth = 0
        var inString = false
        var escape = false
        while index < limit {
            let byte = bytes[index]
            if inString {
                if escape { escape = false }
                else if byte == UInt8(ascii: "\\") { escape = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") { inString = true }
            else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
            else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 } else { break }
        }
        return index
    }

    private static func lineIndent(bytes: [UInt8], at position: Int) -> String {
        var index = position
        while index > 0 {
            let byte = bytes[index - 1]
            if byte == 0x0A { break }
            index -= 1
        }
        var spaces = ""
        while index < position, bytes[index] == 0x20 {
            spaces += " "
            index += 1
        }
        return spaces
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
