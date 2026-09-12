import Foundation
import FloeCore

/// Layer promotion: move installed packages (records + files) from a writable
/// container layer into a permanent target layer. Conflicts are refused
/// unless the versions match exactly.
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
        guard let record = await registry.record(id: containerID) else {
            throw FloeError.notFound("container \(containerID)")
        }
        guard record.kind == .session || record.kind == .project else {
            throw PromoteError.immutableTarget(containerID)
        }
        let sourceURL = roots.layerURL(id: record.id, kind: record.kind)
        let targetURL: URL
        switch target {
        case .shared:
            targetURL = roots.sharedURL
        case .project:
            guard let parentID = record.parentID ?? record.id == containerID ? record.parentID : record.parentID,
                  let parent = await registry.record(id: parentID),
                  parent.kind == .project else {
                throw PromoteError.missingTargetLayer
            }
            targetURL = roots.layerURL(id: parent.id, kind: .project)
        case .session, .base:
            throw PromoteError.immutableTarget(target.rawValue)
        }

        var sourceManifest = LayerManifest.load(from: sourceURL)
            ?? LayerManifest(id: record.id, kind: record.kind == .project ? .project : .session, baseRevision: record.baseRevision)
        var targetManifest = LayerManifest.load(from: targetURL)
            ?? LayerManifest(
                id: target == .shared ? EnvironmentRegistry.sharedContainerID : targetURL.lastPathComponent,
                kind: target == .shared ? .shared : .project,
                baseRevision: record.baseRevision
            )

        var promoted: [String] = []
        for name in packageNames {
            guard let index = sourceManifest.packages.firstIndex(where: { $0.name == name }) else {
                let stack = await registry.layerStack(for: record.id, bundledBaseURL: nil)
                if stack.layerOwning(package: name) == .base || stack.layerOwning(package: name) == .shared {
                    continue
                }
                throw PromoteError.unknownPackage(name)
            }
            let package = sourceManifest.packages[index]
            if let existing = targetManifest.packages.first(where: { $0.name == name }) {
                guard existing.version == package.version else {
                    throw PromoteError.conflict(name, existing: existing.version, incoming: package.version)
                }
                sourceManifest.packages.remove(at: index)
                promoted.append(name)
                continue
            }
            moveFiles(package.files, from: sourceURL, to: targetURL)
            var moved = package
            moved.layer = target
            targetManifest.packages.append(moved)
            sourceManifest.packages.remove(at: index)
            promoted.append(name)
        }
        sourceManifest.casRefs = Array(Set(sourceManifest.casRefs))
        targetManifest.casRefs = Array(Set(targetManifest.casRefs))
        try sourceManifest.write(to: sourceURL)
        try targetManifest.write(to: targetURL)
        await refreshCounters(containerID: record.id, layerURL: sourceURL)
        if target == .shared {
            await refreshCounters(containerID: EnvironmentRegistry.sharedContainerID, layerURL: targetURL)
        }
        return promoted
    }

    private func moveFiles(_ files: [String], from source: URL, to target: URL) {
        for relative in files {
            let sourceFile = source.appendingPathComponent(relative)
            let targetFile = target.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: sourceFile.path) else { continue }
            try? fileManager.createDirectory(
                at: targetFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: targetFile)
            do {
                try fileManager.moveItem(at: sourceFile, to: targetFile)
            } catch {
                try? fileManager.copyItem(at: sourceFile, to: targetFile)
                try? fileManager.removeItem(at: sourceFile)
            }
        }
    }

    private func refreshCounters(containerID: String, layerURL: URL) async {
        guard let manifest = LayerManifest.load(from: layerURL) else { return }
        let bytes = layerSize(layerURL)
        try? await registry.updateBytes(id: containerID, bytes: bytes, packageCount: manifest.packages.count)
    }

    private func layerSize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
