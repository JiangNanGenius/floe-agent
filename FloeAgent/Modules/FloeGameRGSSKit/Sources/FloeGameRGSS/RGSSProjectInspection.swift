// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct RGSSProjectInspection: Codable, Equatable, Sendable {
    public let engine: GameEngineID
    public let version: RGSSVersion
    public let markerPath: String?
    public let scriptsPath: String
    public let scriptsPresent: Bool
    public let encryptedArchives: [String]
    public let nativeExecutables: [String]
    public let nativeLibraries: [String]
    public let rtpReference: String?
    public let libraryReference: String?
    public let audioUnsupported: [String]
    public let fontFiles: [String]
    public let pluginFiles: [String]
    public let unknownRootEntries: [String]
    public let webAvailability: RGSSWebAvailability
    public let guestAvailability: RGSSGuestAvailability
    public let warnings: [String]

    public init(engine: GameEngineID, version: RGSSVersion, markerPath: String?,
                scriptsPath: String, scriptsPresent: Bool, encryptedArchives: [String],
                nativeExecutables: [String], nativeLibraries: [String], rtpReference: String?,
                libraryReference: String?, audioUnsupported: [String], fontFiles: [String],
                pluginFiles: [String], unknownRootEntries: [String],
                webAvailability: RGSSWebAvailability, guestAvailability: RGSSGuestAvailability,
                warnings: [String]) {
        self.engine = engine
        self.version = version
        self.markerPath = markerPath
        self.scriptsPath = scriptsPath
        self.scriptsPresent = scriptsPresent
        self.encryptedArchives = encryptedArchives
        self.nativeExecutables = nativeExecutables
        self.nativeLibraries = nativeLibraries
        self.rtpReference = rtpReference
        self.libraryReference = libraryReference
        self.audioUnsupported = audioUnsupported
        self.fontFiles = fontFiles
        self.pluginFiles = pluginFiles
        self.unknownRootEntries = unknownRootEntries
        self.webAvailability = webAvailability
        self.guestAvailability = guestAvailability
        self.warnings = warnings
    }

    /// Source preservation is a repository guarantee, not a play claim. Unknown
    /// files, plugins and native binaries remain untouched in the original.
    public var preservesOriginalBytes: Bool { true }
}

public struct RGSSInspectionLimits: Sendable {
    public let maximumRootEntries: Int
    public let maximumAudioEntries: Int
    public let maximumPluginEntries: Int
    public let maximumMetadataBytes: Int

    public init(maximumRootEntries: Int = 2_048, maximumAudioEntries: Int = 5_000,
                maximumPluginEntries: Int = 1_024, maximumMetadataBytes: Int = 65_536) throws {
        guard (1...100_000).contains(maximumRootEntries),
              (1...100_000).contains(maximumAudioEntries),
              (1...100_000).contains(maximumPluginEntries),
              (1...1_048_576).contains(maximumMetadataBytes) else {
            throw RGSSRuntimeError.invalidArtifact("invalid inspection limits")
        }
        self.maximumRootEntries = maximumRootEntries
        self.maximumAudioEntries = maximumAudioEntries
        self.maximumPluginEntries = maximumPluginEntries
        self.maximumMetadataBytes = maximumMetadataBytes
    }
}

/// Read-only compatibility inspection. It never executes Ruby/EXE/DLL, never
/// decrypts an RGSS archive and never deletes or rewrites project bytes.
public struct RGSSCompatibilityInspector: Sendable {
    public let limits: RGSSInspectionLimits

    public init(limits: RGSSInspectionLimits? = nil) {
        self.limits = limits ?? (try! RGSSInspectionLimits())
    }

    public func inspect(rootURL: URL) throws -> RGSSProjectInspection {
        guard rootURL.isFileURL else { throw RGSSRuntimeError.invalidArtifact("root is not a file URL") }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RGSSRuntimeError.missingProjectMarker
        }
        let names = try directoryNames(root, maximum: limits.maximumRootEntries)
        let candidates = try GameProjectInspector().inspect(rootURL: root).candidates
        let markerMap: [String: GameEngineID] = [
            "rxproj": .rpgMakerXP, "rvproj": .rpgMakerVX, "rvproj2": .rpgMakerVXAce
        ]
        var markerPath: String?
        var engine: GameEngineID?
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            if let value = markerMap[ext] {
                markerPath = name
                engine = value
                break
            }
        }
        if engine == nil, let first = candidates.first?.engine, RGSSEngineProfiles.isRGSS(first) {
            engine = first
        }
        guard let engine else { throw RGSSRuntimeError.missingProjectMarker }
        let profile = try RGSSEngineProfiles.profile(for: engine)
        let scriptExists = try regularFileExists(root.appendingPathComponent(profile.scriptsPath))
        guard scriptExists else { throw RGSSRuntimeError.missingScripts(profile.scriptsPath) }

        let encrypted = names.filter { ["game.rgssad", "game.rgss2a", "game.rgss3a"].contains($0.lowercased()) }
        let executables = names.filter { ($0 as NSString).pathExtension.lowercased() == "exe" }
        let libraries = names.filter { ($0 as NSString).pathExtension.lowercased() == "dll" }
        let ini = try readGameINI(root.appendingPathComponent("Game.ini"))
        let audio = try scanExtensions(root.appendingPathComponent("Audio"), extensions: ["wma", "mid", "midi"],
                                       maximum: limits.maximumAudioEntries)
        let fonts = try scanExtensions(root.appendingPathComponent("Fonts"), extensions: nil,
                                       maximum: 512)
        let plugins = try scanExtensions(root.appendingPathComponent("Plugins"), extensions: nil,
                                         maximum: limits.maximumPluginEntries)
        let known: Set<String> = [
            "data", "graphics", "audio", "fonts", "plugins", "system", "game.ini", "game.rxproj",
            "game.rvproj", "game.rvproj2", "game.exe", "game.rgssad", "game.rgss2a", "game.rgss3a",
            "floe-inputs.json", "rgss.rb"
        ]
        let unknown = names.filter { name in
            let lower = name.lowercased()
            return !known.contains(lower) && !lower.hasSuffix(".dll") && !lower.hasSuffix(".exe")
                && !lower.hasPrefix(".")
        }.prefix(64).map { $0 }

        let support = try RGSSRuntimeMatrix.support(for: engine)
        var warnings: [String] = []
        if !encrypted.isEmpty {
            warnings.append("Encrypted RGSS archives are preserved but not decrypted; they cannot be loaded by the Web adapter.")
        }
        if !executables.isEmpty || !libraries.isEmpty {
            warnings.append("Native EXE/DLL files are preserved and never executed.")
        }
        if let rtp = ini.rtp, !rtp.isEmpty {
            warnings.append("Game.ini references RTP assets; no RTP is bundled and missing assets are not invented.")
        }
        if !audio.isEmpty {
            warnings.append("WMA/MIDI audio is not decoded by the Web adapter; convert in an explicit project edit or use the Linux guest.")
        }
        if !fonts.isEmpty {
            warnings.append("Project fonts remain in the repository; the reviewed engine uses its built-in font when a font is unavailable.")
        }
        if !plugins.isEmpty {
            warnings.append("Plugin/script files are preserved as source; compatibility depends on the bytes and is not inferred.")
        }
        if !unknown.isEmpty {
            warnings.append("Unknown top-level entries are preserved; no recognition gate pruned them.")
        }
        if support.requiresProjectReview {
            warnings.append("Imported games may require an explicit event-loop/script port; a data edit or successful import is not proof of play.")
        }
        return .init(engine: engine, version: profile.version, markerPath: markerPath,
                     scriptsPath: profile.scriptsPath, scriptsPresent: true,
                     encryptedArchives: encrypted, nativeExecutables: executables,
                     nativeLibraries: libraries, rtpReference: ini.rtp, libraryReference: ini.library,
                     audioUnsupported: audio, fontFiles: fonts, pluginFiles: plugins,
                     unknownRootEntries: unknown, webAvailability: support.web,
                     guestAvailability: support.guest, warnings: warnings)
    }

    private func directoryNames(_ url: URL, maximum: Int) throws -> [String] {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RGSSRuntimeError.missingProjectMarker }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard names.count <= maximum else { throw RGSSRuntimeError.invalidArtifact("too many root entries") }
        return names.sorted()
    }

    private func regularFileExists(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        } catch { return false }
    }

    private func readGameINI(_ url: URL) throws -> (library: String?, rtp: String?) {
        guard try regularFileExists(url) else { return (nil, nil) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= limits.maximumMetadataBytes else {
            throw RGSSRuntimeError.invalidArtifact("Game.ini is too large")
        }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            return (nil, nil)
        }
        var library: String?, rtp: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let split = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<split].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if key == "library" { library = value }
            if key == "rtp" { rtp = value }
        }
        return (library, rtp)
    }

    private func scanExtensions(_ directory: URL, extensions: Set<String>?, maximum: Int) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return [] }
        var result: [String] = []
        var seen = 0
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        for case let file as URL in enumerator {
            seen += 1
            if seen > maximum { break }
            let item = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard item.isRegularFile == true, item.isSymbolicLink != true else { continue }
            if let extensions, !extensions.contains(file.pathExtension.lowercased()) { continue }
            result.append(file.path.replacingOccurrences(of: directory.path + "/", with: ""))
            if result.count >= 64 { break }
        }
        return result.sorted()
    }
}
