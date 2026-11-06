import Foundation

public struct ChemicalPoint: Codable, Sendable, Equatable {
    public var x: Double; public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public func distance(to other: Self) -> Double { hypot(x-other.x,y-other.y) }
}
public struct ChemicalAtomID: Hashable, Sendable {
    public let molecule: String; public let index: Int
    public init(_ molecule: String, _ index: Int) { self.molecule = molecule; self.index = index }
}
public struct ChemicalDrawAtom: Sendable {
    public let id: ChemicalAtomID; public let label: String; public let point: ChemicalPoint
    public let charge: Int; public let isotope: Int; public let raw: JSONValue
}
public struct ChemicalDrawBond: Sendable {
    public let molecule: String; public let index: Int
    public let a: ChemicalAtomID; public let b: ChemicalAtomID; public let order: Int; public let stereo: Int
}
public struct ChemicalAnnotation: Sendable {
    public enum Kind: Sendable { case arrow, plus, text, other }
    public let index: Int; public let kind: Kind; public let point: ChemicalPoint; public let end: ChemicalPoint?; public let text: String
}

/// Native editable projection of KET. Unrecognized fields and nodes remain in the
/// authoritative document; edits that require unknown index remapping fail explicitly.
public struct ChemicalDrawing2D: Sendable, Equatable {
    public private(set) var value: JSONValue
    private var top: [String: JSONValue] { value.dictionary ?? [:] }
    public var nodes: [JSONValue] { value["root"]?["nodes"]?.array ?? [] }
    public var moleculeKeys: [String] { nodes.compactMap { $0["$ref"]?.string }.filter { value[$0]?["type"]?.string == "molecule" } }
    public init(_ source: String = "{\"ket_version\":\"2.0.0\",\"root\":{\"nodes\":[]}}") throws {
        guard source.utf8.count <= 16 * 1024 * 1024 else { throw ChemistryError.invalid("Drawing exceeds its size limit.") }
        value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        guard value.dictionary != nil, value["root"]?["nodes"]?.array != nil else { throw ChemistryError.invalid("A KET drawing is required.") }
        for key in moleculeKeys {
            guard let list = value[key]?["atoms"]?.array else {throw ChemistryError.invalid("A molecule is missing its atoms.")}
            for atom in list {
                guard let p = atom["location"]?.array,p.count >= 2,p[0].number != nil,p[1].number != nil,
                      atom["charge"] == nil || atom["charge"]?.number.boundedInt != nil,
                      atom["isotope"] == nil || atom["isotope"]?.number.boundedInt != nil else {throw ChemistryError.invalid("Invalid drawing atom attributes.")}
            }
            for bond in value[key]?["bonds"]?.array ?? [] {
                guard let type = bond["type"]?.number.boundedInt,(1...10).contains(type),
                      bond["atoms"]?.array?.count == 2 else {throw ChemistryError.invalid("Invalid drawing bond attributes.")}
            }
        }
        let atoms = self.atoms
        guard atoms.count <= 100000, atoms.allSatisfy({ $0.point.x.isFinite && $0.point.y.isFinite && abs($0.point.x) <= 1e6 && abs($0.point.y) <= 1e6 }),
              moleculeKeys.count == Set(moleculeKeys).count else { throw ChemistryError.invalid("Invalid or oversized drawing geometry.") }
        let ids = Set(atoms.map(\.id))
        for bond in bonds { guard ids.contains(bond.a), ids.contains(bond.b) else { throw ChemistryError.invalid("Drawing bond refers to a missing atom.") } }
        guard annotations.flatMap({ [$0.point]+($0.end.map {[$0]} ?? []) }).allSatisfy({$0.x.isFinite && $0.y.isFinite && max(abs($0.x),abs($0.y)) < 1e6}) else {throw ChemistryError.invalid("Invalid annotation coordinates.")}
    }
    public func encoded() throws -> String { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return String(decoding: try e.encode(value), as: UTF8.self) }
    public var atoms: [ChemicalDrawAtom] {
        moleculeKeys.flatMap { key in
            (value[key]?["atoms"]?.array ?? []).enumerated().compactMap { i,a in
                guard let location = a["location"]?.array, location.count >= 2, let x = location[0].number, let y = location[1].number else { return nil }
                return ChemicalDrawAtom(id: ChemicalAtomID(key,i), label: a["label"]?.string ?? "?", point: ChemicalPoint(x,y), charge: a["charge"]?.number.boundedInt ?? 0, isotope: a["isotope"]?.number.boundedInt ?? 0, raw: a)
            }
        }
    }
    public var bonds: [ChemicalDrawBond] {
        moleculeKeys.flatMap { key in
            (value[key]?["bonds"]?.array ?? []).enumerated().compactMap { i,b in
                guard let refs = b["atoms"]?.array, refs.count == 2, let a = refs[0].number, let end = refs[1].number,
                      a >= 0, end >= 0, a.rounded() == a, end.rounded() == end, a < 100000, end < 100000 else { return nil }
                return ChemicalDrawBond(molecule: key, index: i, a: ChemicalAtomID(key,Int(a)), b: ChemicalAtomID(key,Int(end)), order: b["type"]?.number.boundedInt ?? 1, stereo: b["stereo"]?.number.boundedInt ?? 0)
            }
        }
    }
    public var annotations: [ChemicalAnnotation] {
        nodes.enumerated().compactMap { index,n in
            guard n["$ref"] == nil else { return nil }
            let type = n["type"]?.string ?? "other", data = n["data"] ?? n
            let pos = data["pos"]?.array
            let start = data["position"] ?? pos?.first ?? n["position"]
            let location = n["location"]?.array
            let point = ChemicalPoint(start?["x"]?.number ?? location?.first?.number ?? n["boundingBox"]?["x"]?.number ?? 0, start?["y"]?.number ?? ((location?.count ?? 0) > 1 ? location?[1].number : nil) ?? n["boundingBox"]?["y"]?.number ?? 0)
            let end = pos?.last.map { ChemicalPoint($0["x"]?.number ?? point.x,$0["y"]?.number ?? point.y) }
            var text = ""
            if let content = data["content"]?.string, let json = try? JSONDecoder().decode(JSONValue.self, from: Data(content.utf8)) {
                text = json["blocks"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
            }
            if text.isEmpty { text = n["paragraphs"]?.array?.compactMap { $0["text"]?.string ?? $0["runs"]?.array?.compactMap { $0["text"]?.string }.joined() }.joined(separator: "\n") ?? "" }
            return ChemicalAnnotation(index: index, kind: type == "arrow" ? .arrow : (type == "plus" ? .plus : (type == "text" ? .text : .other)), point: point, end: end, text: text)
        }
    }
    private mutating func setNode(_ key: String, _ node: [String: JSONValue]) { var t = top; t[key] = .object(node); value = .object(t) }
    private mutating func setNodes(_ nodes: [JSONValue]) { var t = top, root = value["root"]?.dictionary ?? [:]; root["nodes"] = .array(nodes); t["root"] = .object(root); value = .object(t) }
    private mutating func makeMolecule() -> String {
        var index = 0; while top["mol\(index)"] != nil { index += 1 }
        let key = "mol\(index)"; setNode(key,["type":.string("molecule"),"atoms":.array([]),"bonds":.array([])])
        setNodes(nodes + [.object(["$ref":.string(key)])]); return key
    }
    @discardableResult public mutating func addAtom(_ label: String, at point: ChemicalPoint, molecule: String? = nil) throws -> ChemicalAtomID {
        guard atoms.count < 10000, (try? ChemicalFormula(label))?.elements == [label:1], point.x.isFinite, point.y.isFinite, max(abs(point.x),abs(point.y)) < 1e6 else { throw ChemistryError.invalid("Invalid atom or position.") }
        let key: String
        if let molecule, moleculeKeys.contains(molecule) { key = molecule } else { key = makeMolecule() }
        var node = top[key]?.dictionary ?? [:], list = node["atoms"]?.array ?? []
        let id = ChemicalAtomID(key,list.count)
        list.append(.object(["label":.string(label),"location":.array([.number(point.x),.number(point.y),.number(0)])]))
        node["atoms"] = .array(list); setNode(key,node); return id
    }
    public mutating func updateAtom(_ id: ChemicalAtomID, label: String? = nil, charge: Int? = nil, isotope: Int? = nil, point: ChemicalPoint? = nil) throws {
        guard var node = top[id.molecule]?.dictionary, var list = node["atoms"]?.array, list.indices.contains(id.index), var atom = list[id.index].dictionary else { throw ChemistryError.invalid("Atom not found.") }
        if let label { guard (try? ChemicalFormula(label))?.elements == [label:1] else { throw ChemistryError.invalid("Unknown element.") }; atom["label"] = .string(label) }
        if let charge { guard (-8...8).contains(charge) else { throw ChemistryError.invalid("Charge is outside the editor range.") }; atom["charge"] = .number(Double(charge)) }
        if let isotope { guard (0...300).contains(isotope) else { throw ChemistryError.invalid("Invalid isotope.") }; atom["isotope"] = isotope == 0 ? nil : .number(Double(isotope)) }
        if let point { guard point.x.isFinite, point.y.isFinite, max(abs(point.x),abs(point.y)) < 1e6 else { throw ChemistryError.invalid("Invalid atom position.") }; atom["location"] = .array([.number(point.x),.number(point.y),.number(0)]) }
        list[id.index] = .object(atom); node["atoms"] = .array(list); setNode(id.molecule,node)
    }
    private func remappingAllowed(_ node: [String: JSONValue]) -> Bool {
        Set(node.keys).isSubset(of: ["type","atoms","bonds","stereoFlagPosition","stereoFlag"])
    }
    @discardableResult public mutating func addBond(_ a: ChemicalAtomID, _ b: ChemicalAtomID, order: Int = 1, stereo: Int = 0) throws -> ChemicalDrawBond {
        guard (1...4).contains(order), [0,1,4,6].contains(stereo), a != b, atoms.contains(where: { $0.id == a }), atoms.contains(where: { $0.id == b }) else { throw ChemistryError.invalid("Invalid chemical bond.") }
        var end = b
        if a.molecule != b.molecule {
            guard var left = top[a.molecule]?.dictionary, let right = top[b.molecule]?.dictionary, remappingAllowed(left), remappingAllowed(right) else { throw ChemistryError.unavailable("This connection requires remapping a group. The complete drawing is retained.") }
            let offset = left["atoms"]?.array?.count ?? 0
            left["atoms"] = .array((left["atoms"]?.array ?? []) + (right["atoms"]?.array ?? []))
            let shifted = (right["bonds"]?.array ?? []).map { value -> JSONValue in var bond = value.dictionary ?? [:]; bond["atoms"] = .array((value["atoms"]?.array ?? []).map { .number(($0.number ?? 0)+Double(offset)) }); return .object(bond) }
            left["bonds"] = .array((left["bonds"]?.array ?? [])+shifted); setNode(a.molecule,left)
            var t = top; t.removeValue(forKey:b.molecule); value = .object(t); setNodes(nodes.filter { $0["$ref"]?.string != b.molecule })
            end = ChemicalAtomID(a.molecule,b.index+offset)
        }
        guard !bonds.contains(where: { ($0.a == a && $0.b == end) || ($0.a == end && $0.b == a) }) else { throw ChemistryError.invalid("A bond already connects these atoms.") }
        var node = top[a.molecule]?.dictionary ?? [:], list = node["bonds"]?.array ?? []
        let index = list.count
        list.append(.object(["type":.number(Double(order)),"atoms":.array([.number(Double(a.index)),.number(Double(end.index))]),"stereo":.number(Double(stereo))]))
        node["bonds"] = .array(list); setNode(a.molecule,node)
        return ChemicalDrawBond(molecule:a.molecule,index:index,a:a,b:end,order:order,stereo:stereo)
    }
    public mutating func updateBond(_ bond: ChemicalDrawBond, order: Int, stereo: Int = 0, reverse: Bool = false) throws {
        guard (1...4).contains(order), [0,1,4,6].contains(stereo), var node = top[bond.molecule]?.dictionary, var list = node["bonds"]?.array, list.indices.contains(bond.index), var item = list[bond.index].dictionary else { throw ChemistryError.invalid("Bond not found.") }
        item["type"] = .number(Double(order)); item["stereo"] = .number(Double(stereo))
        if reverse { item["atoms"] = .array((item["atoms"]?.array ?? []).reversed()) }
        list[bond.index] = .object(item); node["bonds"] = .array(list); setNode(bond.molecule,node)
    }
    public mutating func removeAtom(_ id: ChemicalAtomID) throws {
        guard var node = top[id.molecule]?.dictionary, remappingAllowed(node), var list = node["atoms"]?.array, list.indices.contains(id.index) else { throw ChemistryError.unavailable("This atom belongs to a group with additional references. The drawing is retained.") }
        list.remove(at:id.index)
        let bonds = (node["bonds"]?.array ?? []).compactMap { value -> JSONValue? in
            let refs = (value["atoms"]?.array ?? []).compactMap(\.number).map(Int.init)
            if refs.contains(id.index) { return nil }
            var bond = value.dictionary ?? [:]; bond["atoms"] = .array(refs.map { .number(Double($0 > id.index ? $0-1 : $0)) }); return .object(bond)
        }
        node["atoms"] = .array(list); node["bonds"] = .array(bonds); setNode(id.molecule,node)
    }
    public mutating func removeBond(_ bond: ChemicalDrawBond) throws {
        guard var node = top[bond.molecule]?.dictionary, remappingAllowed(node), var list = node["bonds"]?.array, list.indices.contains(bond.index) else { throw ChemistryError.unavailable("This bond has additional group references. The drawing is retained.") }
        list.remove(at:bond.index); node["bonds"] = .array(list); setNode(bond.molecule,node)
    }
    public mutating func addRing(size: Int, aromatic: Bool = false, center: ChemicalPoint) throws {
        guard (3...8).contains(size), !aromatic || size == 6, center.x.isFinite, center.y.isFinite,
              max(abs(center.x),abs(center.y)) < 999990 else { throw ChemistryError.invalid("Unsupported ring template or position.") }
        let key = makeMolecule(), radius = 1.5/(2*sin(.pi/Double(size)))
        var ids: [ChemicalAtomID] = []
        for i in 0..<size { let angle = 2 * .pi * Double(i)/Double(size) + .pi/6; ids.append(try addAtom("C",at:ChemicalPoint(center.x+radius*cos(angle),center.y+radius*sin(angle)),molecule:key)) }
        for i in 0..<size { _ = try addBond(ids[i],ids[(i+1)%size],order:aromatic && i%2 == 0 ? 2 : 1) }
    }
    public mutating func addArrow(from start: ChemicalPoint, to end: ChemicalPoint) {
        func p(_ value: ChemicalPoint) -> JSONValue { .object(["x":.number(value.x),"y":.number(value.y),"z":.number(0)]) }
        setNodes(nodes + [.object(["type":.string("arrow"),"data":.object(["mode":.string("open-angle"),"pos":.array([p(start),p(end)])])])])
    }
    public mutating func addReactionPlus(at point:ChemicalPoint) {setNodes(nodes+[.object(["type":.string("plus"),"location":.array([.number(point.x),.number(point.y),.number(0)])])])}
    public mutating func addText(_ text: String, at point: ChemicalPoint) throws {
        guard text.utf8.count <= 4096 else { throw ChemistryError.invalid("Text exceeds its size limit.") }
        let content: JSONValue = .object(["blocks":.array([.object(["key":.string("floe"),"text":.string(text),"type":.string("unstyled"),"depth":.number(0),"inlineStyleRanges":.array([]),"entityRanges":.array([]),"data":.object([:])])]),"entityMap":.object([:])])
        let encoded = String(decoding:try JSONEncoder().encode(content),as:UTF8.self)
        setNodes(nodes + [.object(["type":.string("text"),"data":.object(["content":.string(encoded),"position":.object(["x":.number(point.x),"y":.number(point.y),"z":.number(0)])])])])
    }
    public mutating func removeAnnotation(at index: Int) { var list = nodes; if list.indices.contains(index) && list[index]["$ref"] == nil { list.remove(at:index); setNodes(list) } }
    public mutating func insert(_ fragment:Self) throws {
        guard fragment.moleculeKeys.allSatisfy({ remappingAllowed(fragment.top[$0]?.dictionary ?? [:]) }),
              Set(fragment.value["root"]?.dictionary?.keys.map {$0} ?? []).isSubset(of:["nodes","connections","templates"]),
              (fragment.value["root"]?["connections"]?.array ?? []).isEmpty,
              (fragment.value["root"]?["templates"]?.array ?? []).isEmpty,
              fragment.annotations.allSatisfy({if case .other = $0.kind {false}else{true}}) else {
            throw ChemistryError.unavailable("Import this grouped structure as a separate object to preserve its references.")
        }
        let left = atoms.map(\.point),right = fragment.atoms.map(\.point)
        let dx = left.isEmpty ? 0 : (left.map(\.x).max() ?? 0)-(right.map(\.x).min() ?? 0)+3
        var mapping:[String:String] = [:]
        for key in fragment.top.keys where key != "root" && key != "ket_version" {
            var index = 0;while top["paste\(index)_\(key)"] != nil || mapping.values.contains("paste\(index)_\(key)") {index += 1};mapping[key] = "paste\(index)_\(key)"
        }
        func rewrite(_ input:JSONValue) -> JSONValue {
            switch input {
            case .array(let list):return .array(list.map(rewrite))
            case .object(let dict):return .object(dict.mapValues(rewrite).mapReferences(mapping))
            default:return input
            }
        }
        var result = self,t = result.top
        for (key,newKey) in mapping {
            let rewritten = rewrite(fragment.top[key] ?? .null)
            guard var node = rewritten.dictionary else {t[newKey] = rewritten;continue}
            if node["type"]?.string == "molecule" {
                node["atoms"] = .array((node["atoms"]?.array ?? []).map {value in var atom = value.dictionary ?? [:];var p = atom["location"]?.array ?? [];if p.count >= 2 {p[0] = .number((p[0].number ?? 0)+dx)};atom["location"] = .array(p);return .object(atom)})
                if var flag = node["stereoFlagPosition"]?.dictionary {flag["x"] = .number((flag["x"]?.number ?? 0)+dx);node["stereoFlagPosition"] = .object(flag)}
            }
            t[newKey] = .object(node)
        }
        result.value = .object(t)
        let incoming = fragment.nodes.map {value -> JSONValue in
            let updated = rewrite(value)
            guard updated["$ref"] == nil else{return updated}
            var node = updated.dictionary ?? [:]
            if var location = node["location"]?.array,location.count >= 2 {location[0] = .number((location[0].number ?? 0)+dx);node["location"] = .array(location)}
            if var data = node["data"]?.dictionary {
                if let pos = data["pos"]?.array {data["pos"] = .array(pos.map {value in var p = value.dictionary ?? [:];p["x"] = .number((p["x"]?.number ?? 0)+dx);return .object(p)})}
                if var p = data["position"]?.dictionary {p["x"] = .number((p["x"]?.number ?? 0)+dx);data["position"] = .object(p)}
                node["data"] = .object(data)
            }
            if var box = node["boundingBox"]?.dictionary {box["x"] = .number((box["x"]?.number ?? 0)+dx);node["boundingBox"] = .object(box)}
            return .object(node)
        }
        result.setNodes(nodes+incoming)
        self = try Self(result.encoded())
    }
}

private extension JSONValue { var dictionary: [String:JSONValue]? { if case .object(let v) = self { v } else { nil } } }
private extension Optional where Wrapped == Double {
    var boundedInt: Int? { guard let self, self.isFinite, self.rounded() == self, abs(self) < 1_000_000 else { return nil }; return Int(self) }
}
private extension Dictionary where Key == String,Value == JSONValue {
    func mapReferences(_ mapping:[String:String]) -> Self {var output = self;if let old = self["$ref"]?.string,let new = mapping[old] {output["$ref"] = .string(new)};return output}
}
