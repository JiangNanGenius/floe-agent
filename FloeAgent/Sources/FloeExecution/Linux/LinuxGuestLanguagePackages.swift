// FloeExecution — package ownership for Linux environments.
//
// An environment whose `executionBackend` is `linuxVM` owns its language
// packages inside the guest, never on the iOS host:
//
//  - Python is the single shared venv at `/floe/env/python/venv` created by
//    `LinuxGuestPythonProvisioner`; installs/uninstalls/inspection run the
//    venv's real `python3 -m pip` in the guest with the environment's
//    configured index, so riscv64 wheels are allowed (the iOS wheelhouse
//    restriction belongs to the native CPython path only) and the shell,
//    `exec.localPython`, `python.packages` and the package UI all read back
//    the same site-packages.
//  - Node runs the guest's real npm/pnpm against the environment prefix
//    `/floe/env/usr` with the same staged, recoverable generation the native
//    managed installer uses (`var/floe-node-transaction` inside the layer),
//    producing `/floe/env/usr/lib/node_modules`. The iOS nodejs-mobile runtime
//    is never involved for a Linux environment.
//
// An environment owned by the Linux backend but with its guest stopped fails
// with the honest "start the Linux environment" error; it never falls back to
// host-side layer writes or the host Node runtime. Native environments never
// resolve here.

import Foundation
import FloeCore
import FloeTools

/// One Python distribution visible to the shared venv interpreter.
public struct LinuxGuestPythonDistribution: Sendable, Equatable {
    public var name: String
    public var version: String
    public var location: String
    /// True when the distribution lives in the environment's venv
    /// site-packages (the writable managed target), false for a system
    /// (guest image) distribution that is only visible through
    /// `--system-site-packages`.
    public var writable: Bool

    public init(name: String, version: String, location: String, writable: Bool) {
        self.name = name
        self.version = version
        self.location = location
        self.writable = writable
    }
}

/// One environment-level Node package read from the layer's
/// `usr/lib/node_modules` inside the guest.
public struct LinuxGuestNodePackage: Sendable, Equatable {
    public var name: String
    public var version: String
    public var path: String

    public init(name: String, version: String, path: String) {
        self.name = name
        self.version = version
        self.path = path
    }
}

/// Python/Node package operations for one injected Linux guest runner.
public struct LinuxGuestLanguagePackages: Sendable {
    /// Guest-side pip cache, kept inside the environment layer so a package is
    /// downloaded once and survives a guest restart. One path with the runner
    /// default (see LinuxGuestWritablePaths).
    public static let pythonCacheDirectory = LinuxGuestWritablePaths.pipCache
    /// Guest-side npm/pnpm caches and the Node transaction root.
    public static let nodeTransactionRoot = LinuxGuestNodeEnvironment.guestTransactionRoot

    /// App-wide shared download cache root, exported by the host as the
    /// optional `floe-cache` 9p share and mounted at `/floe/cache`. It holds
    /// only re-downloadable objects (pip wheels, npm tarballs); a package is
    /// downloaded once and reused across environments. It is used only after
    /// the guest itself reports a real mount, never assumed from a path.
    public static let sharedCacheRoot = "/floe/cache"

    private let runner: any LinuxCommandRunning

    public init(runner: any LinuxCommandRunning) {
        self.runner = runner
    }

    /// Resolves which guest cache directory an install must use. When the
    /// host exported the shared cache share and the running guest actually
    /// mounted it (`/proc/mounts`), the shared path wins; otherwise the
    /// per-environment layer cache stays in effect. This mirrors the runner
    /// PID-1 decision in `floe_exec.c`, so direct shell installs and managed
    /// installs cannot disagree about where downloads live.
    private func cacheDirectory(kind: String, environmentFallback: String,
                                environmentID: String, cancellation: CancellationToken?) async -> String {
        let shared = Self.sharedCacheRoot + "/" + kind
        guard await isSharedCacheMounted(environmentID: environmentID, cancellation: cancellation) else {
            return environmentFallback
        }
        return shared
    }

    /// One bounded read of /proc/mounts per decision. A failing or absent
    /// guest answers false (per-environment fallback), never an error that
    /// blocks an unrelated package operation.
    private func isSharedCacheMounted(environmentID: String, cancellation: CancellationToken?) async -> Bool {
        let result: LinuxCommandResult
        do {
            result = try await runner.run(
                environmentID: environmentID,
                argv: ["/bin/sh", "-c",
                       #"grep -q '  /floe/cache ' /proc/mounts && mkdir -p /floe/cache/pip /floe/cache/npm /floe/cache/xdg"#],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 15,
                maxOutputBytes: 1024,
                cancellation: cancellation
            )
        } catch {
            return false
        }
        return result.exitCode == 0
    }

    // MARK: - Ownership

    public func owns(environmentID: String) async -> Bool {
        await runner.ownsLinuxEnvironment(environmentID: environmentID)
    }

    public func isRunning(environmentID: String) async -> Bool {
        await runner.supports(environmentID: environmentID)
    }

    /// The second race-safe gate: a command must never reach a stopped guest.
    private func requireRunning(_ environmentID: String) async throws {
        guard await runner.ownsLinuxEnvironment(environmentID: environmentID) else {
            throw LinuxGuestError.notOwned(environmentID: environmentID)
        }
        guard await runner.supports(environmentID: environmentID) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
    }

    // MARK: - Python (real pip inside the shared venv)

    public func pythonInstall(
        specs: [String],
        environment: ToolEnvironment,
        timeout: TimeInterval = 180,
        cancellation: CancellationToken?
    ) async throws -> String {
        try await requireRunning(environment.id)
        let venv = try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let sources = try LanguagePackageSources.load(in: environment.writableLayerURL)
        let pipCache = await cacheDirectory(
            kind: "pip",
            environmentFallback: Self.pythonCacheDirectory,
            environmentID: environment.id,
            cancellation: cancellation
        )
        let variables: [String: String] = [
            "VIRTUAL_ENV": venv.venvPath,
            "PATH": venv.venvPath + "/bin:" + LinuxGuestNodeEnvironment.defaultGuestPath,
            "PYTHONUNBUFFERED": "1",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_NO_INPUT": "1",
            "PIP_CACHE_DIR": pipCache,
            // The user's explicit source configuration wins over any guest
            // pip configuration file; the iOS wheelhouse index never applies
            // to a Linux guest.
            "PIP_INDEX_URL": sources.pythonIndex,
            "PIP_EXTRA_INDEX_URL": "",
            "PIP_TRUSTED_HOST": ""
        ]
        let argv = ["/usr/bin/env"]
            + (LinuxGuestEnvironmentEncoding.argv(variables) ?? [])
            + [venv.pythonPath, "-m", "pip", "install", "--disable-pip-version-check", "--no-input"]
            + specs
        let effectiveTimeout = min(600, max(timeout, 120))
        let result = try await runner.run(
            environmentID: environment.id,
            argv: argv,
            workingDirectory: nil,
            standardInput: nil,
            timeout: effectiveTimeout,
            maxOutputBytes: 256 * 1024,
            cancellation: cancellation
        )
        let output = result.stderr.isEmpty ? result.stdout : result.stdout + "\n" + result.stderr
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("pip 退出码 \(result.exitCode)\n" + bounded(output))
        }
        return output
    }

    public func pythonUninstall(
        distribution: String,
        environment: ToolEnvironment,
        timeout: TimeInterval = 180,
        cancellation: CancellationToken?
    ) async throws -> String {
        guard distribution.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw FloeError.validationFailed("pip 卸载只接受单个发行包名")
        }
        try await requireRunning(environment.id)
        let venv = try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let result = try await runner.run(
            environmentID: environment.id,
            argv: [venv.pipPath, "uninstall", "-y", distribution],
            workingDirectory: nil,
            standardInput: nil,
            timeout: min(600, max(timeout, 120)),
            maxOutputBytes: 256 * 1024,
            cancellation: cancellation
        )
        let output = result.stderr.isEmpty ? result.stdout : result.stdout + "\n" + result.stderr
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("pip uninstall 退出码 \(result.exitCode)\n" + bounded(output))
        }
        return output
    }

    /// Fixed inspection commands forwarded to the venv's own pip. The shell
    /// parser already restricts the accepted commands and arguments.
    public func pythonInspect(
        command: String,
        arguments: [String],
        environment: ToolEnvironment,
        timeout: TimeInterval = 60,
        cancellation: CancellationToken?
    ) async throws -> String {
        try await requireRunning(environment.id)
        let venv = try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let result = try await runner.run(
            environmentID: environment.id,
            argv: [venv.pythonPath, "-m", "pip", command] + arguments,
            workingDirectory: nil,
            standardInput: nil,
            timeout: min(600, max(timeout, 30)),
            maxOutputBytes: 256 * 1024,
            cancellation: cancellation
        )
        let output = result.stderr.isEmpty ? result.stdout : result.stdout + "\n" + result.stderr
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("pip \(command) 退出码 \(result.exitCode)\n" + bounded(output))
        }
        return output
    }

    /// Distributions the shared venv sees, read back through the venv
    /// interpreter itself (never by scanning host directories).
    public func pythonInventory(
        environment: ToolEnvironment,
        cancellation: CancellationToken?
    ) async throws -> [LinuxGuestPythonDistribution] {
        try await requireRunning(environment.id)
        let venv = try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let result = try await runner.run(
            environmentID: environment.id,
            argv: [venv.pythonPath, "-c", Self.pythonInventoryScript],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 512 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("Python 依赖读取失败：\n" + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        guard let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("floePythonInventory=") }) else {
            throw FloeError.validationFailed("Python 依赖读取没有返回清单")
        }
        let json = String(line.dropFirst("floePythonInventory=".count))
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FloeError.validationFailed("Python 依赖清单不可解析")
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return LinuxGuestPythonDistribution(
                name: name,
                version: row["version"] as? String ?? "",
                location: row["location"] as? String ?? "",
                writable: row["writable"] as? Bool ?? false
            )
        }
    }

    /// Names only, for the capability installer's installed-entry readback.
    public func pythonDistributionNames(environment: ToolEnvironment) async -> [String] {
        guard let rows = try? await pythonInventory(environment: environment, cancellation: nil) else { return [] }
        return rows.map(\.name)
    }

    /// Post-install verification line, resolved by the venv interpreter.
    public func pythonVerification(
        specs: [String],
        environment: ToolEnvironment
    ) async -> String {
        func normalized(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
        }
        let names = specs.map { spec -> String in
            spec.split(separator: "=", maxSplits: 1).first.map(String.init) ?? spec
        }
        guard let rows = try? await pythonInventory(environment: environment, cancellation: nil) else {
            return "installVerify=unavailable"
        }
        let wanted = Set(names.map(normalized))
        let matches = rows.filter { wanted.contains(normalized($0.name)) }
        let payload = matches.map { ["name": $0.name, "version": $0.version, "location": $0.location, "writable": $0.writable] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "installVerify=unavailable" }
        return "installVerify=" + json
    }

    // MARK: - Node (real npm/pnpm inside the guest)

    /// Current guest managers without installing anything. Used by the package
    /// UI's manager selection.
    public func nodeManagers(environmentID: String, cancellation: CancellationToken?) async -> LinuxGuestNodeManagers {
        await LinuxGuestNodeProvisioner.shared.probe(
            environmentID: environmentID,
            runner: runner,
            cancellation: cancellation
        )
    }

    /// Environment-level packages under `/floe/env/usr/lib/node_modules`.
    public func nodeInventory(
        environment: ToolEnvironment,
        cancellation: CancellationToken?
    ) async throws -> [LinuxGuestNodePackage] {
        try await requireRunning(environment.id)
        let result = try await runner.run(
            environmentID: environment.id,
            argv: ["/bin/sh", "-c", Self.nodeInventoryScript],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 512 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("Node 依赖读取失败：\n" + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return Self.parseNodePackages(result.stdout).map { LinuxGuestNodePackage(name: $0.name, version: $0.version, path: $0.path) }
    }

    /// One managed generation change, mirroring the native installer's staged,
    /// recoverable transaction — but executed entirely inside the guest with
    /// its real npm/pnpm and the layer's own directories.
    public func nodeChange(
        environment: ToolEnvironment,
        specifications: [String],
        remove: Bool,
        manager: NodePackageManager,
        timeout: TimeInterval = 180,
        cancellation: CancellationToken?
    ) async throws -> String {
        guard specifications.count <= 256 else { throw FloeError.validationFailed("一次最多更新 256 个依赖") }
        for specification in specifications {
            try NodePackageManagerPolicy.validateSpecification(specification, remove: remove)
        }
        try await requireRunning(environment.id)
        try await recoverNodeTransaction(environmentID: environment.id, cancellation: cancellation)
        let node = try await LinuxGuestNodeProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let managerPath: String
        switch manager {
        case .npm:
            managerPath = node.npmPath
        case .pnpm:
            guard let pnpm = node.pnpmPath else {
                throw FloeError.validationFailed("此 Linux 环境没有可用的 pnpm；请先在 guest 中安装 pnpm 或改用 npm")
            }
            managerPath = pnpm
        }
        let registry = try LanguagePackageSources.load(in: environment.writableLayerURL).nodeRegistry

        let state = try await readNodeState(environmentID: environment.id, cancellation: cancellation)
        var dependencies = state.dependencies ?? [:]
        for specification in specifications {
            if remove {
                guard dependencies.removeValue(forKey: specification) != nil else {
                    throw FloeError.validationFailed("此包不是本层直接安装的依赖；请先检查依赖它的软件包")
                }
            } else {
                let split = specification.dropFirst().lastIndex(of: "@")
                let name = split.map { String(specification[..<$0]) } ?? specification
                let version = split.map { String(specification[specification.index(after: $0)...]) } ?? "latest"
                dependencies[name] = version
            }
        }
        for (name, version) in dependencies {
            try NodePackageManagerPolicy.validateSpecification(name + "@" + version, remove: false)
        }
        let manifest: [String: Any] = [
            "name": "floe-managed-environment",
            "version": "1.0.0",
            "private": true,
            "dependencies": dependencies
        ]
        guard let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) else {
            throw FloeError.validationFailed("Node 依赖清单无法生成")
        }
        let lockName = manager == .npm ? "package-lock.json" : "pnpm-lock.yaml"
        let stage = Self.nodeTransactionRoot + "/stage"
        let destination = LinuxGuestNodeEnvironment.guestNodeModules

        try await prepareNodeTransaction(environmentID: environment.id, cancellation: cancellation)
        try await writeGuestFile(
            environmentID: environment.id,
            path: stage + "/package.json",
            data: manifestData,
            cancellation: cancellation
        )
        if state.registry == registry, state.lockFiles.contains(lockName) {
            try await runShell(
                environmentID: environment.id,
                script: #"cp "$1" "$2""#,
                arguments: [destination + "/.floe-install/" + lockName, stage + "/" + lockName],
                cancellation: cancellation
            )
        }

        let output: String
        let npmCache = await cacheDirectory(
            kind: "npm",
            environmentFallback: LinuxGuestWritablePaths.npmCache,
            environmentID: environment.id,
            cancellation: cancellation
        )
        do {
            let variables: [String: String] = [
                "HOME": LinuxGuestMountPoint.environment + "/home",
                "TMPDIR": LinuxGuestWritablePaths.tmp,
                "TMP": LinuxGuestWritablePaths.tmp,
                "TEMP": LinuxGuestWritablePaths.tmp,
                "npm_config_cache": npmCache,
                "npm_config_store_dir": LinuxGuestMountPoint.environment + "/opt/pnpm-store",
                "npm_config_prefix": stage,
                "npm_config_global": "false",
                "npm_config_userconfig": Self.nodeTransactionRoot + "/empty.npmrc",
                "npm_config_globalconfig": Self.nodeTransactionRoot + "/empty-global.npmrc",
                "npm_config_manage_package_manager_versions": "false",
                "CI": "1",
                "PATH": node.pathDirectory + ":" + LinuxGuestNodeEnvironment.guestBin + ":" + LinuxGuestNodeEnvironment.defaultGuestPath,
                "NODE_PATH": destination
            ]
            // Linux environments keep real npm/pnpm semantics: lifecycle
            // scripts, bin links and Linux-native addons are allowed. Only
            // the staging location is Floe's convention, not the package
            // feature set (the iOS binary/script restrictions belong to the
            // native nodejs-mobile path and never apply here).
            let common = ["install", "--registry=" + registry]
            let options = manager == .npm
                ? ["--no-audit", "--no-fund"]
                : ["--config.node-linker=hoisted", "--package-import-method=copy", "--no-frozen-lockfile",
                   "--config.verify-deps-before-run=never"]
            let argv = ["/usr/bin/env"]
                + (LinuxGuestEnvironmentEncoding.argv(variables) ?? [])
                + [managerPath] + common + options
            let result = try await runner.run(
                environmentID: environment.id,
                argv: argv,
                workingDirectory: stage,
                standardInput: nil,
                timeout: min(600, max(timeout, 60)),
                maxOutputBytes: 256 * 1024,
                cancellation: cancellation
            )
            output = result.stderr.isEmpty ? result.stdout : result.stdout + "\n" + result.stderr
            guard result.exitCode == 0 else {
                throw FloeError.validationFailed("npm 退出码 \(result.exitCode)\n" + bounded(output))
            }
            try cancellation?.throwIfCancelled()
            try await writeNodeMetadata(
                environmentID: environment.id,
                stage: stage,
                dependencies: dependencies,
                manager: manager,
                registry: registry,
                lockName: lockName,
                cancellation: cancellation
            )
            try await commitNodeTransaction(
                environmentID: environment.id,
                nodePath: node.nodePath,
                cancellation: cancellation
            )
            return output
        } catch {
            do { try await recoverNodeTransaction(environmentID: environment.id, cancellation: nil) }
            catch { throw FloeError.validationFailed("npm 恢复未完成，暂存数据已保留：\(error.localizedDescription)") }
            throw error
        }
    }

    // MARK: - Guest scripts

    static let pythonInventoryScript = #"""
    import importlib.metadata as _metadata
    import json as _json
    import os as _os
    import re as _re
    import sysconfig as _sysconfig
    _target = _os.path.realpath(_sysconfig.get_paths()["purelib"])
    _rows = []
    _seen = set()
    for _distribution in _metadata.distributions():
        try:
            _name = _distribution.metadata.get("Name")
        except Exception:
            _name = None
        if not _name:
            continue
        _key = _re.sub(r"[-_.]+", "-", _name).lower()
        if _key in _seen:
            continue
        _seen.add(_key)
        try:
            _version = _distribution.version or ""
        except Exception:
            _version = ""
        _location = str(_distribution.locate_file(""))
        _real = _os.path.realpath(_location)
        _writable = _real == _target or _real.startswith(_target + _os.sep)
        _rows.append({"name": _name, "version": _version, "location": _location, "writable": _writable})
    print("floePythonInventory=" + _json.dumps(_rows, ensure_ascii=False))
    """#

    /// Reads the current generation: dependencies (or the legacy top-level
    /// packages), the registry the previous install used, the manager and any
    /// reusable lock file. Runs inside the guest.
    static let nodeStateScript = #"""
    dest=/floe/env/usr/lib/node_modules
    meta=$dest/.floe-install
    if [ -e "$dest" ]; then printf 'floeDest 1\n'; fi
    for name in dependencies.json registry manager; do
      f="$meta/$name"
      [ -f "$f" ] || continue
      printf 'floeMeta %s ' "$name"
      base64 -w0 "$f" 2>/dev/null || base64 "$f" | tr -d '\n'
      printf '\n'
    done
    for lock in package-lock.json pnpm-lock.yaml; do
      if [ -f "$meta/$lock" ]; then printf 'floeLock %s\n' "$lock"; fi
    done
    for f in "$dest"/package.json "$dest"/*/package.json "$dest"/@*/*/package.json; do
      [ -f "$f" ] || continue
      printf 'floePkg %s ' "$f"
      base64 -w0 "$f" 2>/dev/null || base64 "$f" | tr -d '\n'
      printf '\n'
    done
    """#

    static let nodeInventoryScript = #"""
    dest=/floe/env/usr/lib/node_modules
    for f in "$dest"/package.json "$dest"/*/package.json "$dest"/@*/*/package.json; do
      [ -f "$f" ] || continue
      printf 'floePkg %s ' "$f"
      base64 -w0 "$f" 2>/dev/null || base64 "$f" | tr -d '\n'
      printf '\n'
    done
    """#

    /// Restores the previous generation when an interrupted commit left a
    /// transaction behind, then removes the transaction. Prepared-only
    /// transactions have nothing to restore.
    static let nodeRecoveryScript = #"""
    tx=/floe/env/var/floe-node-transaction
    dest=/floe/env/usr/lib/node_modules
    if [ -d "$tx" ]; then
      phase=$(cat "$tx/journal" 2>/dev/null || echo none)
      if [ "$phase" = "committing" ]; then
        if [ -e "$tx/backup" ]; then
          rm -rf "$dest"
          mv "$tx/backup" "$dest"
        elif [ "$(cat "$tx/had_original" 2>/dev/null || echo 1)" = "0" ] && [ -e "$dest" ]; then
          rm -rf "$dest"
        fi
      fi
      rm -rf "$tx"
    fi
    """#

    /// Links top-level package CLIs into the environment bin directory after
    /// the generation is in place. npm/pnpm project installs only create
    /// `node_modules/.bin`, which is not on the guest PATH; the managed
    /// environment prefix must expose the same commands a global install
    /// would (`/floe/env/usr/bin/<command>`). Links are relative to the final
    /// module root, so a later generation swap keeps them valid; stale links
    /// that pointed into this module root are removed.
    static let nodeBinLinkScript = #"""
    const fs = require('fs');
    const path = require('path');
    const modules = process.argv[1];
    const binDir = process.argv[2];
    fs.mkdirSync(binDir, { recursive: true });
    const packages = [];
    const visit = (dir, prefix) => {
      let entries = [];
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const entry of entries) {
        if (entry.name.startsWith('.')) continue;
        if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
        const full = path.join(dir, entry.name);
        if (entry.name.startsWith('@') && prefix === '') { visit(full, entry.name + '/'); continue; }
        packages.push({ relative: prefix + entry.name, full });
      }
    };
    visit(modules, '');
    const linked = [];
    for (const pkg of packages) {
      let manifest;
      try { manifest = JSON.parse(fs.readFileSync(path.join(pkg.full, 'package.json'), 'utf8')); } catch { continue; }
      const bin = manifest.bin;
      if (!bin) continue;
      const entries = typeof bin === 'string'
        ? { [String(manifest.name || '').split('/').pop()]: bin }
        : bin;
      for (const [name, relative] of Object.entries(entries)) {
        if (!/^[A-Za-z0-9._-]+$/.test(name) || typeof relative !== 'string') continue;
        const target = path.join(modules, pkg.relative, relative);
        if (!fs.existsSync(target)) continue;
        try { fs.chmodSync(target, 0o755); } catch {}
        const dest = path.join(binDir, name);
        try { fs.rmSync(dest, { force: true }); } catch {}
        try { fs.symlinkSync(target, dest); }
        catch {
          const script = '#!/bin/sh\nexec /usr/bin/env node "' + target.replace(/"/g, '\\"') + '" "$@"\n';
          fs.writeFileSync(dest, script);
          fs.chmodSync(dest, 0o755);
        }
        linked.push(name);
      }
    }
    const wanted = new Set(linked);
    for (const entry of fs.readdirSync(binDir, { withFileTypes: true })) {
      if (wanted.has(entry.name)) continue;
      const full = path.join(binDir, entry.name);
      let target = null;
      try { if (entry.isSymbolicLink()) target = fs.realpathSync(full); } catch {
        try { if (entry.isSymbolicLink()) target = fs.readlinkSync(full); } catch {}
      }
      if (target && (target === modules || target.startsWith(modules + path.sep))) {
        try { fs.rmSync(full, { force: true }); } catch {}
      }
    }
    console.log('floeNodeBins=' + linked.sort().join(','));
    """#

    // MARK: - Guest helpers

    private func readNodeState(
        environmentID: String,
        cancellation: CancellationToken?
    ) async throws -> NodeState {
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", Self.nodeStateScript],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 512 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("Node 依赖状态读取失败：\n" + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        var state = NodeState()
        var scanned: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            if line == "floeDest 1" { state.destinationExists = true; continue }
            if line.hasPrefix("floeLock ") {
                state.lockFiles.insert(String(line.dropFirst("floeLock ".count)))
                continue
            }
            if line.hasPrefix("floeMeta ") {
                let rest = line.dropFirst("floeMeta ".count)
                guard let space = rest.firstIndex(of: " ") else { continue }
                let name = String(rest[..<space])
                guard let data = Data(base64Encoded: String(rest[rest.index(after: space)...])) else { continue }
                switch name {
                case "dependencies.json":
                    state.dependencies = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
                case "registry":
                    state.registry = String(decoding: data, as: UTF8.self)
                case "manager":
                    state.manager = String(decoding: data, as: UTF8.self)
                default:
                    break
                }
                continue
            }
            if line.hasPrefix("floePkg ") {
                let rest = line.dropFirst("floePkg ".count)
                guard let space = rest.firstIndex(of: " ") else { continue }
                guard let data = Data(base64Encoded: String(rest[rest.index(after: space)...])),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String else { continue }
                scanned[name] = json["version"] as? String ?? ""
            }
        }
        if state.dependencies == nil {
            // Legacy global installs kept no dependency record; every
            // top-level package was an explicit install.
            state.dependencies = scanned
        }
        return state
    }

    /// Parses `floePkg <path> <base64 package.json>` lines.
    static func parseNodePackages(_ stdout: String) -> [(name: String, version: String, path: String)] {
        var rows: [(name: String, version: String, path: String)] = []
        for line in stdout.split(separator: "\n") where line.hasPrefix("floePkg ") {
            let rest = line.dropFirst("floePkg ".count)
            guard let space = rest.firstIndex(of: " ") else { continue }
            let path = String(rest[..<space])
            guard let data = Data(base64Encoded: String(rest[rest.index(after: space)...])),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String, !name.isEmpty else { continue }
            rows.append((name: name, version: json["version"] as? String ?? "", path: path))
        }
        return rows
    }

    private func recoverNodeTransaction(environmentID: String, cancellation: CancellationToken?) async throws {
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", Self.nodeRecoveryScript],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 16 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("Node 事务恢复失败：\n" + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    private func prepareNodeTransaction(environmentID: String, cancellation: CancellationToken?) async throws {
        let script = #"""
        set -e
        dest=/floe/env/usr/lib/node_modules
        tx=/floe/env/var/floe-node-transaction
        rm -rf "$tx"
        mkdir -p "$tx/stage" /floe/env/usr/lib /floe/env/home /floe/env/tmp /floe/env/cache/npm /floe/env/cache/pip /floe/env/cache/xdg /floe/env/opt/pnpm-store
        : > "$tx/empty.npmrc"
        : > "$tx/empty-global.npmrc"
        printf 'prepared' > "$tx/journal"
        if [ -e "$dest" ]; then printf '1' > "$tx/had_original"; else printf '0' > "$tx/had_original"; fi
        """#
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", script],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 16 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("Node 暂存目录准备失败：\n" + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    private func runShell(
        environmentID: String,
        script: String,
        arguments: [String],
        cancellation: CancellationToken?
    ) async throws {
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", script] + arguments,
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 16 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("guest 命令失败：\n" + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    /// Writes a guest file in bounded base64 chunks so no single command can
    /// exceed the console channel's payload ceiling.
    private func writeGuestFile(
        environmentID: String,
        path: String,
        data: Data,
        cancellation: CancellationToken?
    ) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        try await runShell(
            environmentID: environmentID,
            script: #"mkdir -p "$1" && : > "$2""#,
            arguments: [directory, path],
            cancellation: cancellation
        )
        let base64 = data.base64EncodedString()
        guard !base64.isEmpty else { return }
        var offset = base64.startIndex
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: min(16_384, base64.distance(from: offset, to: base64.endIndex)))
            let chunk = String(base64[offset..<end])
            try await runShell(
                environmentID: environmentID,
                script: #"printf %s "$1" | base64 -d >> "$2""#,
                arguments: [chunk, path],
                cancellation: cancellation
            )
            offset = end
        }
    }

    private func writeNodeMetadata(
        environmentID: String,
        stage: String,
        dependencies: [String: String],
        manager: NodePackageManager,
        registry: String,
        lockName: String,
        cancellation: CancellationToken?
    ) async throws {
        try await runShell(
            environmentID: environmentID,
            script: #"mkdir -p "$1" "$2""#,
            arguments: [stage + "/node_modules", stage + "/node_modules/.floe-install"],
            cancellation: cancellation
        )
        guard let dependenciesData = try? JSONSerialization.data(withJSONObject: dependencies, options: [.sortedKeys]) else {
            throw FloeError.validationFailed("Node 依赖记录无法生成")
        }
        let metadata = stage + "/node_modules/.floe-install"
        try await writeGuestFile(
            environmentID: environmentID,
            path: metadata + "/dependencies.json",
            data: dependenciesData,
            cancellation: cancellation
        )
        try await writeGuestFile(
            environmentID: environmentID,
            path: metadata + "/manager",
            data: Data(manager.rawValue.utf8),
            cancellation: cancellation
        )
        try await writeGuestFile(
            environmentID: environmentID,
            path: metadata + "/registry",
            data: Data(registry.utf8),
            cancellation: cancellation
        )
        try await runShell(
            environmentID: environmentID,
            script: #"if [ -f "$1" ]; then cp "$1" "$2"; fi"#,
            arguments: [stage + "/" + lockName, metadata + "/" + lockName],
            cancellation: cancellation
        )
    }

    private func commitNodeTransaction(
        environmentID: String,
        nodePath: String,
        cancellation: CancellationToken?
    ) async throws {
        // The bin-link script lives beside the stage; it is written before the
        // swap and links the final (post-swap) module path into guestBin, so
        // installed CLIs are callable from the guest shell and services.
        try await writeGuestFile(
            environmentID: environmentID,
            path: Self.nodeTransactionRoot + "/bin-link.js",
            data: Data(Self.nodeBinLinkScript.utf8),
            cancellation: cancellation
        )
        let script = #"""
        set -e
        nodeBin="$1"
        tx=/floe/env/var/floe-node-transaction
        dest=/floe/env/usr/lib/node_modules
        stage=$tx/stage
        mkdir -p "$stage/node_modules"
        printf 'committing' > "$tx/journal"
        if [ -e "$dest" ]; then
          rm -rf "$tx/backup"
          mv "$dest" "$tx/backup"
        fi
        mkdir -p /floe/env/usr/lib
        mv "$stage/node_modules" "$dest"
        if [ -f "$tx/bin-link.js" ]; then
          "$nodeBin" "$tx/bin-link.js" "$dest" /floe/env/usr/bin
        fi
        printf 'committed' > "$tx/journal"
        rm -rf "$tx"
        """#
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", script, "floe", nodePath],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 120,
            maxOutputBytes: 64 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed("Node 事务提交失败：\n" + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    private func bounded(_ text: String) -> String {
        String(text.suffix(1_200)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct NodeState {
        var destinationExists = false
        var dependencies: [String: String]?
        var registry: String?
        var manager: String?
        var lockFiles: Set<String> = []
    }
}
