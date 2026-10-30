import Foundation
import FloeCore
import FloeTools

/// Same package contract as the guest adapter, executed through the selected
/// authenticated target. Environment-local Python/npm trees are rebuilt, not copied.
struct TaskTargetDependencyOperations: SkillDependencyPackageOperating {
    typealias Execute = @Sendable (String, ToolEnvironment, CancellationToken?) async throws -> String
    let execute: Execute

    private func pythonInventory(ownedOnly: Bool, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String] {
        if ownedOnly {
            let exists = try await execute("if [ -x .floe-env/bin/python ]; then printf yes; fi", environment, cancellation)
            if exists.trimmingCharacters(in: .whitespacesAndNewlines) != "yes" { return [:] }
        }
        let source = ownedOnly
            ? "import importlib.metadata as m,json,sysconfig; print(json.dumps({d.metadata['Name'].lower().replace('_','-'):d.version for d in m.distributions(path=[sysconfig.get_path('purelib')])}))"
            : "import importlib.metadata as m,json; print(json.dumps({d.metadata['Name'].lower().replace('_','-'):d.version for d in m.distributions()}))"
        let output = try await execute("py=python3; [ ! -x .floe-env/bin/python ] || py=.floe-env/bin/python; \"$py\" -c " + Self.quote(source), environment, cancellation)
        return try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
    }
    func pythonInstalledVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String] {
        try await pythonInventory(ownedOnly: false, environment: environment, cancellation: cancellation)
    }
    func pythonOwnedVenvVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String]? {
        try await pythonInventory(ownedOnly: true, environment: environment, cancellation: cancellation)
    }
    func pythonEnsure(spec: String, hashes: [String], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await pythonInstallPins([(spec, hashes)], environment: environment, cancellation: cancellation)
    }
    func pythonInstallPins(_ pins: [(spec: String, hashes: [String])], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        let lines = pins.map { $0.spec + $0.hashes.map { " --hash=sha256:" + $0 }.joined() }.joined(separator: "\n") + "\n"
        let encoded = Data(lines.utf8).base64EncodedString()
        let hashed = pins.contains { !$0.hashes.isEmpty }
        guard !hashed || pins.allSatisfy({ !$0.hashes.isEmpty }) else { throw FloeError.validationFailed("The Python lock is incomplete") }
        // A single full-closure pip transaction preserves every signed transitive hash.
        return try await execute("""
            set -e
            [ -x .floe-env/bin/python ] || python3 -m venv --system-site-packages .floe-env
            .floe-env/bin/python -c \(Self.quote("import base64;open('.floe-env/floe-requirements.txt','wb').write(base64.b64decode('" + encoded + "'))"))
            .floe-env/bin/python -m pip install --disable-pip-version-check \(hashed ? "--require-hashes" : "") -r .floe-env/floe-requirements.txt
            """, environment, cancellation)
    }
    func aptInstalledVersion(identity: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String? {
        let text = try await execute("dpkg-query -W -f='${Status}\\t${Version}' " + Self.quote(identity) + " 2>/dev/null || true", environment, cancellation)
        guard text.hasPrefix("install ok installed\t") else { return nil }
        return String(text.dropFirst("install ok installed\t".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func aptEnsure(identity: String, version: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await execute("if [ \"$(id -u)\" = 0 ]; then apt-get install -y --no-install-recommends " + Self.quote(identity + "=" + version)
            + "; else sudo -n apt-get install -y --no-install-recommends " + Self.quote(identity + "=" + version) + "; fi", environment, cancellation)
    }
    func nodeInstalledVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String] {
        let text = try await execute("if [ -f .floe-node/package.json ]; then npm ls --prefix .floe-node --depth=0 --json 2>/dev/null || test $? -eq 1; else printf '{}'; fi", environment, cancellation)
        struct Tree: Decodable { struct Item: Decodable { let version: String? }; let dependencies: [String: Item]? }
        let tree = try JSONDecoder().decode(Tree.self, from: Data(text.utf8))
        return (tree.dependencies ?? [:]).compactMapValues(\.version)
    }
    func npmEnsure(spec: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await execute("npm install --prefix .floe-node --save-exact --ignore-scripts " + Self.quote(spec), environment, cancellation)
    }
    func fontEnsure(identity: String, version: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        let result = try await aptEnsure(identity: identity, version: version, environment: environment, cancellation: cancellation)
        _ = try await execute("fc-cache -f", environment, cancellation)
        return result
    }
    func cjkProbePasses(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> Bool {
        let output = try await execute("fc-list :lang=zh family | head -n 1", environment, cancellation)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
