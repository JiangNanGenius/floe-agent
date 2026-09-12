import Foundation
import FloeCore

/// `floe-env` command engine. Produces Linux-ish plain text so it can run in
/// the shell; the app wires the registry/lifecycle/promote actors in.
public struct FloeEnvCommand: Sendable {
    public struct Result: Sendable {
        public var output: String
        public var exitCode: Int32? = nil

        public init(output: String, exitCode: Int32? = nil) {
            self.output = output
            self.exitCode = exitCode
        }
    }

    private let registry: EnvironmentRegistry
    private let lifecycle: ContainerLifecycle
    private let promoteEngine: ContainerPromote?
    private let roots: EnvironmentRoots
    private let bundledBaseURL: URL?

    public init(
        registry: EnvironmentRegistry,
        lifecycle: ContainerLifecycle,
        promote: ContainerPromote? = nil,
        roots: EnvironmentRoots = .shared,
        bundledBaseURL: URL? = nil
    ) {
        self.registry = registry
        self.lifecycle = lifecycle
        self.promoteEngine = promote
        self.roots = roots
        self.bundledBaseURL = bundledBaseURL
    }

    public func run(_ arguments: [String]) async -> Result {
        let args = arguments.dropFirst().filter { $0 != "floe-env" }
        let action = args.first ?? "list"
        switch action {
        case "list", "ps":
            return await list(showOutdated: args.contains("--outdated"))
        case "inspect":
            guard let id = args.dropFirst().first else {
                return Result(output: "usage: floe-env inspect <id|owner-id>", exitCode: 2)
            }
            return await inspect(id: id)
        case "size":
            return await size()
        case "stop":
            guard let id = args.dropFirst().first else {
                return Result(output: "usage: floe-env stop <id>", exitCode: 2)
            }
            await lifecycle.stop(containerID: id)
            return Result(output: "stopped \(id)")
        case "rm", "remove":
            guard let id = args.dropFirst().first else {
                return Result(output: "usage: floe-env rm <id>", exitCode: 2)
            }
            guard let report = await lifecycle.destroy(containerID: id) else {
                return Result(output: "floe-env: container not found: \(id)", exitCode: 1)
            }
            return Result(output: "removed \(report.containerID) reclaimed=\(formatBytes(report.reclaimedBytes)) casReleased=\(report.casReleased)")
        case "gc":
            let reclaimed = await lifecycle.garbageCollect()
            return Result(output: "garbage collected reclaimed=\(formatBytes(reclaimed))")
        case "rebuild":
            guard let id = args.dropFirst().first else {
                return Result(output: "usage: floe-env rebuild <id>", exitCode: 2)
            }
            do {
                try await lifecycle.rebuild(containerID: id)
                return Result(output: "rebuilt \(id) base=\(await registry.baseRevision)")
            } catch {
                return Result(output: "floe-env: rebuild failed: \(error.localizedDescription)", exitCode: 1)
            }
        case "templates":
            let templates = await registry.all().filter { $0.kind == .template }
            guard !templates.isEmpty else { return Result(output: "no templates") }
            return Result(output: templates.map { "template \($0.name ?? $0.id) base=\($0.baseRevision)" }.joined(separator: "\n"))
        case "promote":
            return await promote(args: Array(args.dropFirst()))
        case "commit":
            return await commit(args: Array(args.dropFirst()))
        case "help", "--help", "-h":
            return Result(output: Self.helpText)
        default:
            return Result(output: "floe-env: unknown action '\(action)'\n" + Self.helpText, exitCode: 2)
        }
    }

    private func list(showOutdated: Bool) async -> Result {
        var containers = await registry.all()
        if showOutdated {
            containers = containers.filter { $0.requiresRebuild || $0.baseRevision != (bundledBaseURL == nil ? $0.baseRevision : currentBaseRevision()) }
        }
        var lines = ["ID                                     KIND      OWNER        STATE    BASE       SIZE      PKGS"]
        for record in containers {
            let id = record.id.padding(toLength: 38, withPad: " ", startingAt: 0)
            let kind = record.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            let owner = String((record.ownerID ?? record.name ?? "-").prefix(11)).padding(toLength: 12, withPad: " ", startingAt: 0)
            let state = (record.requiresRebuild ? "rebuild" : record.state.rawValue).padding(toLength: 8, withPad: " ", startingAt: 0)
            let base = String(record.baseRevision.prefix(9)).padding(toLength: 10, withPad: " ", startingAt: 0)
            let size = formatBytes(record.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)
            lines.append("\(id) \(kind) \(owner) \(state) \(base) \(size) \(record.packageCount)")
        }
        return Result(output: lines.joined(separator: "\n"))
    }

    private func inspect(id: String) async -> Result {
        let record = await registry.record(id: id)
            ?? await registry.containersOwned(by: id).first
        guard let record else {
            return Result(output: "floe-env: container not found: \(id)", exitCode: 1)
        }
        let stack = await registry.layerStack(for: record.id, bundledBaseURL: bundledBaseURL)
        var lines = [
            "container: \(record.id)",
            "kind: \(record.kind.rawValue)",
            "owner: \(record.ownerID ?? "-")",
            "state: \(record.state.rawValue)\(record.requiresRebuild ? " (rebuild: \(record.rebuildReason ?? "base changed"))" : "")",
            "base: \(record.baseRevision) layerFormat=\(record.layerFormat)",
            "bytes: \(formatBytes(record.bytes)) packages: \(record.packageCount)",
            "layers:"
        ]
        for layer in stack.layers {
            let packages = layer.manifest?.packages.count ?? 0
            lines.append("  \(layer.kind.rawValue)  \(layer.url.lastPathComponent)  packages=\(packages)")
        }
        let merged = stack.mergedPackages()
        if !merged.isEmpty {
            lines.append("packages:")
            for package in merged.prefix(50) {
                lines.append("  \(package.layer.rawValue)  \(package.name) \(package.version)")
            }
            if merged.count > 50 { lines.append("  … \(merged.count - 50) more") }
        }
        return Result(output: lines.joined(separator: "\n"))
    }

    private func size() async -> Result {
        let containers = await registry.all()
        var lines = ["TYPE       COUNT  BYTES"]
        for kind in ContainerKind.allCases {
            let subset = containers.filter { $0.kind == kind }
            let bytes = subset.reduce(Int64(0)) { $0 + $1.bytes }
            lines.append("\(kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(subset.count).padding(toLength: 5, withPad: " ", startingAt: 0))  \(formatBytes(bytes))")
        }
        lines.append("total \(formatBytes(await registry.totalBytes())) quota \(formatBytes((await registry.quotaSnapshot()).totalBytes))")
        return Result(output: lines.joined(separator: "\n"))
    }

    private func promote(args: [String]) async -> Result {
        guard let promoteEngine else {
            return Result(output: "floe-env: promotion is unavailable in this build", exitCode: 1)
        }
        var target: LayerKind = .project
        var containerID: String?
        var packages: [String] = []
        var index = 0
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--to":
                if index + 1 < args.count, let parsed = LayerKind(rawValue: args[index + 1]) {
                    target = parsed
                    index += 2
                    continue
                }
                return Result(output: "floe-env: --to requires session|project|shared", exitCode: 2)
            case "--container":
                if index + 1 < args.count {
                    containerID = args[index + 1]
                    index += 2
                    continue
                }
                return Result(output: "floe-env: --container requires an id", exitCode: 2)
            default:
                packages.append(argument)
                index += 1
            }
        }
        guard let containerID, !packages.isEmpty else {
            return Result(output: "usage: floe-env promote <pkg...> --container <id> [--to project|shared]", exitCode: 2)
        }
        do {
            let promoted = try await promoteEngine.promote(packageNames: packages, from: containerID, to: target)
            return Result(output: "promoted \(promoted.joined(separator: ", ")) to \(target.rawValue)")
        } catch {
            return Result(output: "floe-env: promote failed: \(error.localizedDescription)", exitCode: 1)
        }
    }

    private func commit(args: [String]) async -> Result {
        guard let sourceID = args.first, args.count >= 2 else {
            return Result(output: "usage: floe-env commit <container> <template-name>", exitCode: 2)
        }
        do {
            let template = try await registry.createTemplate(from: sourceID, name: args[1])
            return Result(output: "committed \(sourceID) -> template \(template.name ?? template.id)")
        } catch {
            return Result(output: "floe-env: commit failed: \(error.localizedDescription)", exitCode: 1)
        }
    }

    private func currentBaseRevision() -> String { "" }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f%s" : "%.1f%s", value, units[unit])
    }

    public static let helpText = """
    usage: floe-env <command> [args]
      list [--outdated]                 list containers
      inspect <id|owner-id>             layer stack and packages
      size                              per-kind and total usage
      stop <id>                         stop a running container
      rm <id>                           destroy a session/project container
      gc                                purge trash and unreferenced blobs
      rebuild <id>                      recreate a container on the current base
      promote <pkg...> --container <id> [--to project|shared]
      commit <container> <template>     snapshot a container into a template
      templates                         list templates
    """
}
