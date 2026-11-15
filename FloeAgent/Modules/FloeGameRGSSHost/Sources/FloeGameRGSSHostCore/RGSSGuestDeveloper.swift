// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameDeveloperCore
import FloeGameRGSS
import FloeRPGCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Host path mapping supplied by the Linux adapter. It maps only guest paths
/// under the environment's declared 9p mounts; it is never a filesystem
/// traversal primitive.
public protocol RGSSGuestHostPathMapping: Sendable {
    func hostURL(forGuestPath path: String) throws -> URL
}

/// Existing scoped guest file service used by the developer overlay's file
/// RPC. Every operation is confined to the overlay directory of one run.
public struct RGSSGuestDeveloperFilePort: GameDeveloperGuestFilePort, Sendable {
    private let mapping: any RGSSGuestHostPathMapping
    private let limits: Int

    public init(mapping: any RGSSGuestHostPathMapping, maximumBytes: Int = 4 * 1_024 * 1_024) {
        self.mapping = mapping
        self.limits = max(1_024, min(maximumBytes, 16 * 1_024 * 1_024))
    }

    public func writeFile(_ data: Data, relativePath: String,
                          directory: GameDeveloperGuestDirectory) async throws {
        guard data.count <= limits, Self.isSafe(relativePath) else {
            throw GameDeveloperError.payloadTooLarge("guest file")
        }
        let root = try mapping.hostURL(forGuestPath: directory.absolutePath)
        let destination = try destination(root: root, relativePath: relativePath)
        try RGSSGuestAtomicFile.write(data, to: destination, insideRoot: root)
    }

    public func readFile(relativePath: String, directory: GameDeveloperGuestDirectory,
                         maximumBytes: Int) async throws -> Data? {
        guard Self.isSafe(relativePath) else {
            throw GameDeveloperError.invalidRequest("guest file path")
        }
        let root = try mapping.hostURL(forGuestPath: directory.absolutePath)
        let file = try destination(root: root, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try RGSSGuestAtomicFile.read(file, maximumBytes: min(maximumBytes, limits))
    }

    public func removeFile(relativePath: String,
                           directory: GameDeveloperGuestDirectory) async throws {
        guard Self.isSafe(relativePath) else {
            throw GameDeveloperError.invalidRequest("guest file path")
        }
        let root = try mapping.hostURL(forGuestPath: directory.absolutePath)
        let file = try destination(root: root, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
        try FileManager.default.removeItem(at: file)
    }

    private func destination(root: URL, relativePath: String) throws -> URL {
        guard Self.isSafe(relativePath) else {
            throw GameDeveloperError.invalidRequest("guest file path")
        }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let file = root.appendingPathComponent(relativePath)
        let parent = file.deletingLastPathComponent().standardizedFileURL.path
        guard parent == rootPath || parent.hasPrefix(rootPath + "/") else {
            throw GameDeveloperError.invalidRequest("guest file escapes overlay")
        }
        return file
    }

    private static func isSafe(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else {
            return false
        }
        return !value.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

/// One-run developer menu attachment. The frozen developer transport talks to
/// the overlay through the existing guest file service; no shell, evaluator or
/// second runtime is created.
@MainActor
public final class RGSSGuestDeveloperHost {
    public let binding: GameDeveloperSessionBinding
    public let directory: GameDeveloperGuestDirectory
    public let transport: GameDeveloperRGSSGuestTransport
    public let session: GameDeveloperSession

    public init(
        staged: RGSSGuestStagedRun,
        guestRunDirectory: String,
        mapping: any RGSSGuestHostPathMapping
    ) throws {
        guard RGSSEngineProfiles.isRGSS(staged.request.engine) else {
            throw RGSSGuestRunError.developerOverlayUnsupported("not an RGSS engine")
        }
        let overlay = guestRunDirectory.hasSuffix("/")
            ? guestRunDirectory + "floe-developer"
            : guestRunDirectory + "/floe-developer"
        let directory = try GameDeveloperGuestDirectory(
            absolutePath: overlay, ownerToken: staged.request.id)
        let binding = GameDeveloperSessionBinding(
            projectID: staged.request.context.projectID,
            owner: staged.request.context.owner,
            savedRevision: staged.request.context.savedRevision,
            runID: staged.request.id,
            engine: staged.request.engine)
        let port = RGSSGuestDeveloperFilePort(mapping: mapping)
        let transport = try GameDeveloperRGSSGuestTransport(
            binding: binding, directory: directory, port: port)
        self.binding = binding
        self.directory = directory
        self.transport = transport
        self.session = try GameDeveloperSession(transport: transport)
    }

    public func attach() async throws {
        do {
            try await session.attach()
        } catch let error as RGSSGuestRunError {
            throw error
        } catch {
            throw RGSSGuestRunError.developerOverlayUnsupported(String(describing: error))
        }
    }

    public func detach() {
        transport.detach()
    }
}

/// Explicit developer overlay installer. It never edits the imported source in
/// place: `apply(to:)` changes only the owned run copy, while
/// `projectRevisionChanges` returns writes for a new repository revision.
public enum RGSSGuestDeveloperOverlay {
    public static let overlayRelativePath = "floe-developer/floe_developer.rb"
    public static let overlayEntryTitle = "Floe Developer"
    public static let overlayVersion = "1.0.0"

    public struct Plan: Sendable {
        public let engine: GameEngineID
        public let scriptPath: String
        public let changes: [GameFileChange]
        public let alreadyInstalled: Bool
        public let sourceDigest: String?
        public let notes: [String]
    }

    /// Reads the source archive and returns a new-revision write set. It does
    /// not write anything and it does not decrypt RGSSAD/EXE/DLL content.
    public static func projectRevisionChanges(
        sourceRoot: URL,
        engine: GameEngineID,
        overlayScript: Data
    ) throws -> Plan {
        guard !overlayScript.isEmpty, overlayScript.count <= 1_048_576 else {
            throw RGSSGuestRunError.developerOverlayUnsupported("overlay script is empty or too large")
        }
        let profile = try RGSSEngineProfiles.profile(for: engine)
        let scriptRelative = profile.scriptsPath
        let archiveURL = sourceRoot.appendingPathComponent(scriptRelative)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw RGSSGuestRunError.developerOverlayUnsupported(
                "loose \(scriptRelative) is required; encrypted archives are preserved but not decrypted")
        }
        let archive = try RGSSGuestSafeTree.readFile(
            rootURL: sourceRoot, relative: scriptRelative, maximumBytes: 64 * 1_024 * 1_024)
        let patched = try appendOverlay(to: archive, engine: engine)
        let digest = try RGSSGuestSafeTree.digest(rootURL: sourceRoot, limits: .default)
        var changes: [GameFileChange] = []
        if patched.changed {
            changes.append(.write(try GameRelativePath(scriptRelative), patched.data))
        }
        changes.append(.write(try GameRelativePath(overlayRelativePath), overlayScript))
        return Plan(engine: engine, scriptPath: scriptRelative, changes: changes,
                    alreadyInstalled: !patched.changed, sourceDigest: digest,
                    notes: patched.changed
                        ? ["A separate project revision adds the developer overlay; the original script archive is unchanged."]
                        : ["The developer overlay entry already exists; only the overlay file is refreshed."])
    }

    /// Applies the overlay to the disposable run copy. The source root is never
    /// touched; this is an explicit development action, not an automatic play
    /// requirement.
    @discardableResult
    public static func apply(to staged: RGSSGuestStagedRun,
                             overlayScript: Data) throws -> Plan {
        let plan = try projectRevisionChanges(sourceRoot: staged.runRoot,
                                              engine: staged.request.engine,
                                              overlayScript: overlayScript)
        for change in plan.changes {
            switch change {
            case .write(let path, let data, let executable):
                let destination = staged.runRoot.appendingPathComponent(path.value)
                try RGSSGuestAtomicFile.write(data, to: destination, insideRoot: staged.runRoot)
                if executable == true {
                    _ = chmod(destination.path, mode_t(0o700))
                }
            case .remove(let path):
                throw RGSSGuestRunError.developerOverlayUnsupported("overlay plan attempted to remove \(path.value)")
            }
        }
        return plan
    }

    /// True when the run copy already contains both the overlay file and its
    /// script-archive entry. Used to expose the menu without pretending it is
    /// available for every imported game.
    public static func isInstalled(in runRoot: URL, engine: GameEngineID) -> Bool {
        let profile = (try? RGSSEngineProfiles.profile(for: engine))
        guard let profile else { return false }
        let overlayURL = runRoot.appendingPathComponent(overlayRelativePath)
        guard FileManager.default.fileExists(atPath: overlayURL.path),
              let archive = try? RGSSGuestSafeTree.readFile(
                rootURL: runRoot, relative: profile.scriptsPath,
                maximumBytes: 64 * 1_024 * 1_024),
              let scripts = try? RPGScriptArchive.decode(archive) else {
            return false
        }
        return scripts.contains { $0.title.utf8String == overlayEntryTitle }
    }

    struct AppendResult {
        let data: Data
        let changed: Bool
    }

    static func appendOverlay(to archive: Data, engine: GameEngineID) throws -> AppendResult {
        var scripts: [RPGScript]
        do {
            scripts = try RPGScriptArchive.decode(archive)
        } catch {
            throw RGSSGuestRunError.developerOverlayUnsupported(
                "script archive could not be decoded: \(error)")
        }
        if scripts.contains(where: { $0.title.utf8String == overlayEntryTitle }) {
            return .init(data: archive, changed: false)
        }
        guard scripts.count < 4_096 else {
            throw RGSSGuestRunError.developerOverlayUnsupported("script archive entry limit")
        }
        let source = loaderScript(engine: engine)
        let script = RPGScript(
            magic: 0x464C4F45,
            title: RubyString.utf8(overlayEntryTitle),
            source: source)
        scripts.append(script)
        do {
            return .init(data: try RPGScriptArchive.encode(scripts), changed: true)
        } catch {
            throw RGSSGuestRunError.developerOverlayUnsupported(
                "script archive could not be encoded: \(error)")
        }
    }

    static func loaderScript(engine: GameEngineID) -> Data {
        Data("""
        # encoding: utf-8
        # Floe developer overlay entry. Added only to an owned run copy or a
        # separate project revision; the imported source is unchanged.
        $floe_engine_id = '\(engine.rawValue)'
        begin
          load File.expand_path('floe-developer/floe_developer.rb', Dir.pwd)
        rescue Exception => error
          warn "Floe developer overlay unavailable: #{error.message}"
        end
        """.utf8)
    }
}
