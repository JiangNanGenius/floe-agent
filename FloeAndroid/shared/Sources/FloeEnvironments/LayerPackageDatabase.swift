import Foundation
import FloeCore

/// dpkg status/info persistence. Each container layer keeps a real
/// Debian-format `var/lib/dpkg/status` shard plus `info/<pkg>.list` and
/// `info/<pkg>.md5sums`; `dpkg -l` merges the layer stack.
public enum LayerPackageDatabase {
    public struct StatusEntry: Sendable, Equatable {
        public var name: String
        public var version: String
        public var architecture: String
        public var status: String
        public var summary: String?
        public var license: String?
        public var source: String?
        public var layer: LayerKind?
        public var requiresBase: String?
        public var installedFiles: [String]

        public init(
            name: String,
            version: String,
            architecture: String = "all",
            status: String = "install ok installed",
            summary: String? = nil,
            license: String? = nil,
            source: String? = nil,
            layer: LayerKind? = nil,
            requiresBase: String? = nil,
            installedFiles: [String] = []
        ) {
            self.name = name
            self.version = version
            self.architecture = architecture
            self.status = status
            self.summary = summary
            self.license = license
            self.source = source
            self.layer = layer
            self.requiresBase = requiresBase
            self.installedFiles = installedFiles
        }

        public var isInstalled: Bool { status.split(separator: " ").last == "installed" }
        public var isHalfConfigured: Bool { status.contains("half-configured") }
        public var isUnpacked: Bool { status.contains("unpacked") }
    }

    public static func readStatus(at layerURL: URL) -> [StatusEntry] {
        let url = layerURL.appendingPathComponent("var/lib/dpkg/status")
        guard let data = try? Data(floeContentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return LayerPackageControl.parseAll(text).compactMap { stanza in
            guard let name = stanza["Package"], let version = stanza["Version"] else { return nil }
            let files = readFileList(at: layerURL, package: name)
            return StatusEntry(
                name: name,
                version: version,
                architecture: stanza["Architecture"] ?? "all",
                status: stanza["Status"] ?? "install ok installed",
                summary: stanza["Description"]?.split(separator: "\n").first.map(String.init),
                license: stanza["License"],
                source: stanza["Source"],
                layer: stanza["Floe-Layer"].flatMap { LayerKind(rawValue: $0) },
                requiresBase: stanza["Floe-Requires-Base"],
                installedFiles: files
            )
        }
    }

    public static func writeStatus(_ entries: [StatusEntry], at layerURL: URL) throws {
        let stanzas = entries.map { entry -> LayerPackageControl in
            var stanza = LayerPackageControl()
            stanza.set("Package", entry.name)
            stanza.set("Status", entry.status)
            stanza.set("Priority", "optional")
            stanza.set("Section", "floe")
            stanza.set("Installed-Size", String(entry.installedFiles.count))
            stanza.set("Architecture", entry.architecture)
            stanza.set("Version", entry.version)
            if let summary = entry.summary { stanza.set("Description", summary) }
            if let license = entry.license { stanza.set("License", license) }
            if let source = entry.source { stanza.set("Source", source) }
            if let layer = entry.layer { stanza.set("Floe-Layer", layer.rawValue) }
            if let requiresBase = entry.requiresBase { stanza.set("Floe-Requires-Base", requiresBase) }
            return stanza
        }
        let document = stanzas.map(\.serialized).joined(separator: "\n\n") + (stanzas.isEmpty ? "" : "\n")
        let url = layerURL.appendingPathComponent("var/lib/dpkg/status")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(document.utf8).write(to: url, options: .atomic)
    }

    public static func writeInfoFiles(for entry: StatusEntry, at layerURL: URL, digests: [String: String] = [:]) throws {
        let infoDirectory = layerURL.appendingPathComponent("var/lib/dpkg/info", isDirectory: true)
        try FileManager.default.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        let listText = entry.installedFiles.joined(separator: "\n") + (entry.installedFiles.isEmpty ? "" : "\n")
        try Data(listText.utf8).write(
            to: infoDirectory.appendingPathComponent("\(entry.name).list"),
            options: .atomic
        )
        let md5Text = entry.installedFiles
            .compactMap { path in digests[path].map { "\($0)  \(path.hasPrefix("/") ? path : "/\(path)")" } }
            .joined(separator: "\n")
        try Data(md5Text.utf8).write(
            to: infoDirectory.appendingPathComponent("\(entry.name).md5sums"),
            options: .atomic
        )
    }

    public static func readFileList(at layerURL: URL, package: String) -> [String] {
        let url = layerURL.appendingPathComponent("var/lib/dpkg/info/\(package).list")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Merges a layer stack, top layer wins on name conflicts.
    public static func merged(layers: [(kind: LayerKind, url: URL)]) -> [StatusEntry] {
        var seen = Set<String>()
        var result: [StatusEntry] = []
        for layer in layers {
            for entry in readStatus(at: layer.url) where !seen.contains(entry.name) {
                seen.insert(entry.name)
                var annotated = entry
                annotated.layer = layer.kind
                result.append(annotated)
            }
        }
        return result
    }
}
