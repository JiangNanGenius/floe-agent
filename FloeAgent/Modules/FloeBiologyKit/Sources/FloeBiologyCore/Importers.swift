// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation

public enum BiologyImporter {
    public static let maximumInputBytes = 16 * 1024 * 1024
    public static func parse(title: String, format: String, data: Data) throws -> BiologyAsset {
        guard !data.isEmpty, data.count <= maximumInputBytes else { throw BiologyError.invalid("Input is empty or exceeds 16 MiB. Use a configured compute environment for larger data.") }
        let format = format.lowercased()
        var warnings: [String] = []
        let payload: BiologyAssetPayload
        switch format {
        case "fa", "fasta", "fna", "faa":
            var records=try sequences(text(data),format:"fasta")
            if format=="faa" {for i in records.indices {records[i].alphabet="protein"}}
            payload = .sequence(records)
        case "fastq", "fq": payload = .sequence(try sequences(text(data), format: "fastq"))
        case "gb", "gbk", "genbank":
            let result = try genbank(text(data)); payload = .sequence(result.0); warnings = result.1
        case "pdb": payload = .proteinStructure(try pdb(text(data)))
        case "cif", "mmcif": payload = .proteinStructure(try cif(text(data)))
        case "pgm": payload = .microscopyImage(try pgm(data))
        case "csv", "tsv": payload = .expressionMatrix(try matrix(text(data), delimiter: format == "csv" ? "," : "\t"))
        case "json", "image.json", "network.json":
            if let typed=try? JSONDecoder().decode(BiologyAssetPayload.self,from:data) {
                return BiologyAsset(title:title,payload:typed,originalData:data,originalFormat:format)
            }
            let object = try JSONSerialization.jsonObject(with: data)
            guard let d = object as? [String: Any] else { throw BiologyError.invalid("Expected a structured dataset.") }
            if d["species"] != nil {
                let network = try JSONDecoder().decode(BiochemicalNetwork.self, from: data); try network.validate(); payload = .biochemicalNetwork(network)
            } else {
                payload = .microscopyImage(try imageJSON(d))
            }
        case "h5ad", "mtx", "sbml", "xml", "tif", "tiff":
            payload = .externalDataset(format)
            warnings = ["Original preserved. Reading this format requires its configured scientific backend."]
        default: throw BiologyError.unavailable("This file format needs a configured scientific importer.")
        }
        var asset = BiologyAsset(title: title, payload: payload, originalData: data, originalFormat: format)
        asset.warnings = warnings
        return asset
    }
    private static func text(_ data: Data) throws -> String {
        guard let s = String(data: data, encoding: .utf8) else { throw BiologyError.invalid("The input is not UTF-8 text.") }; return s
    }
    public static func sequences(_ text: String, format: String) throws -> [SequenceRecord] {
        var result: [SequenceRecord] = []
        if format == "fastq" {
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.count % 4 == 0 else { throw BiologyError.invalid("FASTQ records must contain matching sequence and quality lines.") }
            for i in stride(from: 0, to: lines.count, by: 4) {
                guard lines[i].hasPrefix("@"), lines[i+2].hasPrefix("+"), lines[i+1].utf8.count == lines[i+3].utf8.count,
                      lines[i+3].utf8.allSatisfy({ (33...126).contains($0) }) else { throw BiologyError.invalid("Invalid FASTQ header, sequence or quality length.") }
                var r = SequenceRecord(name: String(lines[i].dropFirst()), sequence: lines[i+1].uppercased())
                r.quality = lines[i+3]; result.append(r)
            }
        } else {
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix(">") {
                    result.append(.init(name: String(line.dropFirst()), sequence: ""))
                } else {
                    guard !result.isEmpty else { throw BiologyError.invalid("FASTA needs a >header before its sequence.") }
                    result[result.count-1].sequence += line.filter { !$0.isWhitespace }.uppercased()
                }
            }
        }
        guard !result.isEmpty, result.count <= 256 else { throw BiologyError.invalid("Invalid number of sequence records.") }
        for i in result.indices {
            try validateSequence(result[i].sequence)
            guard !result[i].name.isEmpty, result[i].name.utf8.count <= 4096 else { throw BiologyError.invalid("Invalid sequence name.") }
            let letters = Set(result[i].sequence)
            result[i].alphabet = letters.isSubset(of: Set("ACGTRYSWKMBDHVN-")) ? "dna" : letters.isSubset(of: Set("ACGURYSWKMBDHVN-")) ? "rna" : "protein"
        }
        return result
    }
    public static func validateSequence(_ s: String) throws {
        guard !s.isEmpty, s.utf8.count <= 2_000_000, s.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZ*-".contains($0) }) else { throw BiologyError.invalid("Invalid sequence symbols or size.") }
    }
    private static func genbank(_ text: String) throws -> ([SequenceRecord], [String]) {
        var records: [SequenceRecord] = [], warnings: [String] = []
        let pattern = try NSRegularExpression(pattern: #"^\s{5}([a-zA-Z_]+)\s+(complement\()?([0-9]+)\.\.([0-9]+)\)?\s*$"#)
        for record in text.components(separatedBy: "//") where record.contains("ORIGIN") {
            let parts = record.components(separatedBy: "ORIGIN")
            guard parts.count == 2, let locus = parts[0].split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("LOCUS") }) else { throw BiologyError.invalid("Malformed GenBank record.") }
            let fields = locus.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { throw BiologyError.invalid("GenBank LOCUS is incomplete.") }
            let seq = parts[1].filter(\.isLetter).uppercased()
            try validateSequence(seq)
            var item = SequenceRecord(name: String(fields[1]), sequence: seq)
            var feature: Int?
            for raw in parts[0].components(separatedBy: .newlines) {
                if let m = pattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                   let typeRange = Range(m.range(at: 1), in: raw), let lo = Range(m.range(at: 3), in: raw), let hi = Range(m.range(at: 4), in: raw),
                   let start = Int(raw[lo]), let end = Int(raw[hi]), start > 0, end <= seq.count, end >= start {
                    item.annotations.append(.init(name: String(raw[typeRange]), start: start-1, end: end, strand: m.range(at: 2).location == NSNotFound ? 1 : -1))
                    feature = item.annotations.count-1
                } else if raw.hasPrefix("     "), !raw.hasPrefix("                     "), raw.count > 5, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    if raw.contains("join(") || raw.contains("order(") || raw.contains("<") || raw.contains(">") {
                        warnings.append("Complex or fuzzy feature locations are preserved in the original, with no editable approximation."); feature = nil
                    }
                } else if let feature, raw.trimmingCharacters(in: .whitespaces).hasPrefix("/") {
                    let q = raw.trimmingCharacters(in: .whitespaces).dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if let key = q.first { item.annotations[feature].qualifiers[String(key), default: []].append(q.count == 2 ? String(q[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : "") }
                }
            }
            if parts[0].contains("FEATURES") { warnings.append("Native GenBank editing supports simple ranges; the exact original retains all metadata and multiline qualifiers.") }
            records.append(item)
        }
        guard !records.isEmpty, records.count <= 256 else { throw BiologyError.invalid("GenBank has no usable sequence record.") }
        return (records, Array(Set(warnings)).sorted())
    }
    public static func fasta(_ records: [SequenceRecord]) -> String {
        records.map { r in ">" + r.name + "\n" + stride(from: 0, to: r.sequence.count, by: 80).map { offset in
            let start = r.sequence.index(r.sequence.startIndex, offsetBy: offset)
            return String(r.sequence[start..<r.sequence.index(start, offsetBy: min(80, r.sequence.count-offset))])
        }.joined(separator: "\n") }.joined(separator: "\n") + "\n"
    }
    public static func pdb(_ text: String) throws -> ProteinStructure {
        func field(_ bytes: [UInt8], _ a: Int, _ b: Int) -> String { String(decoding: bytes[min(a,bytes.count)..<min(b,bytes.count)], as: UTF8.self).trimmingCharacters(in: .whitespaces) }
        var atoms: [StructureAtom] = [], best: [String: Int] = [:], model = 1
        for line in text.split(whereSeparator: \.isNewline) {
            let b = Array(line.utf8)
            if line.hasPrefix("MODEL ") { model = Int(field(b,10,14)) ?? (model+1); continue }
            guard line.hasPrefix("ATOM  ") || line.hasPrefix("HETATM") else { continue }
            guard b.count >= 54, let serial = Int(field(b,6,11)), let n = Int(field(b,22,26)),
                  let x = Double(field(b,30,38)), let y = Double(field(b,38,46)), let z = Double(field(b,46,54)),
                  [x,y,z].allSatisfy({ $0.isFinite && abs($0) <= 1e7 }), atoms.count < 100_000 else { throw BiologyError.invalid("Malformed or oversized PDB atom records.") }
            let name = field(b,12,16), chain = field(b,21,22), ins = field(b,26,27), occupancy = Double(field(b,54,60)) ?? 1
            guard occupancy.isFinite, occupancy >= 0 else { throw BiologyError.invalid("Invalid PDB occupancy.") }
            let element = field(b,76,78).isEmpty ? String(name.filter(\.isLetter).prefix(1)) : field(b,76,78)
            var atom = StructureAtom(id: atoms.count, serial: serial, name: name, element: element, chain: chain, residue: field(b,17,20), residueNumber: n, insertionCode: ins, model: model, x: x,y: y,z: z,occupancy: occupancy,hetero: line.hasPrefix("HETATM"))
            let key = "\(atom.residueID):\(name):\(atom.hetero)"
            if let index = best[key] {
                if occupancy > atoms[index].occupancy { atom.id = atoms[index].id; atoms[index] = atom }
            } else { best[key] = atoms.count; atoms.append(atom) }
        }
        guard !atoms.isEmpty else { throw BiologyError.invalid("PDB contains no atom coordinates.") }
        return .init(atoms: atoms, title: "PDB structure")
    }
    private struct CIFToken { let value: String; let control: Bool }
    private static func cifTokens(_ text: String) throws -> [CIFToken] {
        let b = Array(text.utf8); var i = 0, tokens: [CIFToken] = []
        func space(_ x: UInt8) -> Bool { x == 9 || x == 10 || x == 13 || x == 32 }
        while i < b.count {
            if space(b[i]) { i += 1; continue }
            if b[i] == 35 { while i < b.count && b[i] != 10 { i += 1 }; continue }
            let start: Int; let end: Int; let control: Bool
            if b[i] == 59 && (i == 0 || b[i-1] == 10) {
                i += 1; start = i
                while i < b.count && !(b[i] == 59 && b[i-1] == 10) { i += 1 }
                guard i < b.count else { throw BiologyError.invalid("Unterminated CIF multiline value.") }
                end = i; i += 1; control = false
            } else if b[i] == 39 || b[i] == 34 {
                let quote = b[i]; i += 1; start = i
                while i < b.count && !(b[i] == quote && (i+1 == b.count || space(b[i+1]))) { i += 1 }
                guard i < b.count else { throw BiologyError.invalid("Unterminated CIF quoted value.") }
                end = i; i += 1; control = false
            } else {
                start = i; while i < b.count && !space(b[i]) { i += 1 }; end = i; control = true
            }
            tokens.append(.init(value: String(decoding: b[start..<end], as: UTF8.self), control: control))
            if tokens.count > 2_000_000 { throw BiologyError.invalid("CIF token budget exceeded.") }
        }
        return tokens
    }
    public static func cif(_ text: String) throws -> ProteinStructure {
        let tokens = try cifTokens(text); var i = 0
        while i < tokens.count {
            guard tokens[i].control && tokens[i].value == "loop_" else { i += 1; continue }; i += 1
            var fields: [String] = []
            while i < tokens.count && tokens[i].control && tokens[i].value.hasPrefix("_") { fields.append(tokens[i].value); i += 1 }
            guard !fields.isEmpty else { throw BiologyError.invalid("CIF loop has no fields.") }
            var values: [String] = []
            while i < tokens.count {
                let t = tokens[i]
                if values.count % fields.count == 0 && t.control && (t.value.hasPrefix("_") || t.value == "loop_" || t.value == "stop_" || t.value.hasPrefix("data_") || t.value.hasPrefix("save_")) { break }
                values.append(t.value); i += 1
            }
            guard values.count % fields.count == 0 else { throw BiologyError.invalid("CIF loop row is incomplete.") }
            guard fields.contains("_atom_site.Cartn_x") else { continue }
            guard Set(fields).count == fields.count else { throw BiologyError.invalid("CIF loop contains duplicate fields.") }
            let indices = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element,$0.offset) })
            var atoms: [StructureAtom] = [], best: [String: Int] = [:]
            for offset in stride(from: 0,to: values.count,by: fields.count) {
                func value(_ names: String..., fallback: String = "") -> String {
                    for n in names { if let k = indices["_atom_site."+n] { let v = values[offset+k]; if v != "." && v != "?" { return v } } }; return fallback
                }
                guard let x = Double(value("Cartn_x")), let y = Double(value("Cartn_y")), let z = Double(value("Cartn_z")), [x,y,z].allSatisfy({ $0.isFinite && abs($0) < 1e7 }), atoms.count < 100_000 else { throw BiologyError.invalid("Invalid or oversized CIF coordinate loop.") }
                var atom = StructureAtom(id: atoms.count, serial: Int(value("id")) ?? atoms.count+1, name: value("auth_atom_id","label_atom_id"), element: value("type_symbol"), chain: value("auth_asym_id","label_asym_id"), residue: value("auth_comp_id","label_comp_id"), residueNumber: Int(value("auth_seq_id","label_seq_id")) ?? 0, insertionCode: value("pdbx_PDB_ins_code"), model: Int(value("pdbx_PDB_model_num")) ?? 1, x:x,y:y,z:z,occupancy:Double(value("occupancy", fallback:"1")) ?? 1,hetero:value("group_PDB") == "HETATM")
                guard atom.occupancy.isFinite && atom.occupancy >= 0 else { throw BiologyError.invalid("Invalid CIF occupancy.") }
                let key = "\(atom.residueID):\(atom.name):\(atom.hetero)"
                if let k = best[key] { if atom.occupancy > atoms[k].occupancy { atom.id = atoms[k].id; atoms[k] = atom } }
                else { best[key] = atoms.count; atoms.append(atom) }
            }
            guard !atoms.isEmpty else { throw BiologyError.invalid("CIF has no coordinates.") }
            return .init(atoms:atoms,title:"mmCIF structure")
        }
        throw BiologyError.invalid("This CIF has no atom_site coordinate loop.")
    }
    public static func matrix(_ text: String, delimiter: Character) throws -> ExpressionMatrix {
        let rows = try delimited(text, delimiter: delimiter)
        guard let header = rows.first, header.count >= 2, rows.count >= 2 else { throw BiologyError.invalid("A matrix needs gene rows and cell columns.") }
        var ids: [String] = [], values: [Double] = []
        guard (rows.count-1) <= 2_000_000 / (header.count-1) else { throw BiologyError.invalid("Matrix exceeds the native size budget.") }
        for row in rows.dropFirst() {
            guard row.count == header.count else { throw BiologyError.invalid("Matrix row length differs from its header.") }
            ids.append(row[0])
            for value in row.dropFirst() { guard let n = Double(value), n.isFinite, n >= 0 else { throw BiologyError.invalid("Count matrix requires finite nonnegative numbers.") }; values.append(n) }
        }
        let result = ExpressionMatrix(geneIDs:ids,cellIDs:Array(header.dropFirst()),values:values); try result.validate(); return result
    }
    private static func delimited(_ text: String, delimiter: Character) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(text); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i+1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if !quoted && c == delimiter { row.append(field); field = "" }
            else if !quoted && (c == "\n" || c == "\r\n" || c == "\r") { row.append(field); if row != [""] { rows.append(row) }; row = []; field = "" }
            else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw BiologyError.invalid("Unterminated quoted matrix field.") }
        if !row.isEmpty || !field.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
    public static func imageJSON(_ d: [String:Any]) throws -> MicroscopyImage {
        func integer(_ key: String, fallback: Int = 1) throws -> Int {
            guard let v = d[key] else { return fallback }
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue, (1...4_194_304).contains(n.intValue) else { throw BiologyError.invalid("Invalid image dimension.") }; return n.intValue
        }
        let width = try integer("width"), height = try integer("height")
        let channels = try integer("channels"), slices = try integer("slices",fallback: (d["z"] as? Int) ?? 1), frames = try integer("frames",fallback:(d["time"] as? Int) ?? 1)
        guard Double(width)*Double(height)*Double(channels)*Double(slices)*Double(frames) <= 4_194_304,
              let raw = (d["samples"] ?? d["pixels"]) as? [NSNumber],
              raw.count == width*height*channels*slices*frames,
              raw.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite }) else { throw BiologyError.invalid("Image samples do not match its axes or budget.") }
        var image = MicroscopyImage(width:width,height:height,samples:raw.map(\.doubleValue))
        image.channels = channels; image.slices = slices; image.frames = frames; image.bitDepth = try integer("bitDepth",fallback:16)
        image.pixelSizeX = (d["pixelSizeX"] ?? d["pixelSizeMicrometers"]) as? Double
        image.pixelSizeY = (d["pixelSizeY"] ?? d["pixelSizeMicrometers"]) as? Double
        image.calibrationUnit = d["calibrationUnit"] as? String ?? "µm"; try image.validate(); return image
    }
    public static func pgm(_ data: Data) throws -> MicroscopyImage {
        let bytes = [UInt8](data); var i = 0
        func whitespace(_ b: UInt8) -> Bool { b == 10 || b == 13 || b == 9 || b == 32 }
        func token() -> String {
            while i < bytes.count {
                if whitespace(bytes[i]) { i += 1 }
                else if bytes[i] == 35 { while i < bytes.count && bytes[i] != 10 { i += 1 } }
                else { break }
            }
            let start = i; while i < bytes.count && !whitespace(bytes[i]) { i += 1 }
            return String(decoding: bytes[start..<i],as:UTF8.self)
        }
        let magic = token()
        guard ["P2","P5"].contains(magic), let width = Int(token()), let height = Int(token()), let maximum = Int(token()),
              width > 0,height > 0,width <= 16384,height <= 16384,width <= 4_194_304/height,(1...65535).contains(maximum) else { throw BiologyError.invalid("Invalid or oversized PGM image.") }
        let count = width*height; var values: [Double] = []
        if magic == "P2" {
            for _ in 0..<count { guard let n = Int(token()), (0...maximum).contains(n) else { throw BiologyError.invalid("PGM pixels are invalid.") }; values.append(Double(n)) }
            guard token().isEmpty else { throw BiologyError.invalid("PGM has extra pixels.") }
        } else {
            guard i < bytes.count && whitespace(bytes[i]) else { throw BiologyError.invalid("PGM raster delimiter is missing.") }
            if bytes[i] == 13 && i+1 < bytes.count && bytes[i+1] == 10 { i += 2 } else { i += 1 }
            let size = maximum > 255 ? 2 : 1
            guard bytes.count-i == count*size else { throw BiologyError.invalid("PGM raster size does not match its dimensions.") }
            values = (0..<count).map { j in size == 2 ? Double(Int(bytes[i+j*2])*256+Int(bytes[i+j*2+1])) : Double(bytes[i+j]) }
            guard values.allSatisfy({ $0 <= Double(maximum) }) else { throw BiologyError.invalid("PGM pixel exceeds MAXVAL.") }
        }
        var image = MicroscopyImage(width:width,height:height,samples:values); image.bitDepth = maximum > 255 ? 16 : 8; try image.validate(); return image
    }
}
