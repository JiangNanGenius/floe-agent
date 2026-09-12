import Foundation
import FloeCore

/// Debian-style `sources.list` / `sources.list.d` model and parser.
public struct AptSource: Sendable, Equatable, Identifiable {
    public var id: String { "\(uri) \(suite) \(components.joined(separator: ","))" }
    public var type: String
    public var uri: String
    public var suite: String
    public var components: [String]
    public var architectures: [String]
    public var signedBy: String?
    public var trusted: Bool
    public var enabled: Bool

    public init(
        type: String = "deb",
        uri: String,
        suite: String,
        components: [String] = ["main"],
        architectures: [String] = [],
        signedBy: String? = nil,
        trusted: Bool = false,
        enabled: Bool = true
    ) {
        self.type = type
        self.uri = uri
        self.suite = suite
        self.components = components
        self.architectures = architectures
        self.signedBy = signedBy
        self.trusted = trusted
        self.enabled = enabled
    }

    public var baseURL: String {
        uri.hasSuffix("/") ? uri : uri + "/"
    }

    public func releaseURL() -> URL? {
        URL(string: baseURL + "dists/\(suite)/InRelease")
    }

    public func releaseGPGURL() -> URL? {
        URL(string: baseURL + "dists/\(suite)/Release.gpg")
    }

    public func packagesURL(component: String, architecture: String) -> URL? {
        URL(string: baseURL + "dists/\(suite)/\(component)/binary-\(architecture)/Packages.gz")
    }
}

public enum AptSources {
    public static func parse(line: String, fileIndex: Int = 0) -> AptSource? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var enabled = true
        var body = trimmed
        if body.hasPrefix("#") {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("deb") else { return nil }
            enabled = false
        }
        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first, first == "deb" || first == "deb-src" else { return nil }
        var options: [String: String] = [:]
        var position = 1
        if position < tokens.count, tokens[position].hasPrefix("[") {
            var optionText = tokens[position]
            while !optionText.hasSuffix("]"), position + 1 < tokens.count {
                position += 1
                optionText += " " + tokens[position]
            }
            optionText = optionText.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            for pair in optionText.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    options[parts[0].lowercased()] = parts[1]
                } else if parts.count == 1 {
                    options[parts[0].lowercased()] = "yes"
                }
            }
            position += 1
        }
        guard position + 1 < tokens.count else { return nil }
        let uri = tokens[position]
        let suite = tokens[position + 1]
        let components = Array(tokens.dropFirst(position + 2))
        return AptSource(
            type: first,
            uri: uri,
            suite: suite,
            components: components.isEmpty ? ["main"] : components,
            architectures: (options["arch"] ?? options["architectures"])?
                .split(separator: ",").map(String.init) ?? [],
            signedBy: options["signed-by"],
            trusted: (options["trusted"]?.lowercased() == "yes" || options["trusted"]?.lowercased() == "true"),
            enabled: enabled
        )
    }

    public static func parse(contents: String) -> [AptSource] {
        contents.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parse(line: String($0)) }
    }

    public static func read(inContainerAt root: URL) -> [AptSource] {
        var sources: [AptSource] = []
        let listFile = root.appendingPathComponent("etc/apt/sources.list")
        if let text = try? String(contentsOf: listFile, encoding: .utf8) {
            sources.append(contentsOf: parse(contents: text))
        }
        let directory = root.appendingPathComponent("etc/apt/sources.list.d", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "list" || file.pathExtension == "sources" {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                sources.append(contentsOf: parse(contents: text))
            }
        }
        return sources.filter { $0.enabled }
    }

    public static func write(_ sources: [AptSource], toContainer root: URL, fileName: String = "sources.list") throws {
        let directory = root.appendingPathComponent("etc/apt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = sources.map { source -> String in
            var line = "\(source.type) "
            var options: [String] = []
            if !source.architectures.isEmpty { options.append("arch=\(source.architectures.joined(separator: ","))") }
            if let signedBy = source.signedBy { options.append("signed-by=\(signedBy)") }
            if source.trusted { options.append("trusted=yes") }
            if !options.isEmpty { line += "[\(options.joined(separator: " "))] " }
            line += "\(source.uri) \(source.suite)"
            if !source.components.isEmpty { line += " " + source.components.joined(separator: " ") }
            return line
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }
}
