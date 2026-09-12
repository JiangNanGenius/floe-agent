import Foundation
import FloeCore

/// Linux-style apt/dpkg command surface. The app registers `apt`,
/// `apt-get`, `apt-cache`, `apt-mark`, `dpkg` and `dpkg-deb` as replacement
/// commands that route here.
public struct PackagesCLI: Sendable {
    public struct Result: Sendable {
        public var output: String
        public var exitCode: Int32

        public init(output: String, exitCode: Int32 = 0) {
            self.output = output
            self.exitCode = exitCode
        }
    }

    public struct Context: Sendable {
        public var container: AptEngine.Container
        public var sources: [AptSource]
        public var layerURL: URL
        public var installed: [DpkgDatabase.StatusEntry]

        public init(container: AptEngine.Container, sources: [AptSource], layerURL: URL, installed: [DpkgDatabase.StatusEntry]) {
            self.container = container
            self.sources = sources
            self.layerURL = layerURL
            self.installed = installed
        }
    }

    private let engine: AptEngine
    private let contextProvider: @Sendable () async -> Context?

    public init(engine: AptEngine, contextProvider: @escaping @Sendable () async -> Context?) {
        self.engine = engine
        self.contextProvider = contextProvider
    }

    public func run(command: String, arguments: [String]) async -> Result {
        switch command {
        case "apt", "apt-get":
            return await runApt(arguments)
        case "apt-cache":
            return await runAptCache(arguments)
        case "apt-mark":
            return await runAptMark(arguments)
        case "dpkg":
            return await runDpkg(arguments)
        case "dpkg-deb":
            return await runDpkgDeb(arguments)
        default:
            return Result(output: "\(command): unknown floe packages command", exitCode: 2)
        }
    }

    // MARK: - apt

    private func runApt(_ arguments: [String]) async -> Result {
        guard let context = await contextProvider() else {
            return Result(output: "apt: no active container", exitCode: 100)
        }
        let subcommand = arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "list"
        let operands = arguments.dropFirst().drop { $0 == subcommand }.filter { !$0.hasPrefix("-") }
        switch subcommand {
        case "update":
            let report = await engine.update(container: context.container, sources: context.sources)
            var lines = ["Get:1 floe \(report.sources) source(s), \(report.packages) packages"]
            for failure in report.failures { lines.append("W: \(failure)") }
            lines.append("Reading package lists... Done")
            return Result(output: lines.joined(separator: "\n"), exitCode: report.failures.isEmpty ? 0 : 100)
        case "list":
            let packages = await engine.allPackages().sorted { $0.name < $1.name }
            let installedNames = Set(context.installed.map(\.name))
            var lines = ["Listing... Done"]
            for package in packages where operands.isEmpty || operands.contains(where: { package.name.contains($0) }) {
                let state = installedNames.contains(package.name) ? "[installed]" : "[available]"
                lines.append("\(package.name)/\(package.component) \(package.version) \(context.container.architecture) \(state)")
            }
            return Result(output: lines.joined(separator: "\n"))
        case "search":
            let results = await engine.search(operands.first ?? "")
            return Result(output: results.map { "\($0.name) - \($0.description?.split(separator: "\n").first ?? "")" }.joined(separator: "\n"))
        case "show":
            var lines: [String] = []
            for name in operands {
                for package in await engine.show(name) {
                    lines.append("Package: \(package.name)")
                    lines.append("Version: \(package.version)")
                    lines.append("Architecture: \(package.architecture)")
                    lines.append("Filename: \(package.filename)")
                    if let depends = package.depends { lines.append("Depends: \(depends)") }
                    if let description = package.description { lines.append("Description: \(description)") }
                    if let license = package.license { lines.append("License: \(license)") }
                    if let requiresBase = package.requiresBase { lines.append("Floe-Requires-Base: \(requiresBase)") }
                    lines.append("")
                }
            }
            return Result(output: lines.isEmpty ? "E: No packages found" : lines.joined(separator: "\n"), exitCode: lines.isEmpty ? 100 : 0)
        case "policy":
            var lines: [String] = []
            for name in operands {
                if let installed = context.installed.first(where: { $0.name == name }) {
                    lines.append("\(name):")
                    lines.append("  Installed: \(installed.version)")
                }
                if let candidate = await engine.bestPackage(named: name) {
                    lines.append("  Candidate: \(candidate.version)")
                }
            }
            return Result(output: lines.joined(separator: "\n"))
        case "install":
            do {
                let steps = try await engine.install(operands, container: context.container)
                var lines = ["Reading package lists... Done", "Building dependency tree... Done"]
                for step in steps {
                    lines.append("Setting up \(step.package) (\(step.version)) ...")
                }
                return Result(output: lines.joined(separator: "\n"))
            } catch {
                return Result(output: "E: \(error.localizedDescription)", exitCode: 100)
            }
        case "remove", "purge":
            do {
                let steps = try await engine.remove(operands, container: context.container, purge: subcommand == "purge")
                return Result(output: steps.map { "Removing \($0.package) (\($0.version)) ..." }.joined(separator: "\n"))
            } catch {
                return Result(output: "E: \(error.localizedDescription)", exitCode: 100)
            }
        case "upgrade", "full-upgrade":
            let plan = await engine.upgradePlan(container: context.container)
            guard !plan.isEmpty else { return Result(output: "0 upgraded, 0 newly installed, 0 to remove.") }
            do {
                let steps = try await engine.install(plan.map(\.package), container: context.container)
                return Result(output: (["Installing upgrades:"] + steps.map { "  \($0.package) -> \($0.version)" }).joined(separator: "\n"))
            } catch {
                return Result(output: "E: \(error.localizedDescription)", exitCode: 100)
            }
        case "autoremove":
            let orphans = await engine.autoremovable(container: context.container)
            guard !orphans.isEmpty else { return Result(output: "0 upgraded, 0 newly installed, 0 to remove.") }
            do {
                _ = try await engine.remove(orphans, container: context.container, purge: false)
                return Result(output: "Removing \(orphans.joined(separator: " ")) ...")
            } catch {
                return Result(output: "E: \(error.localizedDescription)", exitCode: 100)
            }
        case "clean", "autoclean":
            let cache = context.layerURL.appendingPathComponent("var/cache/apt/archives", isDirectory: true)
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            return Result(output: "")
        default:
            return Result(output: "E: Invalid operation \(subcommand)", exitCode: 100)
        }
    }

    private func runAptCache(_ arguments: [String]) async -> Result {
        let subcommand = arguments.dropFirst().first ?? "show"
        let operands = arguments.dropFirst(2).filter { !$0.hasPrefix("-") }
        switch subcommand {
        case "show", "showpkg":
            var lines: [String] = []
            for name in operands {
                for package in await engine.show(name) {
                    lines.append("\(package.name) - \(package.description ?? "")")
                    if let depends = package.depends { lines.append("  Depends: \(depends)") }
                }
            }
            return Result(output: lines.joined(separator: "\n"))
        case "depends":
            var lines: [String] = []
            for name in operands {
                guard let package = await engine.bestPackage(named: name) else { continue }
                lines.append("\(name)")
                for dependency in (package.depends ?? "").split(separator: ",") {
                    lines.append("  Depends: \(dependency.trimmingCharacters(in: .whitespaces))")
                }
            }
            return Result(output: lines.joined(separator: "\n"))
        case "policy":
            return await runApt(["apt", "policy"] + operands)
        default:
            return Result(output: "E: Invalid operation \(subcommand)", exitCode: 100)
        }
    }

    private func runAptMark(_ arguments: [String]) async -> Result {
        let subcommand = arguments.dropFirst().first ?? "showhold"
        let operands = arguments.dropFirst(2)
        switch subcommand {
        case "hold":
            for name in operands { await engine.hold(name) }
            return Result(output: operands.map { "\($0) set on hold." }.joined(separator: "\n"))
        case "unhold":
            for name in operands { await engine.unhold(name) }
            return Result(output: operands.map { "Canceled hold on \($0)." }.joined(separator: "\n"))
        case "showhold":
            let holds = await engine.held()
            return Result(output: holds.joined(separator: "\n"))
        default:
            return Result(output: "E: Invalid operation \(subcommand)", exitCode: 100)
        }
    }

    // MARK: - dpkg

    private func runDpkg(_ arguments: [String]) async -> Result {
        guard let context = await contextProvider() else {
            return Result(output: "dpkg: no active container", exitCode: 2)
        }
        let flag = arguments.dropFirst().first ?? "-l"
        switch flag {
        case "-l", "--list":
            let entries = DpkgDatabase.merged(layers: [(context.container.layerKind, context.layerURL)])
            var lines = ["Desired=Unknown/Install/Remove/Purge/Hold",
                         "| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend",
                         "||/ Name                          Version                Architecture Description",
                         "+++-=============================-======================-============-================================="]
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                let code = entry.isInstalled ? "ii" : entry.isHalfConfigured ? "iF" : "iU"
                let name = entry.name.padding(toLength: 29, withPad: " ", startingAt: 0)
                let version = entry.version.padding(toLength: 22, withPad: " ", startingAt: 0)
                let architecture = entry.architecture.padding(toLength: 12, withPad: " ", startingAt: 0)
                lines.append("\(code) \(name) \(version) \(architecture) \(entry.summary ?? "")")
            }
            return Result(output: lines.joined(separator: "\n"))
        case "-s", "--status":
            guard let name = arguments.dropFirst(2).first,
                  let entry = DpkgDatabase.merged(layers: [(context.container.layerKind, context.layerURL)])
                    .first(where: { $0.name == name }) else {
                return Result(output: "dpkg-query: package '\(arguments.dropFirst(2).first ?? "")' is not installed", exitCode: 1)
            }
            var lines = [
                "Package: \(entry.name)",
                "Status: \(entry.status)",
                "Version: \(entry.version)",
                "Architecture: \(entry.architecture)"
            ]
            if let summary = entry.summary { lines.append("Description: \(summary)") }
            if let layer = entry.layer { lines.append("Floe-Layer: \(layer.rawValue)") }
            if let license = entry.license { lines.append("License: \(license)") }
            return Result(output: lines.joined(separator: "\n"))
        case "-L", "--listfiles":
            guard let name = arguments.dropFirst(2).first else {
                return Result(output: "dpkg: --listfiles needs a package name", exitCode: 2)
            }
            let files = DpkgDatabase.readFileList(at: context.layerURL, package: name)
            guard !files.isEmpty else {
                return Result(output: "dpkg-query: package '\(name)' is not installed", exitCode: 1)
            }
            return Result(output: files.map { "/" + $0 }.joined(separator: "\n"))
        case "-S", "--search":
            guard let path = arguments.dropFirst(2).first else {
                return Result(output: "dpkg: --search needs a path", exitCode: 2)
            }
            let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let entries = DpkgDatabase.merged(layers: [(context.container.layerKind, context.layerURL)])
            for entry in entries where entry.installedFiles.contains(where: { $0.hasSuffix(normalized) || $0 == normalized }) {
                return Result(output: "\(entry.name): /\(normalized)")
            }
            return Result(output: "dpkg-query: no path found matching pattern /\(normalized)", exitCode: 1)
        case "-c", "--contents":
            guard let debPath = arguments.dropFirst(2).first else {
                return Result(output: "dpkg-deb: --contents needs an archive", exitCode: 2)
            }
            return listDebContents(path: debPath, container: context)
        case "-x", "--extract":
            let operands = arguments.dropFirst(2).filter { !$0.hasPrefix("-") }
            guard operands.count >= 1 else {
                return Result(output: "dpkg-deb: --extract needs <archive> [directory]", exitCode: 2)
            }
            return extractDeb(path: operands[0], destination: operands.count > 1 ? operands[1] : ".", container: context)
        case "-e", "--control":
            let operands = arguments.dropFirst(2).filter { !$0.hasPrefix("-") }
            guard let debPath = operands.first else {
                return Result(output: "dpkg-deb: --control needs an archive", exitCode: 2)
            }
            return controlDeb(path: debPath, destination: operands.count > 1 ? operands[1] : nil)
        case "-f", "--field":
            let operands = arguments.dropFirst(2).filter { !$0.hasPrefix("-") }
            guard let debPath = operands.first else {
                return Result(output: "dpkg-deb: --field needs an archive", exitCode: 2)
            }
            return fieldDeb(path: debPath, field: operands.count > 1 ? operands[1] : nil)
        case "-i", "--install":
            guard let debPath = arguments.dropFirst(2).first else {
                return Result(output: "dpkg: --install needs an archive", exitCode: 2)
            }
            return installLocalDeb(path: debPath, container: context)
        case "--print-architecture":
            return Result(output: context.container.architecture)
        case "--compare-versions":
            let operands = arguments.dropFirst(2)
            guard operands.count == 3 else {
                return Result(output: "dpkg: --compare-versions requires <v1> <op> <v2>", exitCode: 2)
            }
            let order = DebVersion.compare(operands[0], operands[2])
            let satisfied: Bool
            switch operands[1] {
            case "lt", "<<": satisfied = order == .older
            case "le", "<=": satisfied = order != .newer
            case "eq", "=": satisfied = order == .equal
            case "ge", ">=": satisfied = order != .older
            case "gt", ">>": satisfied = order == .newer
            default: satisfied = false
            }
            return Result(output: "", exitCode: satisfied ? 0 : 1)
        default:
            return Result(output: "dpkg: unknown option \(flag)", exitCode: 2)
        }
    }

    private func runDpkgDeb(_ arguments: [String]) async -> Result {
        guard let context = await contextProvider() else {
            return Result(output: "dpkg-deb: no active container", exitCode: 2)
        }
        let flag = arguments.dropFirst().first ?? "-c"
        let operands = arguments.dropFirst(2).filter { !$0.hasPrefix("-") }
        switch flag {
        case "-c", "--contents":
            guard let path = operands.first else { return Result(output: "dpkg-deb: --contents needs an archive", exitCode: 2) }
            return listDebContents(path: path, container: context)
        case "-x", "--extract":
            guard let path = operands.first else { return Result(output: "dpkg-deb: --extract needs an archive", exitCode: 2) }
            return extractDeb(path: path, destination: operands.count > 1 ? operands[1] : ".", container: context)
        case "-e", "--control":
            guard let path = operands.first else { return Result(output: "dpkg-deb: --control needs an archive", exitCode: 2) }
            return controlDeb(path: path, destination: operands.count > 1 ? operands[1] : nil)
        case "-f", "--field":
            guard let path = operands.first else { return Result(output: "dpkg-deb: --field needs an archive", exitCode: 2) }
            return fieldDeb(path: path, field: operands.count > 1 ? operands[1] : nil)
        case "-b", "--build":
            guard let source = operands.first else { return Result(output: "dpkg-deb: --build needs a directory", exitCode: 2) }
            return buildDeb(source: source, output: operands.count > 1 ? operands[1] : nil, container: context)
        default:
            return Result(output: "dpkg-deb: unknown option \(flag)", exitCode: 2)
        }
    }

    // MARK: - Local archive helpers

    private func resolveLocal(_ path: String, container: AptEngine.Container) -> URL? {
        if path.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let relative = container.rootURL.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: relative.path) { return relative }
        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: working.path) { return working }
        return nil
    }

    private func listDebContents(path: String, container: AptEngine.Container) -> Result {
        guard let url = resolveLocal(path, container: container) else {
            return Result(output: "dpkg-deb: cannot read \(path)", exitCode: 2)
        }
        do {
            let payload = try DebArchive.read(data: Data(floeContentsOf: url))
            let lines = payload.dataEntries.map { entry -> String in
                let mode = String(entry.mode, radix: 8)
                let size = entry.kind == .file ? String(entry.data.count) : "-"
                return "-rw-r--r-- root/root \(size.padding(toLength: 9, withPad: " ", startingAt: 0)) \(mode) \(entry.path)"
            }
            return Result(output: lines.joined(separator: "\n"))
        } catch {
            return Result(output: "dpkg-deb: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func extractDeb(path: String, destination: String, container: AptEngine.Container) -> Result {
        guard let url = resolveLocal(path, container: container) else {
            return Result(output: "dpkg-deb: cannot read \(path)", exitCode: 2)
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = container.rootURL.appendingPathComponent(destination)
        }
        do {
            let payload = try DebArchive.read(data: Data(floeContentsOf: url))
            for entry in payload.dataEntries where entry.kind == .file || entry.kind == .directory {
                let normalized = entry.path.hasPrefix("./") ? String(entry.path.dropFirst(2)) : entry.path
                guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.split(separator: "/").contains("..") else {
                    return Result(output: "dpkg-deb: unsafe path in archive: \(entry.path)", exitCode: 2)
                }
                let target = destinationURL.appendingPathComponent(normalized)
                if entry.kind == .directory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try entry.data.write(to: target, options: .atomic)
                }
            }
            if payload.containsNativeExecutable {
                return Result(output: "dpkg-deb: warning: extracted data-only; package contains native executables that iOS cannot run")
            }
            return Result(output: "")
        } catch {
            return Result(output: "dpkg-deb: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func controlDeb(path: String, destination: String?) -> Result {
        guard let url = URL(string: path).map({ URL(fileURLWithPath: $0.path) }),
              FileManager.default.fileExists(atPath: url.path) else {
            return Result(output: "dpkg-deb: cannot read \(path)", exitCode: 2)
        }
        do {
            let payload = try DebArchive.read(data: Data(floeContentsOf: url))
            if let destination {
                let directory = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for entry in payload.controlEntries where entry.kind == .file {
                    let name = (entry.path as NSString).lastPathComponent
                    try entry.data.write(to: directory.appendingPathComponent(name), options: .atomic)
                }
                return Result(output: "")
            }
            return Result(output: payload.control.serialized)
        } catch {
            return Result(output: "dpkg-deb: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func fieldDeb(path: String, field: String?) -> Result {
        guard let url = URL(string: path).map({ URL(fileURLWithPath: $0.path) }),
              FileManager.default.fileExists(atPath: url.path) else {
            return Result(output: "dpkg-deb: cannot read \(path)", exitCode: 2)
        }
        do {
            let payload = try DebArchive.read(data: Data(floeContentsOf: url))
            if let field {
                guard let value = payload.control[field] else {
                    return Result(output: "", exitCode: 1)
                }
                return Result(output: value)
            }
            return Result(output: payload.control.serialized)
        } catch {
            return Result(output: "dpkg-deb: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func buildDeb(source: String, output: String?, container: AptEngine.Container) -> Result {
        let sourceURL = URL(fileURLWithPath: source)
        let controlURL = sourceURL.appendingPathComponent("DEBIAN")
        let controlFile = controlURL.appendingPathComponent("control")
        guard let controlText = try? String(contentsOf: controlFile, encoding: .utf8) else {
            return Result(output: "dpkg-deb: missing DEBIAN/control in \(source)", exitCode: 2)
        }
        let control = Deb822.parse(stanza: controlText)
        var scripts: [String: String] = [:]
        for name in ["preinst", "postinst", "prerm", "postrm"] {
            if let text = try? String(contentsOf: controlURL.appendingPathComponent(name), encoding: .utf8) {
                scripts[name] = text
            }
        }
        var entries: [TarArchive.Entry] = []
        let enumerator = FileManager.default.enumerator(at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let relative = fileURL.path.replacingOccurrences(of: sourceURL.path + "/", with: "")
            if relative.hasPrefix("DEBIAN") { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                entries.append(TarArchive.Entry(path: "./\(relative)", kind: .directory, mode: 0o755))
            } else if let data = try? Data(floeContentsOf: fileURL) {
                entries.append(TarArchive.Entry(path: "./\(relative)", kind: .file, data: data))
            }
        }
        let packageName = control["Package"] ?? "floe-package"
        let version = control["Version"] ?? "0.0.0"
        let data = DebArchive.build(control: control, dataEntries: entries, scripts: scripts)
        let destination = output.map { URL(fileURLWithPath: $0) }
            ?? container.layerURL.appendingPathComponent("\(packageName)_\(version)_\(control["Architecture"] ?? "all").deb")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return Result(output: "dpkg-deb: building package '\(packageName)' in '\(destination.path)'.")
        } catch {
            return Result(output: "dpkg-deb: \(error.localizedDescription)", exitCode: 2)
        }
    }

    private func installLocalDeb(path: String, container: AptEngine.Container) -> Result {
        guard let url = resolveLocal(path, container: container) else {
            return Result(output: "dpkg: cannot read \(path)", exitCode: 2)
        }
        do {
            let payload = try DebArchive.read(data: Data(floeContentsOf: url))
            if DebArchive.installability(of: payload) == .nativePayload {
                return Result(output: "dpkg: error: package contains native executables; iOS cannot run them. Use a remote host.", exitCode: 2)
            }
            let name = payload.control["Package"] ?? "unknown"
            let version = payload.control["Version"] ?? "0.0.0"
            var files: [String] = []
            for entry in payload.dataEntries where entry.kind == .file || entry.kind == .directory {
                let normalized = entry.path.hasPrefix("./") ? String(entry.path.dropFirst(2)) : entry.path
                guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.split(separator: "/").contains("..") else {
                    return Result(output: "dpkg: error: unsafe path \(entry.path)", exitCode: 2)
                }
                let target = container.layerURL.appendingPathComponent(normalized)
                if entry.kind == .directory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try entry.data.write(to: target, options: .atomic)
                    files.append(normalized)
                }
            }
            var entries = DpkgDatabase.readStatus(at: container.layerURL)
            entries.removeAll { $0.name == name }
            entries.append(DpkgDatabase.StatusEntry(
                name: name,
                version: version,
                architecture: payload.control["Architecture"] ?? "all",
                status: "install ok installed",
                summary: payload.control["Description"]?.split(separator: "\n").first.map(String.init),
                license: payload.control["License"],
                source: payload.control["Source"],
                layer: container.layerKind,
                requiresBase: payload.control["Floe-Requires-Base"],
                installedFiles: files
            ))
            try DpkgDatabase.writeStatus(entries, at: container.layerURL)
            if let info = entries.first(where: { $0.name == name }) {
                try DpkgDatabase.writeInfoFiles(for: info, at: container.layerURL)
            }
            var manifest = LayerManifest.load(from: container.layerURL)
                ?? LayerManifest(id: container.id, kind: container.layerKind, baseRevision: container.baseRevision)
            manifest.packages.removeAll { $0.name == name }
            manifest.packages.append(InstalledPackage(
                name: name,
                version: version,
                architecture: payload.control["Architecture"] ?? "all",
                layer: container.layerKind,
                license: payload.control["License"],
                source: payload.control["Source"],
                requiresBase: payload.control["Floe-Requires-Base"],
                files: files
            ))
            try manifest.write(to: container.layerURL)
            return Result(output: "Selecting previously unselected package \(name).\nUnpacking \(name) (\(version)) ...\nSetting up \(name) (\(version)) ...")
        } catch {
            return Result(output: "dpkg: error: \(error.localizedDescription)", exitCode: 2)
        }
    }
}
