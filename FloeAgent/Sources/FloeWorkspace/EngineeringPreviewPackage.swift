// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Read-only renderer routing. Extensions requiring an unbundled decoder are
/// identified explicitly, rather than handed to Quick Look as a blank success.
public enum EngineeringPreviewKind: String, Codable, Sendable {
    case mesh, dxf, dwg, cadSurface, gerber, unsupported

    public static func identify(_ path: String) -> Self? {
        switch (path as NSString).pathExtension.lowercased() {
        case "stl", "obj", "ply", "off", "3ds", "dae", "fbx", "3mf", "amf", "gltf", "glb", "wrl", "bim": .mesh
        case "dxf": .dxf
        case "dwg": .dwg
        case "step", "stp", "iges", "igs", "brep": .cadSurface
        case "gbr", "ger", "gerber", "gtl", "gbl", "gts", "gbs", "gto", "gbo", "gko", "gm1", "gml", "drl", "xln": .gerber
        case "dwt", "dgn", "fcstd", "ifc", "3dm", "kicad_pcb", "kicad_sch": .unsupported
        default: nil
        }
    }
}

public struct EngineeringPreviewPackage: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let name: String
        public let base64: String
    }
    public let name: String
    public let kind: EngineeringPreviewKind
    public let files: [File]
    public let missingReferences: [String]
    public static let maximumBytes = 20 * 1024 * 1024
    public static let maximumFiles = 32

    /// The WebView receives immutable bytes, no filesystem or tool capabilities.
    /// Only explicit OBJ/MTL/glTF references below the selected folder are read.
    public static func load(path: String, service: WorkspaceFileService) throws -> Self {
        guard let kind = EngineeringPreviewKind.identify(path) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let base = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var pending = [name], visited = Set<String>(), files: [File] = [], missing: [String] = []
        var total = 0
        while !pending.isEmpty {
            try Task.checkCancellation()
            let relative = pending.removeFirst()
            guard visited.insert(relative).inserted else { continue }
            guard visited.count <= maximumFiles else { throw CocoaError(.fileReadTooLarge) }
            do {
                let url = try service.guardResolver.resolve(base.isEmpty ? relative : base + "/" + relative)
                try service.guardResolver.assertReadableSize(url)
                // Bound the actual read, including a file that grows after stat.
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: maximumBytes - total + 1) ?? Data()
                total += bytes.count
                guard total <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
                files.append(File(name: relative, base64: bytes.base64EncodedString()))
                let prefix = (relative as NSString).deletingLastPathComponent
                for reference in references(bytes, extension: url.pathExtension.lowercased()) {
                    let child = prefix.isEmpty ? reference : prefix + "/" + reference
                    if safeReference(child) {
                        if !visited.contains(child), !pending.contains(child) {
                            guard visited.count + pending.count < maximumFiles else { throw CocoaError(.fileReadTooLarge) }
                            pending.append(child)
                        }
                    }
                    else { missing.append(reference) }
                }
            } catch {
                if relative == name || (error as NSError).code == NSFileReadTooLargeError { throw error }
                missing.append(relative)
            }
        }
        return Self(name: name, kind: kind, files: files, missingReferences: missing)
    }

    public static func single(name: String, bytes: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let kind = EngineeringPreviewKind.identify(name) else { throw CocoaError(.fileReadUnsupportedScheme) }
        return Self(name: name, kind: kind, files: [File(name: name, base64: bytes.base64EncodedString())],
                    missingReferences: references(bytes, extension: (name as NSString).pathExtension.lowercased()))
    }

    static func safeReference(_ path: String) -> Bool {
        guard !path.isEmpty, path.count < 1024, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains(":"), !path.contains("\\"), !path.contains("%"),
              !path.split(separator: "/").contains("..") else { return false }
        return ["mtl", "bin", "png", "jpg", "jpeg", "webp", "bmp", "gif"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func references(_ bytes: Data, extension ext: String) -> [String] {
        if ext == "gltf", let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            return ["buffers", "images"].flatMap { key in
                (json[key] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
            }.filter { !$0.hasPrefix("data:") }
        }
        guard ["obj", "mtl"].contains(ext), let text = String(data: bytes, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return nil }
            let command = parts[0].lowercased()
            guard (ext == "obj" && command == "mtllib") || (ext == "mtl" && command.hasPrefix("map_")) else { return nil }
            // Option-bearing MTL paths are reported as unresolved, not guessed.
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }
}
