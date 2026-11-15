// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore

/// The result of stamping the reviewed, dormant Floe development bridge into a
/// private GDevelop Web export. It is provenance, not an engine or UI result.
public struct GameGDevelopExportBridgeReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let engine: GameEngineID
    public let bridgeVersion: String
    public let license: String
    public let bridgeFile: String
    public let bridgeSHA256: String
    public let bridgeBytes: Int
    public let bridgeCreated: Bool
    public let indexFile: String
    public let indexSHA256Before: String
    public let indexSHA256After: String
    public let indexBytesAfter: Int
    public let injectionPoint: String
    public let alreadyDecorated: Bool

    public var changed: Bool { bridgeCreated || indexSHA256Before != indexSHA256After }
}

public enum GameGDevelopExportBridgeError: Error, Equatable, Sendable {
    case notAPlayableExport(String)
    case incompatibleIndex(String)
    case bridgeCollision(String)
    case indexCollision(String)
    case limitExceeded(String)
    case unsafePath(String)
    case io(String)
}

extension GameGDevelopExportBridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAPlayableExport(let detail):
            return "The selected GDevelop folder is not a complete playable Web export: \(detail)"
        case .incompatibleIndex(let detail):
            return "This GDevelop export shape cannot receive the reviewed bridge safely: \(detail)"
        case .bridgeCollision(let detail):
            return "floe-developer.js already exists with different bytes: \(detail)"
        case .indexCollision(let detail):
            return "index.html already references a different floe-developer.js tag: \(detail)"
        case .limitExceeded(let detail):
            return "The GDevelop export exceeded a bounded bridge limit: \(detail)"
        case .unsafePath(let detail):
            return "The GDevelop export contains an unsafe path: \(detail)"
        case .io(let detail):
            return "The GDevelop bridge decoration failed: \(detail)"
        }
    }
}

/// Stamps the exact reviewed `gdevelop-export-bridge.js` into a private copy of
/// an official GDJS Web export. The exporter and the Web run preparer call this
/// after verifying the official artifact; imported source bytes are never
/// edited. Calling it twice with the same bytes is a no-op.
public enum GameGDevelopExportBridge {
    public static let version = "1.0.0"
    public static let fileName = "floe-developer.js"
    public static let manifestFileName = "floe-developer.manifest.json"
    public static let licenseIdentifier = "MPL-2.0"
    public static let manifestSchemaVersion = 1
    public static let injectionPoint = "after-body-open"
    public static let maximumIndexBytes = 8 * 1_024 * 1_024
    public static let maximumBridgeBytes = 512 * 1_024
    public static let scriptTag = #"<script src="floe-developer.js"></script>"#
    /// SHA-256 of the reviewed resource bytes. A resource drift fails closed.
    public static let pinnedSourceSHA256 = "0dbe693fc5f82f0feea97383b3243e4d98e71eacd6d6823e39ad02d2a17eac85"

    public static var sourceData: Data {
        get throws {
            guard let url = Bundle.module.url(forResource: "gdevelop-export-bridge",
                                              withExtension: "js"),
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                throw GameGDevelopExportBridgeError.io("gdevelop-export-bridge.js is missing from the resource bundle")
            }
            guard !data.isEmpty, data.count <= maximumBridgeBytes else {
                throw GameGDevelopExportBridgeError.limitExceeded("bridge resource")
            }
            return data
        }
    }

    /// Decorates one private exported playable directory. The caller owns the
    /// directory; this function performs no engine execution, download or
    /// network access and never touches the project repository.
    public static func decorate(directory: URL) throws -> GameGDevelopExportBridgeReceipt {
        guard directory.isFileURL else { throw GameGDevelopExportBridgeError.unsafePath("directory") }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do { values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
        catch { throw GameGDevelopExportBridgeError.notAPlayableExport("directory is unreadable") }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GameGDevelopExportBridgeError.notAPlayableExport("directory is not a real folder")
        }
        let bridgeURL = root.appendingPathComponent(fileName, isDirectory: false)
        let indexURL = root.appendingPathComponent("index.html", isDirectory: false)
        for name in ["index.html", "data.js", "gd.js"] {
            let url = root.appendingPathComponent(name, isDirectory: false)
            let item = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard item?.isRegularFile == true, item?.isSymbolicLink != true else {
                throw GameGDevelopExportBridgeError.notAPlayableExport("\(name) is missing or not a regular file")
            }
        }
        let indexValues = try indexURL.resourceValues(forKeys: [.fileSizeKey])
        let indexSize = indexValues.fileSize ?? 0
        guard indexSize > 0, indexSize <= maximumIndexBytes else {
            throw GameGDevelopExportBridgeError.limitExceeded("index.html")
        }
        let bridge = try sourceData
        let bridgeSHA = GameDigest.sha256(bridge)
        guard bridgeSHA == pinnedSourceSHA256 else {
            throw GameGDevelopExportBridgeError.io("reviewed bridge resource hash drift")
        }
        if FileManager.default.fileExists(atPath: bridgeURL.path) {
            let existing = try? bridgeURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard existing?.isRegularFile == true, existing?.isSymbolicLink != true,
                  let current = try? Data(contentsOf: bridgeURL, options: [.mappedIfSafe]) else {
                throw GameGDevelopExportBridgeError.unsafePath("floe-developer.js is not a regular file")
            }
            guard current == bridge else {
                throw GameGDevelopExportBridgeError.bridgeCollision(
                    "existing sha256 \(GameDigest.sha256(current))")
            }
        }
        let indexData: Data
        do { indexData = try Data(contentsOf: indexURL, options: [.mappedIfSafe]) }
        catch { throw GameGDevelopExportBridgeError.io("index.html is unreadable") }
        guard let index = String(data: indexData, encoding: .utf8) else {
            throw GameGDevelopExportBridgeError.incompatibleIndex("index.html is not UTF-8")
        }
        guard index.contains("gdjs.projectData"), index.contains("gdjs.RuntimeGame") else {
            throw GameGDevelopExportBridgeError.incompatibleIndex(
                "index.html does not initialize the official GDJS runtime")
        }
        let before = GameDigest.sha256(indexData)
        let decorated: String
        let alreadyDecorated: Bool
        let exactTagCount = index.components(separatedBy: scriptTag).count - 1
        if exactTagCount > 0 {
            guard exactTagCount == 1 else {
                throw GameGDevelopExportBridgeError.indexCollision("duplicate bridge tag")
            }
            let bridgeExists = FileManager.default.fileExists(atPath: bridgeURL.path)
            guard bridgeExists else {
                throw GameGDevelopExportBridgeError.indexCollision(
                    "index.html references the bridge but floe-developer.js is missing")
            }
            decorated = index
            alreadyDecorated = true
        } else {
            if index.contains(fileName) {
                throw GameGDevelopExportBridgeError.indexCollision(
                    "index.html mentions floe-developer.js without the reviewed script tag")
            }
            guard let insertion = bodyOpenEnd(in: index) else {
                throw GameGDevelopExportBridgeError.incompatibleIndex("index.html has no <body> element")
            }
            var mutated = index
            mutated.insert(contentsOf: scriptTag, at: insertion)
            guard mutated != index, mutated.components(separatedBy: scriptTag).count == 2 else {
                throw GameGDevelopExportBridgeError.incompatibleIndex("bridge tag insertion failed")
            }
            decorated = mutated
            alreadyDecorated = false
        }
        let decoratedData = Data(decorated.utf8)
        guard decoratedData.count <= maximumIndexBytes + scriptTag.utf8.count else {
            throw GameGDevelopExportBridgeError.limitExceeded("decorated index.html")
        }
        var bridgeCreated = false
        if !FileManager.default.fileExists(atPath: bridgeURL.path) {
            try writeAtomically(bridge, to: bridgeURL)
            bridgeCreated = true
        } else {
            let readback = try Data(contentsOf: bridgeURL, options: [.mappedIfSafe])
            guard readback == bridge else {
                throw GameGDevelopExportBridgeError.bridgeCollision("bridge changed during decoration")
            }
        }
        if !alreadyDecorated {
            do { try writeAtomically(decoratedData, to: indexURL) }
            catch { throw GameGDevelopExportBridgeError.io("index.html write failed") }
            let readback = try Data(contentsOf: indexURL, options: [.mappedIfSafe])
            guard readback == decoratedData else {
                throw GameGDevelopExportBridgeError.io("index.html read-back mismatch")
            }
        }
        let receipt = GameGDevelopExportBridgeReceipt(
            schemaVersion: manifestSchemaVersion,
            engine: .gdevelop,
            bridgeVersion: version,
            license: licenseIdentifier,
            bridgeFile: fileName,
            bridgeSHA256: bridgeSHA,
            bridgeBytes: bridge.count,
            bridgeCreated: bridgeCreated,
            indexFile: "index.html",
            indexSHA256Before: before,
            indexSHA256After: GameDigest.sha256(decoratedData),
            indexBytesAfter: decoratedData.count,
            injectionPoint: injectionPoint,
            alreadyDecorated: alreadyDecorated)
        try writeManifest(receipt, to: root)
        return receipt
    }

    /// The exact script tag and both hashes. The exported manifest is public
    /// provenance for the private copy; it is not an engine or UI result.
    private static func writeManifest(_ receipt: GameGDevelopExportBridgeReceipt,
                                      to root: URL) throws {
        struct Manifest: Encodable {
            let schemaVersion: Int
            let engine: GameEngineID
            let bridgeVersion: String
            let license: String
            let source: String
            let bridgeFile: String
            let bridgeSHA256: String
            let bridgeBytes: Int
            let bridgeCreated: Bool
            let indexFile: String
            let indexSHA256Before: String
            let indexSHA256After: String
            let indexBytesAfter: Int
            let injectionPoint: String
            let alreadyDecorated: Bool
            let runtimeGate: String
        }
        let manifest = Manifest(
            schemaVersion: receipt.schemaVersion, engine: receipt.engine,
            bridgeVersion: receipt.bridgeVersion, license: receipt.license,
            source: "FloeGameGDevelopKit.gdevelop-export-bridge.js",
            bridgeFile: receipt.bridgeFile, bridgeSHA256: receipt.bridgeSHA256,
            bridgeBytes: receipt.bridgeBytes, bridgeCreated: receipt.bridgeCreated,
            indexFile: receipt.indexFile,
            indexSHA256Before: receipt.indexSHA256Before,
            indexSHA256After: receipt.indexSHA256After,
            indexBytesAfter: receipt.indexBytesAfter,
            injectionPoint: receipt.injectionPoint,
            alreadyDecorated: receipt.alreadyDecorated,
            runtimeGate: "window.FloeDeveloper")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        let url = root.appendingPathComponent(manifestFileName, isDirectory: false)
        if let current = try? Data(contentsOf: url), current == data { return }
        try writeAtomically(data, to: url)
    }

    private static func bodyOpenEnd(in text: String) -> String.Index? {
        guard let start = text.range(of: "<body", options: [.caseInsensitive])?.lowerBound else { return nil }
        var index = start
        var quote: Character?
        var escape = false
        while index < text.endIndex {
            let character = text[index]
            if escape { escape = false }
            else if character == "\\" { escape = true }
            else if quote != nil {
                if character == quote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return text.index(after: index)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".floe-gdevelop-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: [.atomic])
            guard rename(temporary.path, url.path) == 0 else {
                throw GameGDevelopExportBridgeError.io("rename \(url.lastPathComponent)")
            }
        } catch let error as GameGDevelopExportBridgeError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw GameGDevelopExportBridgeError.io("write \(url.lastPathComponent)")
        }
    }
}
