// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A user-confirmed association, never a manufacturer-qualified part inferred
/// from two similar names. Each source and every explicit pin/pad remain fixed.
public enum EDALibraryBinding {
    public static func package(symbol source: EDALibrarySnapshot, footprint physical: EDALibrarySnapshot,
        pinMap: EDALibraryPinMap, name: String? = nil) throws -> EDALibraryPackage {
        try source.validate(); try physical.validate()
        guard source.part.isPlaceable, physical.part.isPlaceable else { throw EDAError.unsupported("association source has blocking compatibility findings") }
        guard let symbol = source.part.symbol, let footprint = physical.part.footprint else { throw EDAError.invalid("choose a symbol and a footprint") }
        try pinMap.validate(symbol: symbol, footprint: footprint)
        guard let symbolSources = source.originalSources, let footprintSources = physical.originalSources else { throw EDAError.missing("exact original source bytes for the chosen library entries") }
        var payloads: [String: Data] = [:], origins: [EDALibrarySource] = []
        func copy(_ sources: [EDALibrarySource], _ bytes: [String: Data], prefix: String) throws {
            for original in sources {
                guard let data = bytes[original.path], data.count == original.byteCount,
                      EDALibraryDigest.sha256(data) == original.sha256 else { throw EDAError.invalid("association original source") }
                let path = prefix + "/" + original.path
                guard payloads[path] == nil else { throw EDAError.duplicate("association source path") }
                payloads[path] = data
                origins.append(.init(path: path, data: data, url: original.url, revision: original.revision))
            }
        }
        try copy(source.part.sources, symbolSources, prefix: "symbol")
        try copy(physical.part.sources, footprintSources, prefix: "footprint")
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = value.flatMap { $0.isEmpty ? nil : $0 } ?? symbol.name + " / " + footprint.name
        let parameters = ["Value": source.part.parameters["Value"] ?? symbol.name,
            "PartNumber": "", "Manufacturer": "", "Package": footprint.name,
            "BindingKind": "user-confirmed", "BindingSource": "Explicit user-defined symbol/footprint association; not a manufacturer-qualified device",
            "SourceSymbolPackageSHA256": source.packageSHA256, "SourceFootprintPackageSHA256": physical.packageSHA256]
        let part = EDALibraryPart(id: "associated-part", name: title, kind: .generic, category: "user", parameters: parameters,
            symbol: symbol, footprint: footprint, pinMap: pinMap, sources: origins,
            notices: source.part.notices + physical.part.notices + [.init("user_defined_association", .information, path: "binding", detail: "The symbol/footprint association and map were chosen explicitly. It is a custom combination, not a verified manufacturer part number.")])
        var licenses: [EDALibraryLicense] = [], seen: Set<String> = []
        for var license in source.licenses + physical.licenses {
            let hash = try EDALibraryDigest.sha256(EDALibraryDigest.encoded(license))
            if seen.insert(hash).inserted {
                license.modifications += "\nUser-defined association; all original files remain unchanged."
                licenses.append(license)
            }
        }
        let hash = try EDALibraryDigest.sha256(EDALibraryDigest.encoded(part))
        let package = EDALibraryPackage(id: "user.association." + hash, version: "1.0.0", title: title,
            parts: [part], licenses: licenses, sourcePayloads: payloads)
        try package.validate(); return package
    }
}
