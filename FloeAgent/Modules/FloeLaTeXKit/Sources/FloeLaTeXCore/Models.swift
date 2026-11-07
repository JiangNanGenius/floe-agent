// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public enum LaTeXError: Error, LocalizedError, Sendable, Equatable {
    case invalidPath(String), invalidProject, missingFile(String), changedFile(String)
    case revisionConflict(expected: Int64, actual: Int64), invalidRange, invalidText
    case limitExceeded(String), duplicatePath(String), invalidOperation(String)
    case unavailable(String), checksumMismatch(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): "Invalid project path: \(path)"
        case .invalidProject: "The LaTeX project is incomplete. Its files have been preserved."
        case .missingFile(let path): "File not found: \(path)"
        case .changedFile(let path): "This file changed outside the editor: \(path)"
        case .revisionConflict: "The document changed. Refresh it before applying this edit."
        case .invalidRange: "The edit no longer matches this text."
        case .invalidText: "This source file must contain valid UTF-8 text."
        case .limitExceeded(let value): "Document limit reached: \(value)"
        case .duplicatePath(let path): "A file with this name already exists: \(path)"
        case .invalidOperation(let reason), .unavailable(let reason): reason
        case .checksumMismatch(let name): "The downloaded file could not be verified: \(name)"
        case .cancelled: "Typesetting stopped."
        }
    }
}

public enum LaTeXEngine: String, CaseIterable, Codable, Sendable {
    case xeLaTeX, luaLaTeX, pdfLaTeX, latex
    public var title: String {
        switch self { case .xeLaTeX: "XeLaTeX"; case .luaLaTeX: "LuaLaTeX"; case .pdfLaTeX: "pdfLaTeX"; case .latex: "LaTeX" }
    }
}

public struct LaTeXOwner: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case space, task, note, externalDocument }
    public var kind: Kind
    public var id: UUID
    public init(kind: Kind, id: UUID) { self.kind = kind; self.id = id }
}

public enum LaTeXFileKind: String, Codable, Sendable {
    case source, bibliography, style, image, font, data
    public static func infer(_ path: String) -> Self {
        switch (path as NSString).pathExtension.lowercased() {
        case "tex", "ltx": .source
        case "bib": .bibliography
        case "sty", "cls", "bst", "bbx", "cbx", "def", "cfg", "fd": .style
        case "png", "jpg", "jpeg", "pdf", "svg", "eps", "tif", "tiff": .image
        case "otf", "ttf", "tfm", "vf", "pfb", "woff", "woff2": .font
        default: .data
        }
    }
    public var isText: Bool { [.source, .bibliography, .style].contains(self) }
}

public struct LaTeXFileEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var kind: LaTeXFileKind
    public var sha256: String
    public var byteCount: Int
    public init(path: String, data: Data) {
        self.path = path; kind = .infer(path); sha256 = LaTeXDigest.hash(data); byteCount = data.count
    }
}

public struct LaTeXResourcePin: Codable, Hashable, Sendable {
    public var identifier: String
    public var version: String
    public var sha256: String
    public init(identifier: String, version: String, sha256: String) { self.identifier = identifier; self.version = version; self.sha256 = sha256 }
}

public struct LaTeXProjectManifest: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: UUID
    public var owner: LaTeXOwner
    public var title: String
    public var revision: Int64
    public var mainFile: String
    public var engine: LaTeXEngine
    public var files: [LaTeXFileEntry]
    public var resources: [LaTeXResourcePin]
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastMutationID: UUID?
    public init(id: UUID = UUID(), owner: LaTeXOwner, title: String, mainFile: String = "main.tex", engine: LaTeXEngine = .xeLaTeX) {
        self.id = id; self.owner = owner; self.title = title; revision = 0
        self.mainFile = mainFile; self.engine = engine; files = []; resources = []
        createdAt = Date(); modifiedAt = createdAt
    }
}

/// All offsets refer to UTF-8 bytes of one exact source revision.
public struct LaTeXSourceRange: Codable, Hashable, Sendable {
    public var start: Int
    public var length: Int
    public var end: Int { start + length }
    public init(start: Int, length: Int) { self.start = start; self.length = length }
    public func replacing(in text: String, with replacement: String) throws -> String {
        let bytes = Array(text.utf8)
        guard start >= 0, length >= 0, start <= bytes.count, length <= bytes.count - start,
              String(bytes: bytes[..<start], encoding: .utf8) != nil,
              String(bytes: bytes[end...], encoding: .utf8) != nil else { throw LaTeXError.invalidRange }
        return String(decoding: Array(bytes[..<start]) + Array(replacement.utf8) + Array(bytes[end...]), as: UTF8.self)
    }
}

public enum LaTeXEdit: Codable, Sendable {
    case put(path: String, data: Data)
    case replace(path: String, range: LaTeXSourceRange, text: String)
    case delete(path: String)
    case rename(from: String, to: String)
    case title(String)
    case mainFile(String)
    case engine(LaTeXEngine)
    case resources([LaTeXResourcePin])
}

public struct LaTeXMutationResult: Codable, Sendable {
    public var revision: Int64
    public var currentRevision: Int64
    public var replayed: Bool
    public var changedPaths: [String]
}

public struct LaTeXHistoryEntry: Codable, Identifiable, Sendable {
    public var id: Int64 { manifest.revision }
    public var manifest: LaTeXProjectManifest
    public var label: String
    public var origin: String
    public var mutationID: UUID?
}

public struct LaTeXProjectSnapshot: Sendable {
    public var id: UUID
    public var manifest: LaTeXProjectManifest
    public var sourceRoot: URL
    public var fingerprint: String
    public init(id: UUID, manifest: LaTeXProjectManifest, sourceRoot: URL, fingerprint: String) {
        self.id = id; self.manifest = manifest; self.sourceRoot = sourceRoot; self.fingerprint = fingerprint
    }
}

public enum LaTeXDigest {
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public struct LaTeXProjectLimits: Sendable {
    public var maximumFiles = 10_000
    public var maximumTextBytes = 16 * 1024 * 1024
    public var maximumFileBytes = 256 * 1024 * 1024
    public var maximumProjectBytes = 1024 * 1024 * 1024
    public init() {}
}
