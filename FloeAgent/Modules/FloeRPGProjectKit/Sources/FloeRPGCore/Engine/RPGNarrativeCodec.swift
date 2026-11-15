// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore

/// Bidirectional codec between engine-native event command lists and the
/// editor `NarrativeDocument`. Known commands expose named fields; unknown
/// commands are surfaced read-only and re-serialize byte-identically.
public struct RPGNarrativeCodec: Sendable {
    public let engine: RPGEngine

    public init(engine: RPGEngine) {
        self.engine = engine
    }

    private var isJSON: Bool { engine.usesJSONData }
    private var specs: [RPGCommandSpec] { isJSON ? RPGCommandSpec.jsonCommon : RPGCommandSpec.binaryCommon }

    /// Stable editor identities let an edit captured by a view survive a
    /// fresh decode in the session transaction. Native files gain no IDs.
    private func stableID(_ location: String) -> UUID {
        var b = Array(stableEditorDigest(engine.rawValue + "|" + location).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }

    // MARK: - Decode

    /// Decodes one binary event page node (`@list`) to a narrative document.
    public func decodeBinaryPage(_ page: RubyNode, title: String) throws -> NarrativeDocument {
        let commands = RPGMapDocument.binaryCommandList(page)
        var labels: [NarrativeDocument.Label] = []
        var rows: [NarrativeDocument.Command] = []
        for (commandIndex, command) in commands.enumerated() {
            let spec = RPGCommandSpec.spec(for: command.code, json: false)
            var labelID: UUID? = nil
            if command.code == 118, let name = command.parameters.first?.stringValue {
                let label = NarrativeDocument.Label(id: stableID(title + "|page|label|" + String(commandIndex)), name: name)
                labels.append(label)
                labelID = label.id
            }
            if command.code == 119, let name = command.parameters.first?.stringValue {
                labelID = labels.first(where: { $0.name == name })?.id
            }
            let original = RPGMarshalJSON.encode(commandNode(command))
            rows.append(NarrativeDocument.Command(
                id: stableID(title + "|page|command|" + String(commandIndex)),
                code: spec.map { String($0.code) } ?? "unknown-\(command.code)",
                parameters: namedParameters(command, spec: spec),
                branchRole: branchRole(for: command.code),
                labelID: labelID,
                isSupported: spec != nil,
                originalPayload: original))
        }
        return NarrativeDocument(title: title, labels: labels, commands: rows)
    }

    /// Decodes one MV/MZ event page JSON to a narrative document.
    public func decodeJSONPage(_ page: JSONValue, title: String) throws -> NarrativeDocument {
        guard let list = page["list"]?.arrayValue else {
            throw RPGCodecError.malformedArchive("page has no command list")
        }
        var labels: [NarrativeDocument.Label] = []
        var rows: [NarrativeDocument.Command] = []
        for (commandIndex, item) in list.enumerated() {
            guard let object = item.objectValue, let code = object["code"]?.intValue,
                  let indent = object["indent"]?.intValue else { throw RPGCodecError.malformedArchive("bad command") }
            let spec = RPGCommandSpec.spec(for: code, json: true)
            let parameters = object["parameters"]?.arrayValue ?? []
            var labelID: UUID? = nil
            if code == 118, let name = parameters.first?.stringValue {
                let label = NarrativeDocument.Label(id: stableID(title + "|page|label|" + String(commandIndex)), name: name)
                labels.append(label)
                labelID = label.id
            }
            if code == 119, let name = parameters.first?.stringValue {
                labelID = labels.first(where: { $0.name == name })?.id
            }
            rows.append(NarrativeDocument.Command(
                id: stableID(title + "|page|command|" + String(commandIndex)),
                code: spec.map { String($0.code) } ?? "unknown-\(code)",
                parameters: {
                    var named = namedJSONParameters(parameters, spec: spec)
                    named["indent"] = .number(Double(indent))
                    return named
                }(),
                branchRole: branchRole(for: code),
                labelID: labelID,
                isSupported: spec != nil,
                originalPayload: item))
        }
        return NarrativeDocument(title: title, labels: labels, commands: rows)
    }

    // MARK: - Encode

    /// Encodes a narrative document back to an `@list`-shaped Ruby node.
    /// Unsupported rows reuse their original node untouched; supported rows
    /// rebuild from named fields overlaid on their original payload.
    public func encodeBinaryPage(_ document: NarrativeDocument) throws -> RubyNode {
        var nodes: [RubyNode] = []
        for row in document.commands {
            guard let original = row.originalPayload else { throw RPGCodecError.malformedArchive("row \(row.id) missing payload") }
            let originalNode = try RPGMarshalJSON.decode(original)
            guard row.isSupported, let code = Int(row.code), RPGCommandSpec.spec(for: code, json: false) != nil else {
                nodes.append(originalNode) // unknown: byte-exact preservation
                continue
            }
            nodes.append(try applyBinaryOverrides(originalNode, row: row, code: code, document: document))
        }
        return RubyNode(RubyValue(kind: .array(nodes)))
    }

    public func encodeJSONPage(_ document: NarrativeDocument) throws -> JSONValue {
        var items: [JSONValue] = []
        for row in document.commands {
            guard let original = row.originalPayload, let object = original.objectValue else {
                throw RPGCodecError.malformedArchive("row \(row.id) missing payload")
            }
            guard row.isSupported, let code = Int(row.code), RPGCommandSpec.spec(for: code, json: true) != nil else {
                items.append(original) // unknown: exact preservation
                continue
            }
            var parameters = object["parameters"]?.arrayValue ?? []
            parameters = try applyJSONOverrides(parameters, row: row, code: code, document: document)
            items.append(.object([
                "code": .number(Double(code)),
                "indent": .number(Double(row.indentEstimate)),
                "parameters": .array(parameters),
            ]))
        }
        return .array(items)
    }

    // MARK: - Mapping helpers

    private func branchRole(for code: Int) -> NarrativeDocument.BranchRole {
        switch code {
        case 111, 112: return .open
        case 412, 413: return .close
        default: return .none
        }
    }

    private func namedParameters(_ command: RPGEventCommand, spec: RPGCommandSpec?) -> [String: JSONValue] {
        guard let spec else { return [:] }
        var named: [String: JSONValue] = [:]
        for (index, name) in spec.fieldNames.enumerated() where index < command.parameters.count {
            let parameter = command.parameters[index]
            named[name] = jsonParameter(parameter)
        }
        named["indent"] = .number(Double(command.indent))
        return named
    }

    private func namedJSONParameters(_ parameters: [JSONValue], spec: RPGCommandSpec?) -> [String: JSONValue] {
        guard let spec else { return [:] }
        var named: [String: JSONValue] = [:]
        for (index, name) in spec.fieldNames.enumerated() where index < parameters.count {
            named[name] = parameters[index]
        }
        return named
    }
    private func jsonParameter(_ parameter: RPGCommandParameter) -> JSONValue {
        switch parameter {
        case .`nil`: return .null
        case .bool(let value): return .bool(value)
        case .integer(let value): return .number(Double(value))
        case .float(let value): return .number(value)
        case .string(let value): return .string(value)
        case .binary(let data): return .string(data.base64EncodedString())
        }
    }

    /// Rebuilds the editable Ruby node for a scalar command (round-trips
    /// through the narrative payload form).
    private func commandNode(_ command: RPGEventCommand) -> RubyNode {
        let params = command.parameters.map { parameter -> RubyNode in
            switch parameter {
            case .`nil`: return RubyNode(RubyValue(kind: .`nil`))
            case .bool(let value): return RubyNode(RubyValue(kind: .bool(value)))
            case .integer(let value): return RubyNode(RubyValue(kind: .integer(value)))
            case .float(let value): return RubyNode(RubyValue(kind: .float(RubyFloat(value))))
            case .string(let value): return RubyNode(RubyValue(kind: .string(.utf8(value))))
            case .binary(let data): return RubyNode(RubyValue(kind: .string(RubyString(bytes: data, encoding: .binary))))
            }
        }
        return RubyNode(RubyValue(kind: .object(className: "RPG::EventCommand", ivars: [
            RubyIvar(name: "@code", value: RubyNode(RubyValue(kind: .integer(Int64(command.code))))),
            RubyIvar(name: "@indent", value: RubyNode(RubyValue(kind: .integer(Int64(command.indent))))),
            RubyIvar(name: "@parameters", value: RubyNode(RubyValue(kind: .array(params)))),
        ])))
    }

    private func command(from node: RubyNode) throws -> RPGEventCommand {
        guard let code = node.intMember("@code"), let indent = node.intMember("@indent"),
              let params = node[member: "@parameters"]?.value.kind.arrayValue else {
            throw RPGCodecError.malformedArchive("bad original command payload")
        }
        return RPGEventCommand(code: Int(code), indent: Int(indent), parameters: params.map(RPGMapDocument.binaryParameter))
    }

    /// Applies narrative edits to an original command node by replacing only
    /// the parameter slots whose values actually changed. Untouched slots keep
    /// their original Ruby nodes, so shared strings, encoding ivars and object
    /// links survive byte-identically.
    private func applyBinaryOverrides(_ originalNode: RubyNode, row: NarrativeDocument.Command,
                                      code: Int, document: NarrativeDocument) throws -> RubyNode {
        guard var parameterNodes = originalNode[member: "@parameters"]?.value.kind.arrayValue else {
            return originalNode
        }
        func current(_ index: Int) -> JSONValue? {
            guard parameterNodes.indices.contains(index) else { return nil }
            return RPGMarshalJSON.encode(parameterNodes[index])
        }
        func sameScalar(_ node: RubyNode, _ json: JSONValue) -> Bool {
            switch node.value.kind {
            case .string(let string): return string.utf8String == json.stringValue
            case .integer(let value): return json.intValue.map(Int64.init) == value
            case .bool(let value): return json.boolValue == value
            case .float(let value): return json.numberValue == value.doubleValue
            case .nil: return json.isNull
            default: return false
            }
        }
        func patch(_ index: Int, _ desired: JSONValue?) throws {
            guard let desired else { return }
            if parameterNodes.indices.contains(index) {
                if sameScalar(parameterNodes[index], desired) { return }
                // Compare full node forms for non-scalars.
                if current(index) == desired { return }
            }
            while parameterNodes.count <= index { parameterNodes.append(RubyNode(RubyValue(kind: .nil))) }
            parameterNodes[index] = try jsonToNode(desired)
        }
        switch code {
        case 118, 119:
            if let labelID = row.labelID, let label = document.label(id: labelID) {
                try patch(0, .object(["$string": .string(label.name), "$encoding": .string("utf-8")]))
            }
        case 101:
            try patch(0, row.parameters["faceName"])
            try patch(1, row.parameters["faceIndex"])
            try patch(2, row.parameters["background"])
            try patch(3, row.parameters["position"])
        case 401, 408, 355, 655:
            try patch(0, row.parameters["text"] ?? row.parameters["line"])
        case 117:
            try patch(0, row.parameters["commonEventId"])
        case 303:
            try patch(0, row.parameters["actorId"])
            try patch(1, row.parameters["name"])
        default:
            break // other known codes keep their original parameters
        }
        if let current = originalNode[member: "@parameters"]?.value.kind.arrayValue,
           current.count == parameterNodes.count,
           zip(current, parameterNodes).allSatisfy({ $0 === $1 }) {
            return originalNode
        }
        originalNode[member: "@parameters"] = RubyNode(RubyValue(kind: .array(parameterNodes)))
        return originalNode
    }

    private func jsonToNode(_ value: JSONValue) throws -> RubyNode {
        try RPGMarshalJSON.decode(value)
    }

    struct EventListKey: Hashable { let event: Int; let page: Int }

    static func binaryEventLists(in root: RubyNode) -> [EventListKey: [RubyNode]] {
        var result: [EventListKey: [RubyNode]] = [:]
        if root.value.kind.className == "RPG::Map", let hash = root[member: "@events"]?.value.kind.hashValue {
            for pair in hash.pairs {
                guard let id = pair.key.value.kind.int64Value,
                      let pages = pair.value[member: "@pages"]?.value.kind.arrayValue else { continue }
                for (page, node) in pages.enumerated() {
                    result[EventListKey(event: Int(id), page: page)] =
                        node[member: "@list"]?.value.kind.arrayValue ?? []
                }
            }
        } else if let items = root.value.kind.arrayValue {
            for (index, event) in items.enumerated() {
                guard event.value.kind.className != nil, !event.value.kind.isNil else { continue }
                result[EventListKey(event: index, page: 0)] =
                    event[member: "@list"]?.value.kind.arrayValue ?? []
            }
        }
        return result
    }

    private func applyJSONOverrides(_ base: [JSONValue], row: NarrativeDocument.Command,
                                    code: Int, document: NarrativeDocument) throws -> [JSONValue] {
        var parameters = base
        func set(_ index: Int, _ value: JSONValue?) {
            guard let value else { return }
            while parameters.count <= index { parameters.append(.null) }
            parameters[index] = value
        }
        switch code {
        case 118, 119:
            if let labelID = row.labelID, let label = document.label(id: labelID) {
                parameters = [.string(label.name)]
            }
        case 101:
            set(0, row.parameters["faceName"])
            set(1, row.parameters["faceIndex"])
            set(2, row.parameters["background"])
            set(3, row.parameters["position"])
        case 401, 408, 355, 655:
            set(0, row.parameters["text"] ?? row.parameters["line"])
        case 117:
            set(0, row.parameters["commonEventId"])
        case 303:
            set(0, row.parameters["actorId"])
            set(1, row.parameters["name"])
        default:
            break
        }
        return parameters
    }

    private func parameterString(_ command: RPGEventCommand, _ index: Int) -> String? {
        command.parameters.indices.contains(index) ? command.parameters[index].stringValue : nil
    }

    private func parameterInt(_ command: RPGEventCommand, _ index: Int) -> Int64? {
        command.parameters.indices.contains(index) ? command.parameters[index].intValue : nil
    }

    // MARK: - Multi-list containers (CommonEvents files and map files)

    /// Decodes a binary container (CommonEvents array or RPG::Map @events
    /// hash) into one flattened narrative document. Every command's
    /// `originalPayload` is wrapped as `{"event": id, "page": p, "payload": …}`
    /// so encode can rebuild each event's list even after reordering.
    public func decodeBinaryEventContainer(_ root: RubyNode, title: String) throws -> NarrativeDocument {
        var lists: [(id: Int, page: Int, list: RubyNode)] = []
        if root.value.kind.className == "RPG::Map", let hash = root[member: "@events"]?.value.kind.hashValue {
            for pair in hash.pairs {
                guard let id = pair.key.value.kind.int64Value,
                      let pages = pair.value[member: "@pages"]?.value.kind.arrayValue else { continue }
                for (page, node) in pages.enumerated() {
                    lists.append((id: Int(id), page: page, list: node))
                }
            }
            lists.sort { ($0.id, $0.page) < ($1.id, $1.page) }
        } else if let items = root.value.kind.arrayValue {
            // CommonEvents: index-aligned array of RPG::CommonEvent (or subclasses);
            // the event node itself owns @list.
            for (index, event) in items.enumerated() {
                guard event.value.kind.className != nil, !event.value.kind.isNil else { continue }
                guard event[member: "@list"] != nil else { continue }
                lists.append((id: index, page: 0, list: event))
            }
        } else {
            throw RPGCodecError.malformedArchive("not an event container")
        }
        var labels: [NarrativeDocument.Label] = []
        var rows: [NarrativeDocument.Command] = []
        for entry in lists {
            let label = NarrativeDocument.Label(id: stableID(title + "|event|\(entry.id)|page|\(entry.page)|header"), name: "event-\(entry.id)-page-\(entry.page)")
            labels.append(label)
            guard let commandNodes = entry.list[member: "@list"]?.value.kind.arrayValue else { continue }
            for (commandIndex, itemNode) in commandNodes.enumerated() {
                guard let code64 = itemNode.intMember("@code"), let indent64 = itemNode.intMember("@indent"),
                      let params = itemNode[member: "@parameters"]?.value.kind.arrayValue else { continue }
                let command = RPGEventCommand(code: Int(code64), indent: Int(indent64),
                                              parameters: params.map(RPGMapDocument.binaryParameter))
                let spec = RPGCommandSpec.spec(for: command.code, json: false)
                var labelID: UUID? = nil
                if command.code == 118, let name = command.parameters.first?.stringValue {
                    let target = NarrativeDocument.Label(id: stableID(title + "|event|\(entry.id)|page|\(entry.page)|label|\(commandIndex)"), name: name)
                    labels.append(target)
                    labelID = target.id
                }
                if command.code == 119, let name = command.parameters.first?.stringValue {
                    labelID = labels.first(where: { $0.name == name })?.id
                }
                // The payload is the original command node (byte identity,
                // shared links and encoding ivars preserved verbatim).
                let wrapped: JSONValue = .object([
                    "event": .number(Double(entry.id)),
                    "page": .number(Double(entry.page)),
                    "payload": RPGMarshalJSON.encode(itemNode),
                ])
                var named = namedParameters(command, spec: spec)
                named["event"] = .number(Double(entry.id))
                named["page"] = .number(Double(entry.page))
                rows.append(NarrativeDocument.Command(
                    id: stableID(title + "|event|\(entry.id)|page|\(entry.page)|command|\(commandIndex)"),
                    code: spec.map { String($0.code) } ?? "unknown-\(command.code)",
                    parameters: named,
                    branchRole: branchRole(for: command.code),
                    labelID: labelID,
                    isSupported: spec != nil,
                    originalPayload: wrapped))
            }
        }
        return NarrativeDocument(title: title, labels: labels, commands: rows)
    }

    /// Rebuilds event command lists from the document and merges them into
    /// the original container, preserving every field outside the edited
    /// lists (event names, triggers, page conditions, map tiles, ...).
    public func encodeBinaryEventContainer(_ document: NarrativeDocument,
                                           mergingInto original: RubyNode) throws -> RubyNode {
        typealias Key = EventListKey
        var lists: [Key: [RubyNode]] = [:]
        var orderedKeys: [Key] = []
        let originalLists = Self.binaryEventLists(in: original)
        for row in document.commands {
            guard let wrapped = row.originalPayload?.objectValue,
                  let event = wrapped["event"]?.intValue, let page = wrapped["page"]?.intValue,
                  let payload = wrapped["payload"] else {
                throw RPGCodecError.malformedArchive("row \(row.id) missing container payload")
            }
            let key = Key(event: event, page: page)
            if !orderedKeys.contains(key) { orderedKeys.append(key) }
            let originalNode = try RPGMarshalJSON.decode(payload)
            guard row.isSupported, let code = Int(row.code), RPGCommandSpec.spec(for: code, json: false) != nil else {
                lists[key, default: []].append(originalNode) // unknown: preserved exactly
                continue
            }
            lists[key, default: []].append(try applyBinaryOverrides(originalNode, row: row, code: code, document: document))
        }
        // When a page keeps the same command count, patch the container's
        // original nodes in place so shared strings, encodings and object
        // links survive; rebuild only structurally edited pages.
        for key in orderedKeys {
            guard let originalList = originalLists[key],
                  originalList.count == (lists[key]?.count ?? 0) else { continue }
            var patched: [RubyNode] = []
            let rows = document.commands.filter { row in
                guard let wrapped = row.originalPayload?.objectValue,
                      let event = wrapped["event"]?.intValue, let page = wrapped["page"]?.intValue else { return false }
                return event == key.event && page == key.page
            }
            for (index, node) in originalList.enumerated() where index < rows.count {
                let row = rows[index]
                if row.isSupported, let code = Int(row.code), RPGCommandSpec.spec(for: code, json: false) != nil {
                    patched.append(try applyBinaryOverrides(node, row: row, code: code, document: document))
                } else {
                    patched.append(node)
                }
            }
            if patched.count == originalList.count {
                lists[key] = patched
            }
        }
        if original.value.kind.className == "RPG::Map" {
            guard let eventsNode = original[member: "@events"] else { throw RPGCodecError.malformedArchive("missing @events") }
            var hash = eventsNode.value.kind.hashValue ?? RubyHash(pairs: [])
            for (key, list) in lists {
                guard let pairIndex = hash.pairs.firstIndex(where: { $0.key.value.kind.int64Value == Int64(key.event) }) else { continue }
                let eventNode = hash.pairs[pairIndex].value
                guard var pages = eventNode[member: "@pages"]?.value.kind.arrayValue,
                      pages.indices.contains(key.page) else { continue }
                pages[key.page][member: "@list"] = RubyNode(RubyValue(kind: .array(list)))
                eventNode[member: "@pages"] = RubyNode(RubyValue(kind: .array(pages)))
                hash.pairs[pairIndex].value = eventNode
            }
            original[member: "@events"] = RubyNode(RubyValue(kind: .hash(hash)))
            return original
        }
        // CommonEvents array: replace each event's @list only.
        guard var items = original.value.kind.arrayValue else { throw RPGCodecError.malformedArchive("bad container") }
        for (key, list) in lists {
            guard items.indices.contains(key.event), !items[key.event].value.kind.isNil else { continue }
            items[key.event][member: "@list"] = RubyNode(RubyValue(kind: .array(list)))
        }
        original.value.kind = .array(items)
        return original
    }

    /// Decodes an MV/MZ event container (map "events" array or common events
    /// {"events": [...]}) into one flattened narrative document.
    public func decodeJSONEventContainer(_ root: JSONValue, title: String) throws -> NarrativeDocument {
        // Maps are objects with an "events" array; CommonEvents.json is a raw
        // [null, {...}] array.
        guard let events = root["events"]?.arrayValue ?? root.arrayValue else {
            throw RPGCodecError.malformedArchive("not an event container")
        }
        // Discriminate CommonEvents.json (entries carry "list") from maps
        // (entries carry "pages") by inspecting the first populated entry.
        let isCommonEvents = events.contains(where: { $0.objectValue?["list"] != nil })
        var lists: [(id: Int, page: Int, commands: [JSONValue])] = []
        if isCommonEvents {
            for (index, event) in events.enumerated() {
                guard let list = event["list"]?.arrayValue else { continue }
                lists.append((id: index, page: 0, commands: list))
            }
        } else {
            for (index, event) in events.enumerated() {
                guard let pages = event["pages"]?.arrayValue else { continue }
                for (page, pageValue) in pages.enumerated() {
                    lists.append((id: index, page: page, commands: pageValue["list"]?.arrayValue ?? []))
                }
            }
        }
        var labels: [NarrativeDocument.Label] = []
        var rows: [NarrativeDocument.Command] = []
        for entry in lists {
            let label = NarrativeDocument.Label(id: stableID(title + "|event|\(entry.id)|page|\(entry.page)|header"), name: "event-\(entry.id)-page-\(entry.page)")
            labels.append(label)
            for (commandIndex, item) in entry.commands.enumerated() {
                guard let object = item.objectValue, let code = object["code"]?.intValue,
                      let indent = object["indent"]?.intValue else { throw RPGCodecError.malformedArchive("bad command") }
                let spec = RPGCommandSpec.spec(for: code, json: true)
                var labelID: UUID? = nil
                if code == 118, let name = object["parameters"]?.arrayValue?.first?.stringValue {
                    let target = NarrativeDocument.Label(id: stableID(title + "|event|\(entry.id)|page|\(entry.page)|label|\(commandIndex)"), name: name)
                    labels.append(target)
                    labelID = target.id
                }
                if code == 119, let name = object["parameters"]?.arrayValue?.first?.stringValue {
                    labelID = labels.first(where: { $0.name == name })?.id
                }
                let wrapped: JSONValue = .object([
                    "event": .number(Double(entry.id)),
                    "page": .number(Double(entry.page)),
                    "payload": item,
                ])
                var named = namedJSONParameters(object["parameters"]?.arrayValue ?? [], spec: spec)
                named["indent"] = .number(Double(indent))
                named["event"] = .number(Double(entry.id))
                named["page"] = .number(Double(entry.page))
                rows.append(NarrativeDocument.Command(
                    id: stableID(title + "|event|\(entry.id)|page|\(entry.page)|command|\(commandIndex)"),
                    code: spec.map { String($0.code) } ?? "unknown-\(code)",
                    parameters: named,
                    branchRole: branchRole(for: code),
                    labelID: labelID,
                    isSupported: spec != nil,
                    originalPayload: wrapped))
            }
        }
        return NarrativeDocument(title: title, labels: labels, commands: rows)
    }

    /// Rebuilds event command lists and merges them into the original MV/MZ
    /// container (map or common events), preserving all unknown fields.
    public func encodeJSONEventContainer(_ document: NarrativeDocument,
                                         mergingInto original: JSONValue) throws -> JSONValue {
        struct Key: Hashable { let event: Int; let page: Int }
        var lists: [Key: [JSONValue]] = [:]
        for row in document.commands {
            guard let wrapped = row.originalPayload?.objectValue,
                  let event = wrapped["event"]?.intValue, let page = wrapped["page"]?.intValue,
                  let payload = wrapped["payload"], let object = payload.objectValue else {
                throw RPGCodecError.malformedArchive("row \(row.id) missing container payload")
            }
            let key = Key(event: event, page: page)
            guard row.isSupported, let code = Int(row.code), RPGCommandSpec.spec(for: code, json: true) != nil else {
                lists[key, default: []].append(payload)
                continue
            }
            let parameters = try applyJSONOverrides(object["parameters"]?.arrayValue ?? [], row: row, code: code, document: document)
            lists[key, default: []].append(.object([
                "code": .number(Double(code)),
                "indent": .number(Double(row.indentEstimate)),
                "parameters": .array(parameters),
            ]))
        }
        if var items = original.arrayValue {
            // Raw CommonEvents array: each event carries its own list.
            for (key, list) in lists {
                guard items.indices.contains(key.event), let object = items[key.event].objectValue else { continue }
                var event = object
                event["list"] = .array(list)
                items[key.event] = .object(event)
            }
            return .array(items)
        }
        var container = original
        var events = container["events"]?.arrayValue ?? [.null]
        for (key, list) in lists {
            guard events.indices.contains(key.event), events[key.event].objectValue != nil else { continue }
            var event = events[key.event].objectValue ?? [:]
            if key.page == 0, event["pages"] == nil, event["list"] != nil {
                // CommonEvents-style single list.
                event["list"] = .array(list)
            } else {
                var pages = event["pages"]?.arrayValue ?? []
                while pages.count <= key.page { pages.append(.object([:])) }
                var page = pages[key.page].objectValue ?? [:]
                page["list"] = .array(list)
                pages[key.page] = .object(page)
                event["pages"] = .array(pages)
            }
            events[key.event] = .object(event)
        }
        container.setKey(.array(events), "events")
        return container
    }
}

extension NarrativeDocument.Command {
    /// The original list indent for supported rows (binary carries it in the
    /// payload; the DTO exposes it via the "indent" named parameter).
    var indentEstimate: Int {
        parameters["indent"]?.intValue ?? 0
    }
}
