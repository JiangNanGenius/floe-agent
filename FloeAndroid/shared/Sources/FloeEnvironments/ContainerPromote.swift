import Foundation
import FloeCore

/// Durable package promotion copies verified records and files into a permanent
/// layer. The source remains usable and can be removed independently afterward.
public actor ContainerPromote {
    public enum PromoteError: Error, CustomStringConvertible {
        case unknownPackage(String)
        case conflict(String, existing: String, incoming: String)
        case immutableTarget(String)
        case missingTargetLayer

        public var description: String {
            switch self {
            case .unknownPackage(let name):
                return "package \(name) is not installed in the source layer"
            case .conflict(let name, let existing, let incoming):
                return "package \(name) exists with version \(existing); refusing to replace with \(incoming) without an explicit upgrade"
            case .immutableTarget(let name):
                return "package \(name) belongs to a read-only layer"
            case .missingTargetLayer:
                return "the target project layer is unavailable"
            }
        }
    }

    private let roots: EnvironmentRoots
    private let registry: EnvironmentRegistry
    private let cas: ContainerCAS
    private let fileManager = FileManager.default

    public init(roots: EnvironmentRoots = .shared, registry: EnvironmentRegistry, cas: ContainerCAS) {
        self.roots = roots
        self.registry = registry
        self.cas = cas
    }

    /// Promotes the named packages from `containerID` to `target`.
    @discardableResult
    public func promote(
        packageNames: [String],
        from containerID: String,
        to target: LayerKind
    ) async throws -> [String] {
        try await registry.prepare()
        guard let record = await registry.record(id: containerID) else {
            throw FloeError.notFound("container \(containerID)")
        }
        guard record.kind == .session || record.kind == .project,
              record.state != .deleting, !record.requiresRebuild else {
            throw PromoteError.immutableTarget(containerID)
        }
        let targetRecord: ContainerRecord
        switch target {
        case .shared:
            guard let shared = await registry.record(id: EnvironmentRegistry.sharedContainerID) else { throw PromoteError.missingTargetLayer }
            targetRecord = shared
        case .project:
            guard record.kind == .session, let parentID = record.parentID,
                  let parent = await registry.record(id: parentID), parent.kind == .project else {
                throw PromoteError.missingTargetLayer
            }
            targetRecord = parent
        case .session, .base: throw PromoteError.immutableTarget(target.rawValue)
        }
        guard targetRecord.state != .deleting, !targetRecord.requiresRebuild else {
            throw PromoteError.immutableTarget(targetRecord.id)
        }
        let sourceURL = roots.layerURL(id: record.id, kind: record.kind)
        let targetURL = roots.layerURL(id: targetRecord.id, kind: targetRecord.kind)
        guard let sourceManifest = try LayerManifest.loadChecked(from: sourceURL),
              var targetManifest = try LayerManifest.loadChecked(from: targetURL),
              sourceManifest.id == record.id, targetManifest.id == targetRecord.id else {
            throw FloeError.validationFailed("Promotion requires intact layer manifests")
        }
        let names = Array(Set(packageNames)).sorted()
        guard !names.isEmpty else { throw FloeError.validationFailed("No packages selected for promotion") }
        // No awaits from validation through commit: the actor cannot interleave
        // another promotion. The journal also rejects an outstanding install.
        var copies: [(path: String, source: URL, digest: String, mode: Int)] = []
        var claimed = Set<String>()
        for name in names {
            guard name.range(of: "^[a-z0-9][a-z0-9+.-]*$", options: .regularExpression) != nil else {
                throw FloeError.validationFailed("Invalid promoted package name")
            }
            guard let package = sourceManifest.packages.first(where: { $0.name == name }) else {
                throw PromoteError.unknownPackage(name)
            }
            if let existing = targetManifest.packages.first(where: { $0.name == name }), existing.version != package.version {
                throw PromoteError.conflict(name, existing: existing.version, incoming: package.version)
            }
            for relative in package.files {
                guard relative != LayerManifest.fileName, !relative.hasPrefix("var/lib/dpkg/"),
                      relative != EnvironmentFileTransaction.directoryName,
                      !relative.hasPrefix(EnvironmentFileTransaction.directoryName + "/"),
                      claimed.insert(relative).inserted else {
                    throw FloeError.validationFailed("Duplicate or reserved promoted file: \(relative)")
                }
                let source = try EnvironmentFileTransaction.location(relative, root: sourceURL)
                let destination = try EnvironmentFileTransaction.location(relative, root: targetURL)
                let attrs = try fileManager.attributesOfItem(atPath: source.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular else {
                    throw FloeError.validationFailed("Promotion requires regular package files: \(relative)")
                }
                let digest = try FloeDigest.sha256Hex(ofFileAt: source)
                if let expected = package.fileDigests?[relative], digest != expected {
                    throw FloeError.validationFailed("Promoted file checksum mismatch: \(relative)")
                }
                guard !targetManifest.packages.contains(where: { $0.name != name && $0.files.contains(relative) }) else {
                    throw FloeError.validationFailed("Promoted file belongs to another package: \(relative)")
                }
                if fileManager.fileExists(atPath: destination.path) {
                    guard targetManifest.packages.contains(where: { $0.name == name && $0.files.contains(relative) }),
                          try FloeDigest.sha256Hex(ofFileAt: destination) == digest else {
                        throw FloeError.validationFailed("Promoted file conflicts with existing data: \(relative)")
                    }
                }
                copies.append((relative, source, digest, (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644))
            }
            var promoted = package; promoted.layer = target
            targetManifest.packages.removeAll { $0.name == name }
            targetManifest.packages.append(promoted)
        }
        // Copies own their bytes; source CAS references and installed records
        // remain unchanged. Removing the source later cannot invalidate target.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(targetManifest)
        var entries = LayerPackageDatabase.readStatus(at: targetURL)
        var metadataPaths = [LayerManifest.fileName, "var/lib/dpkg/status"]
        for name in names {
            metadataPaths += ["var/lib/dpkg/info/" + name + ".list", "var/lib/dpkg/info/" + name + ".md5sums"]
        }
        let transaction = try EnvironmentFileTransaction(root: targetURL,
            paths: copies.map(\.path) + metadataPaths)
        do {
            for copy in copies { try transaction.copy(from: copy.source, to: copy.path, digest: copy.digest, mode: copy.mode) }
            for package in targetManifest.packages where names.contains(package.name) {
                let entry = LayerPackageDatabase.StatusEntry(name: package.name, version: package.version,
                    architecture: package.architecture, status: "install ok installed", summary: package.summary,
                    license: package.license, source: package.source, layer: target,
                    requiresBase: package.requiresBase, installedFiles: package.files)
                entries.removeAll { $0.name == package.name }; entries.append(entry)
                try LayerPackageDatabase.writeInfoFiles(for: entry, at: targetURL)
            }
            try LayerPackageDatabase.writeStatus(entries, at: targetURL)
            try transaction.write(manifestData, to: LayerManifest.fileName)
            try transaction.commit()
        } catch {
            // Recovery keeps the journal if restoring any file fails.
            try EnvironmentFileTransaction.recover(root: targetURL)
            throw error
        }
        return names
    }
}
