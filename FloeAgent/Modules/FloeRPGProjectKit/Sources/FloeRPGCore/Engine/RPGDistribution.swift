// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// One diagnosed condition of a published RPG Maker distribution.
public struct RPGDistributionDiagnostic: Hashable, Sendable {
    public enum Severity: String, Sendable { case info, warning, blocking }
    public enum Code: String, Sendable {
        case encryptedArchivePresent
        case nativeRuntimeRequired
        case rtpReferenced
        case rtpAssetMissing
        case scriptsMissing
        case dataMissing
        case engineVersionMismatch
        case readableDataPresent
        case encryptedAssetsPresent
        case noProjectMarkers
        case playableWebBundle
    }
    public let severity: Severity
    public let code: Code
    /// Project-relative path the condition refers to, when applicable.
    public let path: String?
    public let detail: String
}

/// Read-only inspection of a downloaded/published RPG Maker game folder
/// (not necessarily an editor project). No Ruby/EXE/DLL execution, no
/// archive decryption, no file changes: conditions are diagnosed and
/// reported; originals are preserved.
public struct RPGDistributionInspection: Sendable {
    /// Detected engine, when project markers identify one.
    public let engine: RPGEngine?
    /// Every regular file found (relative paths), for import planning.
    public let files: [String]
    /// Per-file classification for the import workflow.
    public let fileStates: [String: RPGFileState]
    public let diagnostics: [RPGDistributionDiagnostic]
}

public struct RPGFileState: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Safe to copy into a project (all files are; nothing is discarded).
    public static let importable = RPGFileState(rawValue: 1 << 0)
    /// Readable by this module's data adapters (plain data files).
    public static let readable = RPGFileState(rawValue: 1 << 1)
    /// Semantically editable through the native DTO adapters.
    public static let editable = RPGFileState(rawValue: 1 << 2)
    /// Encrypted container or payload this module does not open.
    public static let encrypted = RPGFileState(rawValue: 1 << 3)
    /// Native executable/runtime dependency (EXE/DLL); never executed.
    public static let nativeBinary = RPGFileState(rawValue: 1 << 4)
    /// Referenced resource not present in the folder (e.g. RTP asset).
    public static let missingReference = RPGFileState(rawValue: 1 << 5)
}

public enum RPGDistributionInspector {
    /// Inspects a folder containing a published game. Follows no symlinks;
    /// directory reads are bounded.
    public static func inspect(rootURL: URL, maximumEntries: Int = 10_000) throws -> RPGDistributionInspection {
        guard rootURL.isFileURL else { throw GameProjectError.invalidContext }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw GameProjectError.rootUnavailable
        }
        var files: [String] = []
        var states: [String: RPGFileState] = [:]
        var diagnostics: [RPGDistributionDiagnostic] = []
        for case let relative as String in enumerator {
            // Manual hidden-file skip (enumerator(atPath:) has no options).
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            var isDirectory: ObjCBool = false
            let full = root.appendingPathComponent(relative).path
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            files.append(relative)
            states[relative] = [.importable]
            if files.count > maximumEntries { throw GameProjectError.limitExceeded("distributionEntries") }
        }
        files.sort()

        let lower = Set(files.map { $0.lowercased() })
        let baseNames = Set(files.map { ($0 as NSString).lastPathComponent.lowercased() })

        // Engine detection from published-game markers (specific first).
        var engine: RPGEngine? = nil
        let has = { (names: [String]) in names.contains(where: { baseNames.contains($0) }) }
        let hasExt = { (ext: String) in files.contains(where: { $0.lowercased().hasSuffix("." + ext) }) }
        if hasExt("rgss3a") || has(["rgss3.dll"]) {
            engine = .rpgMakerVXAce
        } else if hasExt("rgss2a") || has(["rgss2.dll"]) {
            engine = .rpgMakerVX
        } else if hasExt("rgssad") || baseNames.contains(where: { $0.hasPrefix("rgss") && $0.hasSuffix(".dll") }) {
            engine = .rpgMakerXP
        } else if files.contains(where: { $0.lowercased() == "js/rmmz_core.js" }) || has(["rmmz_managers.js"]) {
            engine = .rpgMakerMZ
        } else if files.contains(where: { $0.lowercased() == "js/rpg_core.js" }) || has(["rpg_core.js"]) {
            engine = .rpgMakerMV
        } else if hasExt("rvdata2") {
            engine = .rpgMakerVXAce
        } else if hasExt("rvdata") {
            engine = .rpgMakerVX
        } else if hasExt("rxdata") {
            engine = .rpgMakerXP
        } else if lower.contains("data/system.json") {
            engine = .rpgMakerMV // MV/MZ data without runtime scripts; treated as MV-family JSON data
        }

        // Classify per file group.
        for path in files {
            let name = (path as NSString).lastPathComponent.lowercased()
            var state = states[path] ?? [.importable]
            if name.hasSuffix(".rgssad") || name.hasSuffix(".rgss2a") || name.hasSuffix(".rgss3a") {
                state.insert(.encrypted)
                diagnostics.append(.init(severity: .warning, code: .encryptedArchivePresent, path: path,
                    detail: "Encrypted RGSS archive; contents are preserved on import but not opened. Data inside is not readable or editable until the archive is handled separately."))
            }
            if name.hasSuffix(".exe") || name.hasSuffix(".dll") {
                state.insert(.nativeBinary)
                if name.hasPrefix("rgss") {
                    diagnostics.append(.init(severity: .blocking, code: .nativeRuntimeRequired, path: path,
                        detail: "Native RGSS runtime library; RPG Maker XP/VX/VX Ace gameplay is not available on this platform and the library is never executed."))
                }
            }
            if name.hasSuffix(".rxdata") || name.hasSuffix(".rvdata") || name.hasSuffix(".rvdata2") {
                state.insert([.readable, .editable])
                diagnostics.append(.init(severity: .info, code: .readableDataPresent, path: path,
                    detail: "Plain RPG Maker data file; readable and editable through the native data adapters."))
            }
            if path.lowercased().hasPrefix("data/") && name.hasSuffix(".json") {
                state.insert([.readable, .editable])
            }
            if name.hasSuffix(".png") {
                // MV/MZ "encryption" mangles asset headers; check the PNG signature.
                let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent(path))
                if let handle {
                    defer { try? handle.close() }
                    if let header = try? handle.read(upToCount: 8),
                       header != Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
                        state.insert(.encrypted)
                        diagnostics.append(.init(severity: .info, code: .encryptedAssetsPresent, path: path,
                            detail: "Image lacks a PNG signature (typical of RPG Maker MV/MZ asset encryption); preserved as-is, not decoded."))
                    }
                }
            }
            states[path] = state
        }

        // Game.ini: RTP references and title.
        if let ini = files.first(where: { ($0 as NSString).lastPathComponent.lowercased() == "game.ini" }) {
            let content = (try? String(contentsOf: root.appendingPathComponent(ini), encoding: .utf8)) ?? ""
            for key in ["RTP1", "RTP2", "RTP3"] {
                if let value = iniValue(content, key: key), !value.isEmpty {
                    diagnostics.append(.init(severity: .warning, code: .rtpReferenced, path: ini,
                        detail: "Game.ini references RTP package \(key)=\(value); assets from that package are not redistributable and are not present in this folder. Missing references are reported at use sites, never bundled."))
                }
            }
        }

        // Presence checks.
        let dataFiles = files.filter { $0.lowercased().hasPrefix("data/") }
        let hasScripts = files.contains(where: {
            let name = ($0 as NSString).lastPathComponent.lowercased()
            return name == "scripts.rxdata" || name == "scripts.rvdata" || name == "scripts.rvdata2"
        })
        let hasEncryptedArchive = files.contains(where: {
            let name = ($0 as NSString).lastPathComponent.lowercased()
            return name.hasSuffix(".rgssad") || name.hasSuffix(".rgss2a") || name.hasSuffix(".rgss3a")
        })
        if engine != nil, dataFiles.isEmpty, hasEncryptedArchive {
            diagnostics.append(.init(severity: .blocking, code: .dataMissing, path: nil,
                detail: "No plain Data folder; project data is inside an encrypted archive. Import still copies every file, but nothing is readable or editable yet."))
        }
        if (engine == .rpgMakerXP || engine == .rpgMakerVX || engine == .rpgMakerVXAce), !hasScripts, !hasEncryptedArchive {
            diagnostics.append(.init(severity: .warning, code: .scriptsMissing, path: nil,
                detail: "No Scripts data file found; the original Ruby script sources are unavailable. Data files remain editable."))
        }
        if engine == nil {
            diagnostics.append(.init(severity: .info, code: .noProjectMarkers, path: nil,
                detail: "No RPG Maker project markers found; the folder can still be imported as an original game project with all files preserved."))
        }
        if engine == .rpgMakerMV || engine == .rpgMakerMZ {
            let hasCore = files.contains(where: { $0.lowercased().hasSuffix("rpg_core.js") || $0.lowercased().hasSuffix("rmmz_core.js") })
            if hasCore, !dataFiles.isEmpty {
                diagnostics.append(.init(severity: .info, code: .playableWebBundle, path: nil,
                    detail: "JavaScript runtime and data are present; this distribution is a candidate for WebKit playback through the existing game player once packaged."))
            }
        }
        return RPGDistributionInspection(engine: engine, files: files, fileStates: states, diagnostics: diagnostics)
    }

    private static func iniValue(_ content: String, key: String) -> String? {
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(key.lowercased()) else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            return trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
