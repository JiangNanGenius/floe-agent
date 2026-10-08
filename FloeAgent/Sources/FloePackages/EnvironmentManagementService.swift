// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeEnvironments

/// Explicit-ID management API shared by native UI and qualification fixtures.
public actor EnvironmentManagementService {
    private let registry: EnvironmentRegistry
    private let lifecycle: ContainerLifecycle
    private let engine: AptEngine
    private let baseSliceURL: URL?
    public init(registry: EnvironmentRegistry, lifecycle: ContainerLifecycle, engine: AptEngine, baseSliceURL: URL? = nil) {
        self.registry = registry
        self.lifecycle = lifecycle
        self.engine = engine
        self.baseSliceURL = baseSliceURL
    }
    public struct PackageReport: Sendable {
        public let installed: [InstalledPackage]
        public let inherited: [InstalledPackage]
        public let available: [AptPackage]
        public let sources: [AptSource]
        public let held: Set<String>
    }

    private func packageContext(id: String, writable: Bool) async throws -> (AptEngine, AptEngine.Container, ResolvedLayerStack) {
        guard let record = await registry.record(id: id),
              let root = await registry.layerURL(for: id) else {
            throw FloeError.notFound("Environment \(id)")
        }
        let stack = await registry.layerStack(for: id, bundledBaseURL: baseSliceURL)
        if writable {
            guard record.kind.isWritableLayer, record.state == .active, !record.requiresRebuild else {
                throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.this_environment_is_not_writable_or"))
            }
            for layer in stack.layers {
                if let layerID = layer.manifest?.id, let parent = await registry.record(id: layerID), parent.state != .active || parent.requiresRebuild {
                    throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.the_inherited_environment_is_unavailable_restore"))
                }
            }
        }
        let kind: LayerKind = record.kind == .session ? .session : record.kind == .shared ? .shared : .project
        return (engine, AptEngine.Container(id: id, rootURL: root, layerURL: root,
            layerKind: kind, baseRevision: record.baseRevision), stack)
    }

    public func packageReport(id: String) async throws -> PackageReport {
        let (engine, container, stack) = try await packageContext(id: id, writable: false)
        let installed = try LayerManifest.loadChecked(from: container.layerURL)?.packages ?? []
        var inherited: [InstalledPackage] = []
        var names = Set(installed.map(\.name))
        for layer in stack.layers where layer.url != container.layerURL {
            for package in try LayerManifest.loadChecked(from: layer.url)?.packages ?? [] where names.insert(package.name).inserted {
                inherited.append(package)
            }
        }
        return PackageReport(installed: installed, inherited: inherited,
            available: await engine.allPackages(container: container),
            sources: AptSources.read(inContainerAt: container.layerURL, includingDisabled: true),
            held: Set(try await engine.held(container: container)))
    }

    public enum PackageAction: Sendable {
        case refresh, install(String), remove(String), hold(String), unhold(String)
        case saveSource(AptSource, String, replacingID: String? = nil), deleteSource(String)
        case setSourceEnabled(String, Bool)
    }

    public func managePackage(id: String, action: PackageAction) async throws -> String {
        let (engine, container, _) = try await packageContext(id: id, writable: true)
        try Task.checkCancellation()
        switch action {
        case .saveSource(var source, var armoredKey, let replacingID):
            guard let url = URL(string: source.uri), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  !source.uri.contains(where: { $0.isWhitespace }), !source.components.isEmpty,
                  ([source.suite] + source.components).allSatisfy({ !$0.isEmpty && $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil }) else {
                throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.enter_an_https_software_source_url"))
            }
            var receipt = FloeL10n.l("packages.environment_management_service.unsigned_software_source_saved_trusted_for")
            if source.trusted {
                source.signedBy = nil
            } else {
                if armoredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let replacingID,
                   let old = AptSources.read(inContainerAt: container.layerURL, includingDisabled: true).first(where: { $0.id == replacingID }),
                   let path = old.signedBy, path.hasPrefix("etc/apt/keyrings/") {
                    let url = try AptSources.confinedURL(path, root: container.layerURL)
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_048_576 else {
                        throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.the_public_key_file_exceeds_1"))
                    }
                    armoredKey = try String(contentsOf: url, encoding: .utf8)
                }
                guard armoredKey.utf8.count <= 1_048_576 else { throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.the_public_key_file_exceeds_1")) }
                let keys = try OpenPGP.parseKeyring(Data(armoredKey.utf8))
                guard let key = keys.first, !key.revoked, key.signingKey != nil else {
                    throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.provide_a_valid_openpgp_public_signing"))
                }
                let keyPath = "etc/apt/keyrings/" + key.primary.fingerprint + ".asc"
                let target = try AptSources.confinedURL(keyPath, root: container.layerURL)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(armoredKey.utf8).write(to: target, options: .atomic)
                source.signedBy = keyPath; source.trusted = false
                receipt = FloeL10n.l("packages.environment_management_service.software_source_saved_signature_fingerprint") + key.primary.fingerprint
            }
            var sources = AptSources.read(inContainerAt: container.layerURL, includingDisabled: true)
            sources.removeAll { $0.id == source.id || $0.id == replacingID }; sources.append(source)
            try AptSources.write(sources, toContainer: container.layerURL, replacingAll: true)
            return receipt
        case .deleteSource(let sourceID):
            var sources = AptSources.read(inContainerAt: container.layerURL, includingDisabled: true)
            sources.removeAll { $0.id == sourceID }
            try AptSources.write(sources, toContainer: container.layerURL, replacingAll: true)
            return FloeL10n.l("packages.environment_management_service.software_source_removed")
        case .setSourceEnabled(let sourceID, let enabled):
            var sources = AptSources.read(inContainerAt: container.layerURL, includingDisabled: true)
            guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { throw FloeError.notFound(FloeL10n.l("packages.environment_management_service.software_source_removed_2")) }
            sources[index].enabled = enabled
            try AptSources.write(sources, toContainer: container.layerURL, replacingAll: true)
            return enabled ? FloeL10n.l("packages.environment_management_service.software_source_enabled_refresh_the_index") : FloeL10n.l("packages.environment_management_service.disabled_software_source")
        case .refresh:
            let sources = AptSources.read(inContainerAt: container.layerURL).filter { $0.enabled }
            guard !sources.isEmpty else { throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.this_environment_has_no_software_sources")) }
            let result = await engine.update(container: container, sources: sources)
            try Task.checkCancellation()
            guard result.failures.isEmpty else { throw FloeError.validationFailed(result.failures.joined(separator: "\n")) }
            return FloeL10n.plural("packages.environment_management_service.verified_and_refreshed_packages", count: result.packages)
        case .install(let name):
            let steps = try await engine.install([name], container: container)
            return steps.isEmpty ? FloeL10n.l("packages.environment_management_service.the_package_is_already_at_the") : FloeL10n.l("packages.environment_management_service.installed") + steps.map { "\($0.package) \($0.version)" }.joined(separator: ", ")
        case .remove(let name):
            _ = try await engine.remove([name], container: container, purge: false)
            return FloeL10n.l("packages.environment_management_service.uninstalled", name)
        case .hold(let name):
            try await engine.hold(name, container: container)
            return FloeL10n.l("packages.environment_management_service.pinned_the_version_of", name)
        case .unhold(let name):
            try await engine.unhold(name, container: container)
            return FloeL10n.l("packages.environment_management_service.unpinned_the_version_of", name)
        }
    }

    public func stopEnvironment(id: String) async throws {
        try await lifecycle.stop(containerID: id)
    }

    public func resumeEnvironment(id: String) async throws {
        guard let record = await registry.record(id: id),
              record.kind.isWritableLayer, record.state == .stopped, !record.requiresRebuild else {
            throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.this_environment_cannot_be_restored_check"))
        }
        try await registry.transition(id: id, state: .active)
    }

    public func deleteEnvironment(id: String) async throws {
        _ = try await lifecycle.destroy(containerID: id)
    }

    public func saveEnvironmentTemplate(id: String, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.enter_a_template_name_of_1")) }
        guard let record = await registry.record(id: id), record.kind.isWritableLayer,
              record.state == .stopped, !record.requiresRebuild else {
            throw FloeError.validationFailed(FloeL10n.l("packages.environment_management_service.stop_this_environment_before_saving_a"))
        }
        _ = try await registry.createTemplate(from: id, name: name)
    }

}
