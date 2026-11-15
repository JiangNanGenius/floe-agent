// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

private struct Binding: Decodable {
    let category: String
    let family: String
    let name: String
    let symbolIdentifier: String
    let footprintIdentifier: String
    let footprintPath: String?
    let bindingSource: String
    let symbolPaths: [String]
    let sourceError: String?
}
private struct Bindings: Decodable { let schemaVersion: Int; let version: String; let bindings: [Binding] }
private struct SourceLock: Decodable {
    struct File: Decodable { let path: String; let revision: String; let url: String; let bytes: Int; let sha256: String }
    let schemaVersion: Int
    let files: [File]
}
private struct Entry: Encodable {
    let id: String
    let name: String
    let category: String
    let status: String
    let sourceIdentifier: String
    let footprintIdentifier: String
    let pinCount: Int?
    let padNumbers: [String]?
    let notices: [EDALibraryNotice]
}
private struct Catalog: Encodable {
    struct Package: Encodable {
        let id: String; let version: String; let category: String; let path: String
        let sha256: String; let bytes: Int; let partCount: Int
        let distributionStatus = "prepared-not-published"
    }
    let schemaVersion = 1
    let version: String
    let packages: [Package]
    let entries: [Entry]
}

@main private struct Producer {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw EDAError.invalid("usage: ElectronicsLibraryProducer library-source-root output-directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let bindings = try JSONDecoder().decode(Bindings.self, from: Data(contentsOf: root.appendingPathComponent("curated-bindings.json")))
        let lock = try JSONDecoder().decode(SourceLock.self, from: Data(contentsOf: root.appendingPathComponent("SOURCES.lock.json")))
        guard bindings.schemaVersion == 1, lock.schemaVersion == 1 else { throw EDAError.unsupported("library producer source schema") }
        let locked = Dictionary(uniqueKeysWithValues: lock.files.map { ($0.path, $0) })
        func source(_ path: String) throws -> (Data, EDALibrarySource) {
            guard EDALibraryPackage.safeRelativePath(path), let original = locked[path] else { throw EDAError.missing("locked source " + path) }
            let bytes = try Data(contentsOf: root.appendingPathComponent("sources").appendingPathComponent(path))
            guard bytes.count == original.bytes, EDALibraryDigest.sha256(bytes) == original.sha256 else { throw EDAError.invalid("source hash differs: " + path) }
            return (bytes, .init(path: path, data: bytes, url: original.url, revision: original.revision))
        }
        let licenseURL = "https://www.kicad.org/libraries/license/"
        let license = try source("kicad-symbols/LICENSE.md").0
        let legalCode = try Data(contentsOf: root.appendingPathComponent("licenses/CC-BY-SA-4.0.txt"))
        let notice = EDALibraryLicense(id: "CC-BY-SA-4.0 WITH KiCad-design-exception", attribution: "KiCad library contributors",
            text: String(decoding: license, as: UTF8.self) + "\n\n" + String(decoding: legalCode, as: UTF8.self), url: licenseURL,
            modifications: "Floe native conversion and explicit curated symbol/footprint bindings. Source files remain byte-identical. Normal symbol bodies are used; compatibility findings describe retained alternate artwork/styling. Rounded SMD pads use a declared polygon error budget.")
        var groups: [String: [EDALibraryPart]] = [:], payloads: [String: [String: Data]] = [:], entries: [Entry] = []
        for binding in bindings.bindings {
            let variant = binding.footprintIdentifier.isEmpty ? "symbol" : binding.footprintIdentifier
            let partID = binding.symbolIdentifier + "/" + variant
            let displayName = binding.name + (binding.footprintIdentifier.isEmpty ? "" : " · " + (binding.footprintIdentifier.split(separator: ":").last.map(String.init) ?? ""))
            var reports: [EDALibraryNotice] = []
            do {
                guard binding.sourceError == nil, let firstPath = binding.symbolPaths.first else { throw EDAError.missing("curated original source") }
                var raw: [String: Data] = [:], origins: [EDALibrarySource] = [], dependencies: [String: Data] = [:]
                for path in binding.symbolPaths {
                    let key = "kicad-symbols/" + path, result = try source(key)
                    raw[key] = result.0; origins.append(result.1)
                    if path != firstPath { dependencies[path] = result.0 }
                }
                let imported = try EDAKiCadSymbols.read(raw["kicad-symbols/" + firstPath]!, sourcePath: "kicad-symbols/" + firstPath,
                    namespace: binding.family, dependencies: dependencies)
                reports += imported.notices[binding.name] ?? []
                guard let symbol = imported.symbols.first(where: { $0.name == binding.name }) else { throw EDAError.unsupported("symbol cannot be represented; see compatibility findings") }
                var footprint: EDAFootprintDefinition?
                if let path = binding.footprintPath {
                    let key = "kicad-footprints/" + path, result = try source(key)
                    raw[key] = result.0; origins.append(result.1)
                    let importedFP = try EDAKiCadFootprints.read(result.0, sourcePath: key,
                        namespace: binding.footprintIdentifier.split(separator: ":").first.map(String.init) ?? "")
                    reports += importedFP.notices
                    guard let value = importedFP.footprint else { throw EDAError.unsupported("footprint cannot be represented; see compatibility findings") }
                    footprint = value
                }
                let map = try footprint.map { try EDALibraryPinMap.matchingNumbers(symbol: symbol, footprint: $0) }
                let generic = ["Device", "Connector_Generic", "Switch"].contains(binding.family)
                let url = symbol.fields["Datasheet"] ?? ""
                let maker = symbol.fields["Manufacturer"] ?? manufacturer(url: url)
                var parameters = symbol.fields
                parameters["PartNumber"] = generic ? "" : binding.name
                parameters["Package"] = binding.footprintIdentifier
                parameters["BindingSource"] = binding.bindingSource
                if !maker.isEmpty { parameters["ManufacturerSource"] = "KiCad Datasheet publisher or explicit source property" }
                let part = EDALibraryPart(id: partID, name: displayName, kind: generic ? .generic : .device,
                    category: binding.category, manufacturer: maker, aliases: [binding.name, binding.symbolIdentifier, alias(binding.category, name: binding.name)],
                    parameters: parameters, symbol: symbol, footprint: footprint, pinMap: map, sources: origins, notices: reports)
                try part.validate()
                groups[binding.category, default: []].append(part)
                payloads[binding.category, default: [:]].merge(raw) { old, new in precondition(old == new); return old }
                entries.append(.init(id: partID, name: displayName, category: binding.category, status: "native-available",
                    sourceIdentifier: binding.symbolIdentifier, footprintIdentifier: binding.footprintIdentifier,
                    pinCount: part.pinCount, padNumbers: footprint.map { Array(Set($0.pads.map(\.number))).sorted() }, notices: reports))
            } catch {
                reports.append(.init("curated_entry_unavailable", .blocking, path: partID, detail: String(describing: error)))
                entries.append(.init(id: partID, name: displayName, category: binding.category, status: "original-retained-unavailable",
                    sourceIdentifier: binding.symbolIdentifier, footprintIdentifier: binding.footprintIdentifier, pinCount: nil, padNumbers: nil, notices: reports))
            }
        }
        guard !groups.isEmpty else { throw EDAError.invalid("no compatible native library entries; inspect retained source and compatibility report") }
        var packages: [Catalog.Package] = []
        for category in groups.keys.sorted() {
            let package = EDALibraryPackage(id: "org.floe.electronics.common." + category, version: bindings.version,
                title: "KiCad / Floe — " + category, parts: groups[category]!.sorted { $0.id < $1.id }, licenses: [notice], sourcePayloads: payloads[category]!)
            try package.validate()
            let bytes = try EDALibraryDigest.encoded(package), relative = "packages/" + category + "/Library.json"
            let destination = output.appendingPathComponent(relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .atomic)
            let content: [String: Any] = ["schemaVersion": 1, "id": package.id, "version": package.version, "kind": "templates", "template": "Library.json",
                "title": ["en": package.title, "zh-Hans": package.title], "domain": "org.floe.electronics.library", "librarySHA256": EDALibraryDigest.sha256(bytes)]
            let contentBytes = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
            try contentBytes.write(to: destination.deletingLastPathComponent().appendingPathComponent("content.json"), options: .atomic)
            packages.append(.init(id: package.id, version: package.version, category: category, path: relative,
                sha256: EDALibraryDigest.sha256(bytes), bytes: bytes.count, partCount: package.parts.count))
        }
        let catalog = Catalog(version: bindings.version, packages: packages, entries: entries)
        try EDALibraryDigest.encoded(catalog).write(to: output.appendingPathComponent("Catalog.json"), options: .atomic)
        let available = entries.filter { $0.status == "native-available" }.count
        print("Prepared \(packages.count) category packages; \(available)/\(entries.count) entries are native-available. No content has been published.")
        for entry in entries where entry.status != "native-available" {
            print(entry.id + ": " + entry.notices.map { $0.code + "=" + $0.detail }.joined(separator: "; "))
        }
    }
    static func manufacturer(url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return "" }
        for (suffix, name) in [("ti.com", "Texas Instruments"), ("st.com", "STMicroelectronics"), ("microchip.com", "Microchip"), ("raspberrypi.com", "Raspberry Pi"), ("espressif.com", "Espressif"), ("bosch-sensortec.com", "Bosch Sensortec"), ("onsemi.com", "onsemi"), ("nexperia.com", "Nexperia"), ("analog.com", "Analog Devices"), ("maximintegrated.com", "Maxim Integrated")] {
            if host == suffix || host.hasSuffix("." + suffix) { return name }
        }
        return ""
    }
    static func alias(_ category: String, name: String) -> String {
        if category == "passives" {
            if name.hasPrefix("R_Pot") { return "电位器 可调电阻 无源" }
            if name == "R" { return "电阻 无源" }
            if name.hasPrefix("C") { return "电容 无源" }
            if name == "L" { return "电感 无源" }
        }
        return ["passives": "无源", "diodes-leds": "二极管 发光二极管", "transistors-mosfets": "晶体管 三极管 MOS管",
         "power": "电源 稳压 基准", "analog-opamps": "模拟 运算放大器 比较器", "digital-logic": "数字逻辑 移位寄存器",
         "microcontrollers": "单片机 微控制器 MCU", "connectors": "连接器 排针", "switches-relays": "开关 按键 继电器",
         "crystals": "晶振 晶体", "sensors": "传感器 温度 湿度 气压", "modules": "模块 无线 开发板"][category] ?? category
    }
}
