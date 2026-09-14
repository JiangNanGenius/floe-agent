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
                throw FloeError.validationFailed("此环境不可写，或需要重建依赖")
            }
            for layer in stack.layers {
                if let layerID = layer.manifest?.id, let parent = await registry.record(id: layerID), parent.state != .active || parent.requiresRebuild {
                    throw FloeError.validationFailed("继承的环境不可用；请先恢复父环境")
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
                throw FloeError.validationFailed("请输入 HTTPS 软件源地址，以及有效的发行版和组件")
            }
            var receipt = "已保存无签名软件源；仅对此源信任"
            if source.trusted {
                source.signedBy = nil
            } else {
                if armoredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let replacingID,
                   let old = AptSources.read(inContainerAt: container.layerURL, includingDisabled: true).first(where: { $0.id == replacingID }),
                   let path = old.signedBy, path.hasPrefix("etc/apt/keyrings/") {
                    let url = try AptSources.confinedURL(path, root: container.layerURL)
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_048_576 else {
                        throw FloeError.validationFailed("公钥文件超过 1 MB")
                    }
                    armoredKey = try String(contentsOf: url, encoding: .utf8)
                }
                guard armoredKey.utf8.count <= 1_048_576 else { throw FloeError.validationFailed("公钥文件超过 1 MB") }
                let keys = try OpenPGP.parseKeyring(Data(armoredKey.utf8))
                guard let key = keys.first, !key.revoked, key.signingKey != nil else {
                    throw FloeError.validationFailed("请提供有效的 OpenPGP 签名公钥")
                }
                let keyPath = "etc/apt/keyrings/" + key.primary.fingerprint + ".asc"
                let target = try AptSources.confinedURL(keyPath, root: container.layerURL)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(armoredKey.utf8).write(to: target, options: .atomic)
                source.signedBy = keyPath; source.trusted = false
                receipt = "已保存软件源；签名指纹：" + key.primary.fingerprint
            }
            var sources = AptSources.read(inContainerAt: container.layerURL, includingDisabled: true)
            sources.removeAll { $0.id == source.id || $0.id == replacingID }; sources.append(source)
            try AptSources.write(sources, toContainer: container.layerURL, replacingAll: true)
            return receipt
        case .deleteSource(let sourceID):
            var sources = AptSources.read(inContainerAt: container.layerURL, includingDisabled: true)
            sources.removeAll { $0.id == sourceID }
            try AptSources.write(sources, toContainer: container.layerURL, replacingAll: true)
            return "已移除软件源"
        case .setSourceEnabled(let sourceID, let enabled):
            var sources = AptSources.read(inContainerAt: container.layerURL, includingDisabled: true)
            guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { throw FloeError.notFound("软件源已移除") }
            sources[index].enabled = enabled
            try AptSources.write(sources, toContainer: container.layerURL, replacingAll: true)
            return enabled ? "已启用软件源；请刷新索引" : "已停用软件源"
        case .refresh:
            let sources = AptSources.read(inContainerAt: container.layerURL).filter { $0.enabled }
            guard !sources.isEmpty else { throw FloeError.validationFailed("此环境尚未配置已签名的软件源") }
            let result = await engine.update(container: container, sources: sources)
            try Task.checkCancellation()
            guard result.failures.isEmpty else { throw FloeError.validationFailed(result.failures.joined(separator: "\n")) }
            return "已验证并刷新 \(result.packages) 个软件包"
        case .install(let name):
            let steps = try await engine.install([name], container: container)
            return steps.isEmpty ? "软件包已是当前版本" : "已安装：" + steps.map { "\($0.package) \($0.version)" }.joined(separator: ", ")
        case .remove(let name):
            _ = try await engine.remove([name], container: container, purge: false)
            return "已卸载 \(name)"
        case .hold(let name):
            try await engine.hold(name, container: container)
            return "已固定 \(name) 的版本"
        case .unhold(let name):
            try await engine.unhold(name, container: container)
            return "已解除 \(name) 的版本固定"
        }
    }

    public func stopEnvironment(id: String) async throws {
        try await lifecycle.stop(containerID: id)
    }

    public func resumeEnvironment(id: String) async throws {
        guard let record = await registry.record(id: id),
              record.kind.isWritableLayer, record.state == .stopped, !record.requiresRebuild else {
            throw FloeError.validationFailed("此环境无法恢复；请检查依赖重建状态")
        }
        try await registry.transition(id: id, state: .active)
    }

    public func deleteEnvironment(id: String) async throws {
        _ = try await lifecycle.destroy(containerID: id)
    }

    public func saveEnvironmentTemplate(id: String, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw FloeError.validationFailed("请输入 1–80 字的模板名称") }
        guard let record = await registry.record(id: id), record.kind.isWritableLayer,
              record.state == .stopped, !record.requiresRebuild else {
            throw FloeError.validationFailed("请先停止此环境，再保存一致的依赖模板")
        }
        _ = try await registry.createTemplate(from: id, name: name)
    }

}
