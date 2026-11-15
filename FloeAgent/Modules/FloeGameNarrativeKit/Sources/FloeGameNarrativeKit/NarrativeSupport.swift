// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore
import FloeGameTouch

/// Per-engine integration facts the host needs before registering an adapter.
/// Values describe the actual prepared runtime/SDK bytes in this package; they
/// never grant permissions and they cannot be decoded from project manifests.
public struct NarrativeEngineProfile: Sendable {
    public let engine: GameEngineID
    /// Upstream runtime/compiler version these adapters were verified against.
    public let runtimeVersion: String
    /// Upstream source identity (URL + commit/version) used for the prepared resources.
    public let upstream: String
    /// Top-level engine/runtime license only. Conditional engines also carry a
    /// selected transitive notice bundle described by `licenseBundle`.
    public let license: String
    /// Human-readable identity of the selected transitive notices that must
    /// travel with artifacts. nil when the top-level license is the complete
    /// prepared set (inkjs, microStudio).
    public let licenseBundle: String?
    /// True when `buildArtifact` requires the prepared notice bundle and fails
    /// closed if it is missing.
    public let licenseBundleRequired: Bool
    public let licenseURL: String
    /// Artifact entry file, relative to the built artifact folder.
    public let entry: String
    /// True when the ready bridge exposes `window.FloeGame.input`.
    public let supportsInput: Bool
    /// True when the ready bridge exposes `window.FloeGame.choose`.
    public let supportsChoose: Bool
    /// True when the ready bridge exposes `window.FloeGame.pointer`.
    public let supportsPointer: Bool
    /// True when snapshot()/restore(state) are backed by real engine state.
    public let supportsState: Bool
    /// Documented state contract (what snapshot() captures and restore() needs).
    public let stateContract: String
    /// CSP additions required beyond `GameWebRuntimePolicy` for this engine. Empty
    /// for every engine here: the fixed per-engine policy already covers wasm,
    /// JS evaluation and workers; all engines run fully offline from same-artifact
    /// resources (connect-src 'self', frame-src 'none').
    public let requiredCSPAdditions: [String]
    /// MIME types this engine's artifact needs beyond `GameWebArtifactPackage`'s table.
    public let requiredMIMETypes: [String: String]
}

public enum NarrativeAdapterError: Error, Equatable, Sendable {
    case destinationExists
    case invalidProject(String)
    case missingResource(String)
    case resourceChanged(String)
    case corruptCart(String)
    case unsupportedFormat(String)
    case io(String)
}

/// Project keyboard declaration (`floe-inputs.json`). Keys are fixed
/// `GameKeyboardKey` raw values ("left", "z", "enter") or DOM codes ("KeyZ").
/// It describes the adapter template's real key bindings; it never grants
/// commands, evaluators or native access, and imported projects may customize
/// their own buttons through the host.
public enum NarrativeInputs {
    public static let fileName = "floe-inputs.json"

    public struct Movement: Codable, Sendable, Equatable {
        public let left: [String]
        public let right: [String]
        public let up: [String]
        public let down: [String]
        public init(left: [String], right: [String], up: [String], down: [String]) {
            self.left = left; self.right = right; self.up = up; self.down = down
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(left: try values.decodeIfPresent([String].self, forKey: .left) ?? [],
                      right: try values.decodeIfPresent([String].self, forKey: .right) ?? [],
                      up: try values.decodeIfPresent([String].self, forKey: .up) ?? [],
                      down: try values.decodeIfPresent([String].self, forKey: .down) ?? [])
        }
        private enum CodingKeys: String, CodingKey { case left, right, up, down }
    }

    public struct Button: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let keys: [String]
        public init(id: String, label: String, keys: [String]) {
            self.id = id; self.label = label; self.keys = keys
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try values.decode(String.self, forKey: .id),
                      label: try values.decodeIfPresent(String.self, forKey: .label) ?? "",
                      keys: try values.decode([String].self, forKey: .keys))
        }
        private enum CodingKeys: String, CodingKey { case id, label, keys }
    }

    public struct Declaration: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let engine: String
        public let movement: Movement
        public let buttons: [Button]
        public init(schemaVersion: Int = 1, engine: String, movement: Movement, buttons: [Button]) {
            self.schemaVersion = schemaVersion; self.engine = engine
            self.movement = movement; self.buttons = buttons
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
                      engine: try values.decode(String.self, forKey: .engine),
                      movement: try values.decodeIfPresent(Movement.self, forKey: .movement)
                          ?? .init(left: [], right: [], up: [], down: []),
                      buttons: try values.decodeIfPresent([Button].self, forKey: .buttons) ?? [])
        }
        private enum CodingKeys: String, CodingKey { case schemaVersion, engine, movement, buttons }
    }

    /// One key per direction/button entry: `keys` is a simultaneous chord, so
    /// alternate physical keys must never be listed together. Additional in-game
    /// alternates handled by the engine are documented separately, not encoded
    /// as chords here.
    public static func defaultDeclaration(for engine: GameEngineID) -> Declaration {
        switch engine {
        case .ink, .twine:
            return Declaration(engine: engine.rawValue,
                movement: .init(left: [], right: [], up: ["up"], down: ["down"]),
                buttons: [.init(id: "confirm", label: "Enter", keys: ["enter"])])
        case .wasm4:
            return Declaration(engine: engine.rawValue,
                movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
                buttons: [.init(id: "confirm", label: "X", keys: ["x"]),
                          .init(id: "cancel", label: "Z", keys: ["z"])])
        case .tic80:
            return Declaration(engine: engine.rawValue,
                movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
                buttons: [.init(id: "confirm", label: "Z", keys: ["z"]),
                          .init(id: "cancel", label: "X", keys: ["x"]),
                          .init(id: "action3", label: "A", keys: ["a"]),
                          .init(id: "action4", label: "S", keys: ["s"])])
        case .microStudio:
            return Declaration(engine: engine.rawValue,
                movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
                buttons: [])
        default:
            return Declaration(engine: engine.rawValue,
                movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
                buttons: [])
        }
    }

    public static func encoded(_ declaration: Declaration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(declaration)
    }

    public static func encodedDefault(for engine: GameEngineID) throws -> Data {
        try encoded(defaultDeclaration(for: engine))
    }

    public enum DeclarationStatus: Sendable, Equatable {
        case absent
        case invalid(String)
        case valid(Declaration)
    }

    /// Same bounded declaration contract as the native keyboard settings UI.
    public static let maximumDeclarationBytes = GameTouchProjectBindings.maximumDeclarationBytes

    /// Inspects the raw project file without allocating unbounded data, refusing
    /// symlinks, non-regular files and oversize content. A `.valid` result is a
    /// shared native keyboard validation, including custom IDs, optional labels,
    /// unbound axes and real key/chord limits. The raw file is never rewritten.
    public static func status(inProject project: URL, for engine: GameEngineID) -> DeclarationStatus {
        let url = project.appendingPathComponent(fileName)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .absent }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { return .invalid("symbolic link") }
        guard type == S_IFREG else { return .invalid("not a regular file") }
        guard info.st_size >= 0, info.st_size <= off_t(maximumDeclarationBytes) else {
            return .invalid("larger than \(maximumDeclarationBytes) bytes")
        }
        guard let data = try? NarrativeBoundedFile.read(url, maximum: maximumDeclarationBytes) else {
            return .invalid("unreadable")
        }
        guard let declaration = try? JSONDecoder().decode(Declaration.self, from: data) else {
            return .invalid("invalid JSON shape")
        }
        guard declaration.schemaVersion == 1 else { return .invalid("unsupported schemaVersion") }
        guard declaration.engine == engine.rawValue else {
            return .invalid("declaration belongs to \(declaration.engine), not \(engine.rawValue)")
        }
        // Check original bytes as well: typed decoding cannot hide unknown
        // command-like fields from the shared native keyboard validator.
        guard (try? GameTouchProjectBindings(json: data, engine: engine)) != nil else {
            return .invalid("invalid keyboard keys, controls or fields")
        }
        return .valid(declaration)
    }

    /// The valid project declaration, or nil when absent/invalid.
    public static func declaration(inProject project: URL, for engine: GameEngineID) -> Declaration? {
        if case .valid(let declaration) = status(inProject: project, for: engine) { return declaration }
        return nil
    }

    public struct ArtifactResolution: Sendable {
        public let data: Data
        /// True when the project declaration was absent/invalid and the truthful
        /// engine default was used; `reason` says why.
        public let usedDefault: Bool
        public let reason: String?
    }

    /// Artifact declaration: a valid project file is copied byte-exact (raw file
    /// preserved); otherwise the engine default is used and the reason reported.
    public static func resolutionForArtifact(project: URL, engine: GameEngineID) throws -> ArtifactResolution {
        switch status(inProject: project, for: engine) {
        case .valid:
            let url = project.appendingPathComponent(fileName)
            let raw = try NarrativeBoundedFile.read(url, maximum: maximumDeclarationBytes)
            if let raw { return .init(data: raw, usedDefault: false, reason: nil) }
            return .init(data: try encodedDefault(for: engine), usedDefault: true, reason: "unreadable")
        case .absent:
            return .init(data: try encodedDefault(for: engine), usedDefault: true, reason: nil)
        case .invalid(let reason):
            return .init(data: try encodedDefault(for: engine), usedDefault: true, reason: reason)
        }
    }

    static func artifactFile(project: URL, engine: GameEngineID) throws -> Data {
        try resolutionForArtifact(project: project, engine: engine).data
    }
}

/// Bounded descriptor-relative file read: `O_NOFOLLOW` refuses a symlink at the
/// final component, `fstat` refuses non-regular/oversize files, and the buffer
/// is allocated only after those checks.
enum NarrativeBoundedFile {
    static func read(_ url: URL, maximum: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= off_t(maximum) else {
            throw NarrativeAdapterError.invalidProject("declaration is not a bounded regular file")
        }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NarrativeAdapterError.io("read declaration") }
                offset += count
            }
        }
        return data
    }
}

/// Identifier rules shared with the GameKit context contract (host-validated).
enum NarrativeValidation {
    static func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Minimal staged writer for component hosts: create temp, write, fsync, rename.
/// Mirrors the repository storage discipline without duplicating its CAS.
enum NarrativeWriter {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw NarrativeAdapterError.io("unsafe directory: " + url.lastPathComponent)
        }
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".narrative-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw NarrativeAdapterError.io("stage file: \(temporary.lastPathComponent)")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw NarrativeAdapterError.io("write: \(error.localizedDescription)")
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            throw NarrativeAdapterError.io("publish file: \(error.localizedDescription)")
        }
    }

    /// Publish a complete staged folder atomically at `target`.
    static func publish(stage: URL, to target: URL) throws {
        try directory(target.deletingLastPathComponent())
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) { throw NarrativeAdapterError.destinationExists }
        do {
            try manager.moveItem(at: stage, to: target)
        } catch {
            throw NarrativeAdapterError.io("publish: \(error.localizedDescription)")
        }
    }
}

/// Byte-level helpers shared by the fantasy-console cartridge builders.
enum NarrativeBytes {
    static func leb128(_ value: UInt32) -> [UInt8] {
        var result: [UInt8] = []
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            result.append(byte)
        } while remaining != 0
        return result
    }

    static func leb128(_ value: Int32) -> [UInt8] {
        var result: [UInt8] = []
        var more = true
        var current = value
        while more {
            var byte = UInt8(current & 0x7F)
            current >>= 7
            if (current == 0 && (byte & 0x40) == 0) || (current == -1 && (byte & 0x40) != 0) {
                more = false
            } else {
                byte |= 0x80
            }
            result.append(byte)
        }
        return result
    }
}

/// Bounded read-only project tree for import. Rejects symlinks and special
/// files; the host still owns File Provider grants and lifecycle leases.
struct NarrativeProjectTree {
    let root: URL
    let maximumEntries: Int
    let maximumBytes: Int

    init(root: URL, maximumEntries: Int = 10_000, maximumBytes: Int = 512 * 1_024 * 1_024) throws {
        guard root.isFileURL else { throw NarrativeAdapterError.invalidProject("non-file root") }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }

    /// All entries as relative paths, walked manually from each parent URL so a
    /// resolved `/var` vs `/private/var` prefix can never skew relative paths.
    func walk() throws -> [(path: String, directory: Bool)] {
        var result: [(String, Bool)] = []
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var total = 0
        func visit(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw NarrativeAdapterError.invalidProject("tree too deep") }
            // Full import: hidden and unknown files are retained. No name pruning;
            // traversal safety comes from real path components below.
            let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                           options: []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                guard result.count < maximumEntries else { throw NarrativeAdapterError.invalidProject("too many entries") }
                let values = try child.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else { throw NarrativeAdapterError.invalidProject("symlink: " + child.lastPathComponent) }
                let relative = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                // Only actual `.`/`..` path components are unsafe; ordinary names may
                // contain dots (e.g. "notes..bin") and are preserved verbatim.
                guard relative.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
                    throw NarrativeAdapterError.invalidProject("unsafe path component")
                }
                if values.isDirectory == true {
                    result.append((relative, true))
                    try visit(child, prefix: relative, depth: depth + 1)
                } else if values.isRegularFile == true {
                    total += (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard total <= maximumBytes else { throw NarrativeAdapterError.invalidProject("project too large") }
                    result.append((relative, false))
                } else {
                    throw NarrativeAdapterError.invalidProject("unsupported file: " + relative)
                }
            }
        }
        try visit(root, prefix: "", depth: 0)
        return result.sorted { $0.0 < $1.0 }
    }

    func read(_ relative: String) throws -> Data {
        let url = root.appendingPathComponent(relative)
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw NarrativeAdapterError.invalidProject("unsafe path") }
        return try Data(contentsOf: url)
    }
}

enum NarrativeLicenses {
    static func componentNotice(engine: GameEngineID,
                                supportFiles: [String],
                                originalGameFiles: [String],
                                runtimeFiles: [String],
                                runtimeSourceFiles: [String],
                                runtimeNotices: [NarrativeArtifactEntry]) -> String {
        let engineSupport = supportFiles.filter { $0 != "index.html" }
        let floeFiles = (engine == .twine ? engineSupport : ["index.html"] + engineSupport)
            .map { "  " + $0 + "\n" }.joined()
        let gameFiles = originalGameFiles.isEmpty ? "  (none)\n" : originalGameFiles.map { "  " + $0 + "\n" }.joined()
        let runtimes = runtimeFiles.isEmpty ? "  (none)\n" : runtimeFiles.map { "  " + $0 + "\n" }.joined()
        let sources = runtimeSourceFiles.isEmpty ? "  (none)\n" : runtimeSourceFiles.map { "  " + $0 + "\n" }.joined()
        let noticeFiles = runtimeNotices.filter {
            $0.role == .thirdPartyLicense || $0.role == .thirdPartyNotice
                || $0.role == .thirdPartySourceOffer
        }.map { "  " + $0.path + " — " + $0.license + "\n" }.joined()
        let twineNote = engine == .twine
            ? "\nThe Twine HTML shell is the upstream SugarCube published-page template\n(BSD-2-Clause); its extracted engine/libraries are unchanged upstream bytes.\n"
            : ""
        let tic80SourceNote = engine == .tic80
            ? "\nTIC-80 source status: the exact selected TIC-80/blip_buf source archives,\nsidecars, submodule pins and SOURCE-OFFER record are bundled as-is under\nsource/tic80 and licenses/. This is not a full LGPL clearance or relink proof;\nsubmodule contents, exact emsdk and relink remain conditional and unverified.\n"
            : ""
        return """
        FloeGameNarrativeKit generated Web support
        SPDX-License-Identifier: MPL-2.0

        Floe-authored files in this artifact (MPL-2.0):
        \(floeFiles)
        These files contain reusable Floe support code and, where listed above,
        the Floe HTML shell only. They do not contain the original game's story
        text, source code, map data, cartridge bytes or assets.\(twineNote)

        Original game content in this artifact (NOT MPL-2.0; each file retains
        the project's own license, which may be custom or all rights reserved):
        \(gameFiles)
        Third-party runtime files (unchanged upstream bytes; own licenses):
        \(runtimes)
        Third-party selected source bundle (exact bytes; separate licenses):
        \(sources)
        Selected third-party notice/license files:
        \(noticeFiles.isEmpty ? "  (none beyond the top-level engine notice)\n" : noticeFiles)
        Full MPL text: licenses/FLOE-MPL-2.0.txt and
        https://www.mozilla.org/MPL/2.0/ .

        Source availability: the exact readable Source Code Form of the Floe
        support files is bundled in this artifact under support/ (and
        index.html where it is the Floe shell). This artifact does not assert
        a public URL or a complete SDK source handoff; that SDK/source
        distribution is separate. The file-by-file role/hash manifest is
        floe-artifact.json. This notice does not relicense imported game
        content or third-party runtimes.\(tic80SourceNote)
        """
    }

    /// Adds the full MPL text, the generated file-boundary notice, the exact
    /// starter MIT notice (only for an actual Floe starter) and original notice
    /// bytes under `licenses/original/`.
    static func addArtifactNotices(to builder: inout NarrativeArtifactBuilder, engine: GameEngineID,
                                   originals: [NarrativeOriginalNotices.Notice]) throws {
        guard let url = Bundle.module.url(forResource: "MPL-2.0", withExtension: "txt") else {
            throw NarrativeAdapterError.missingResource("MPL-2.0 license text")
        }
        let supportFiles = ([builder.entry] + builder.floeSupportFiles).sorted()
        let runtimeNotices = builder.entries(for: [.thirdPartyLicense, .thirdPartyNotice,
                                                      .thirdPartySourceOffer])
        let generated = componentNotice(engine: engine, supportFiles: supportFiles,
                                        originalGameFiles: builder.originalGameFiles,
                                        runtimeFiles: builder.thirdPartyRuntimeFiles,
                                        runtimeSourceFiles: builder.thirdPartySourceFiles,
                                        runtimeNotices: runtimeNotices)
        try builder.add(path: "licenses/FLOE-COMPONENT-MPL-2.0.txt", data: Data(generated.utf8),
                        role: .floeNotice, license: "MPL-2.0")
        try builder.add(path: "licenses/FLOE-MPL-2.0.txt", data: try Data(contentsOf: url),
                        role: .floeLicense, license: "MPL-2.0")
        // Retain an existing, exact Floe starter notice. Never manufacture one
        // for an imported game, or replace a modified/custom original notice.
        if let original = originals.first(where: {
            $0.path == "licenses/FLOE-STARTER-MIT.txt" && $0.data == Data(starterMIT.utf8)
        }) {
            try builder.add(path: "licenses/FLOE-STARTER-MIT.txt", data: original.data,
                            role: .starterLicense, license: "MIT")
        }
        for notice in originals {
            try builder.add(path: "licenses/original/" + notice.path, data: notice.data,
                            role: .originalNotice, license: "original project terms (unchanged)")
        }
    }

    /// The newly authored Floe starter content is additionally MIT-licensed so
    /// exporting a starter does not relicense a user's whole game MPL.
    static let starterMIT = """
    MIT License

    Copyright (c) 2026 Floe contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}

/// Read-only build tree: unlike the full-import walker it never follows a
/// symlink and never fails the whole project because of an unrelated link.
/// Callers decide whether a specific symlink is a hard diagnostic (source or
/// packaged resource) or simply ignored (host-managed metadata such as a
/// symlinked `floe-inputs.json`). Directory symlinks are never traversed.
struct NarrativeBuildTree {
    struct Entry: Sendable, Equatable {
        let path: String
        let directory: Bool
        let symlink: Bool
        let regular: Bool
        let bytes: Int
    }

    let root: URL
    let maximumEntries: Int

    init(root: URL, maximumEntries: Int = 20_000) throws {
        guard root.isFileURL else { throw NarrativeAdapterError.invalidProject("non-file root") }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumEntries = maximumEntries
    }

    func walk() throws -> [Entry] {
        var result: [Entry] = []
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        func visit(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw NarrativeAdapterError.invalidProject("tree too deep") }
            let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                           options: []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                guard result.count < maximumEntries else { throw NarrativeAdapterError.invalidProject("too many entries") }
                let values = try child.resourceValues(forKeys: Set(keys))
                let relative = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                guard relative.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
                    throw NarrativeAdapterError.invalidProject("unsafe path component")
                }
                if values.isSymbolicLink == true {
                    // Recorded but never followed: callers can diagnose a link at
                    // a source/resource path, and unrelated links stay harmless.
                    result.append(.init(path: relative, directory: false, symlink: true, regular: false, bytes: 0))
                } else if values.isDirectory == true {
                    result.append(.init(path: relative, directory: true, symlink: false, regular: false, bytes: 0))
                    try visit(child, prefix: relative, depth: depth + 1)
                } else if values.isRegularFile == true {
                    result.append(.init(path: relative, directory: false, symlink: false, regular: true,
                                        bytes: (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                } else {
                    result.append(.init(path: relative, directory: false, symlink: false, regular: false, bytes: 0))
                }
            }
        }
        try visit(root, prefix: "", depth: 0)
        return result.sorted { $0.path < $1.path }
    }

    /// Descriptor-relative, `O_NOFOLLOW` bounded read. The relative path must
    /// come from `walk()`; no caller-supplied absolute path is accepted.
    func read(_ relative: String, maximum: Int) throws -> Data {
        guard !relative.isEmpty,
              relative.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw NarrativeAdapterError.invalidProject("unsafe path")
        }
        let url = root.appendingPathComponent(relative)
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw NarrativeAdapterError.invalidProject("unsafe path")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw NarrativeAdapterError.invalidProject("symbolic link: " + relative)
            }
            throw NarrativeAdapterError.invalidProject("unreadable: " + relative)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= off_t(maximum) else {
            throw NarrativeAdapterError.invalidProject("not a bounded regular file: " + relative)
        }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NarrativeAdapterError.invalidProject("unreadable: " + relative) }
                offset += count
            }
        }
        return data
    }
}

/// Deterministic JSON/JS script-block literals for generated artifacts.
/// `<`, `>`, `&`, U+2028 and U+2029 are escaped so user source or resource
/// names can never terminate a `<script>` element or introduce a line break.
enum NarrativeJSON {
    static func literal(_ object: Any, allowFragments: Bool = false) throws -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if allowFragments { options.insert(.fragmentsAllowed) }
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        return escapeForScriptBlock(String(decoding: data, as: UTF8.self))
    }

    static func escapeForScriptBlock(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// True only for a project created by the Floe starter templates: the project
/// metadata must carry the marker and the actual entry/source text must still
/// contain the starter's original notice. Imported user projects are never
/// assigned the Floe starter MIT notice.
enum NarrativeStarter {
    static let templateMarker = "floe-starter"

    static func isFloeStarter(project: URL, sourceTexts: [String], contentMarker: String) -> Bool {
        guard let data = try? NarrativeBoundedFile.read(project.appendingPathComponent("project.json"),
                                                         maximum: 256 * 1_024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["template"] as? String == templateMarker else { return false }
        return sourceTexts.contains { $0.contains(contentMarker) }
    }
}

/// Bounded preservation of an imported project's own license/NOTICE/COPYING
/// files inside a built artifact. Files are copied byte-exact under
/// `licenses/original/<original relative path>` so they can never overwrite
/// the engine or generated-component notices. Original project bytes are never
/// modified, and the copies are not executed.
enum NarrativeOriginalNotices {
    static let maximumFiles = 32
    static let maximumFileBytes = 256 * 1_024
    static let maximumTotalBytes = 1 * 1_024 * 1_024

    static let tokens = ["license", "licence", "notice", "copying", "copyright",
                         "unlicense", "attribution", "third-party", "thirdparty", "third_party", "readme"]
    static let directories: Set<String> = ["licenses", "license", "licences", "notices", "legal"]

    struct Notice: Sendable {
        let path: String
        let data: Data
    }

    /// Discovers and reads bounded original notices. Symlinks and special files
    /// are skipped (never followed); exceeding the bounds is an explicit error
    /// rather than a silent drop.
    static func discover(projectAt project: URL) throws -> [Notice] {
        let tree = try NarrativeBuildTree(root: project)
        let entries = try tree.walk()
        var notices: [Notice] = []
        var total = 0
        for entry in entries where !entry.directory && entry.regular && !entry.symlink {
            guard isNotice(entry.path) else { continue }
            guard entry.bytes <= maximumFileBytes else {
                throw NarrativeAdapterError.invalidProject("notice too large: " + entry.path)
            }
            total += entry.bytes
            guard total <= maximumTotalBytes else {
                throw NarrativeAdapterError.invalidProject("notice files exceed bounds")
            }
            guard notices.count < maximumFiles else {
                throw NarrativeAdapterError.invalidProject("too many notice files")
            }
            notices.append(Notice(path: entry.path, data: try tree.read(entry.path, maximum: maximumFileBytes)))
        }
        return notices.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// Copies original notices into `stage/licenses/original/...` and returns
    /// the artifact-relative paths. Never overwrites an existing artifact file.
    @discardableResult
    static func copy(from project: URL, into stage: URL) throws -> [String] {
        try copy(discover(projectAt: project), into: stage)
    }

    @discardableResult
    static func copy(_ notices: [Notice], into stage: URL) throws -> [String] {
        var paths: [String] = []
        for notice in notices {
            let relative = "licenses/original/" + notice.path
            let output = stage.appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw NarrativeAdapterError.invalidProject("notice collision: " + relative)
            }
            try NarrativeWriter.directory(output.deletingLastPathComponent())
            try NarrativeWriter.atomicWrite(notice.data, to: output)
            paths.append(relative)
        }
        return paths
    }

    static func isNotice(_ path: String) -> Bool {
        let components = path.split(separator: "/").map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        guard let basename = components.last, !basename.isEmpty else { return false }
        if components.dropLast().contains(where: { directories.contains($0) }) { return true }
        return tokens.contains { token in
            basename == token || basename.hasPrefix(token + ".") || basename.hasPrefix(token + "-")
                || basename.hasPrefix(token + "_")
        }
    }
}
