import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

private actor SourceRunner: LinuxCommandRunning {
    struct Call: Sendable {
        let environmentID: String
        let argv: [String]
        let input: String?
        let cancellation: CancellationToken?
    }
    let output: String
    let running: Bool
    let owns: Bool
    let cancelOnRun: Bool
    private(set) var calls: [Call] = []
    init(output: String, running: Bool = true, owns: Bool = true, cancelOnRun: Bool = false) {
        self.output = output; self.running = running; self.owns = owns; self.cancelOnRun = cancelOnRun
    }
    func supports(environmentID: String) async -> Bool { running }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { owns }
    func run(environmentID: String, argv: [String], workingDirectory: String?, standardInput: String?,
             timeout: TimeInterval, maxOutputBytes: Int, cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        calls.append(Call(environmentID: environmentID, argv: argv, input: standardInput, cancellation: cancellation))
        if cancelOnRun { cancellation?.cancel() }
        return LinuxCommandResult(stdout: output, stderr: "", exitCode: 0)
    }
}

@Suite("Linux package source presets")
struct LinuxPackageSourceTests {
    private let tuna = #"{"selection":"tuna","sourceList":"/etc/apt/sources.list","sourceParts":"/etc/apt/sources.list.d/","uri":"https://mirrors.tuna.tsinghua.edu.cn/debian","verified":true}"#
    private let system = #"{"selection":"system","sourceList":"/etc/apt/sources.list","sourceParts":"/etc/apt/sources.list.d/","uri":null,"verified":true}"#

    @Test func catalogContainsOfficialAndTUNAKeepingOfficialSignedSecurity() throws {
        let catalog = try LinuxPackageSourceCatalog.bundled()
        #expect(Set(catalog.apt.map(\.id)) == ["official", "tuna"])
        #expect(catalog.apt.first { $0.id == "official" }?.uri == "https://deb.debian.org/debian")
        #expect(catalog.apt.first { $0.id == "tuna" }?.uri == "https://mirrors.tuna.tsinghua.edu.cn/debian")
        #expect(catalog.apt.allSatisfy { $0.securityURI == "https://security.debian.org/debian-security" && $0.signedBy == "/usr/share/keyrings/debian-archive-keyring.gpg" })
        #expect(catalog.python.first { $0.id == "official" }?.indexURL == LanguagePackageSources().pythonIndex)
        #expect(catalog.python.first { $0.id == "tuna" }?.indexURL == "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/")
        #expect(LinuxPackageSourceCatalog.modelInstructions.contains("mirrors.tuna.tsinghua.edu.cn"))
    }

    @Test func customPythonSourcePersistsAndCatalogListingDoesNotChangeIt() throws {
        let testRoot = ProcessInfo.processInfo.environment["FLOE_PACKAGE_SOURCE_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = testRoot.appendingPathComponent("source-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var custom = LanguagePackageSources(pythonIndex: "https://packages.example.invalid/simple/", nodeRegistry: "https://registry.example.invalid/")
        try custom.save(in: root)
        let before = try Data(contentsOf: root.appendingPathComponent("var/language-package-sources.json"))
        let preset = try #require(LinuxPackageSourceCatalog.bundled().python.first { $0.id == "tuna" })
        #expect(try Data(contentsOf: root.appendingPathComponent("var/language-package-sources.json")) == before)
        #expect(try LanguagePackageSources.load(in: root) == custom)
        custom.pythonIndex = preset.indexURL
        try custom.save(in: root)
        #expect(try LanguagePackageSources.load(in: root).pythonIndex == preset.indexURL)
        #expect(try LanguagePackageSources.load(in: root).nodeRegistry == "https://registry.example.invalid/")
    }

    @Test func inspectionRemainsReadOnlyAndCarriesExactEnvironment() async throws {
        let runner = SourceRunner(output: system)
        let token = CancellationToken()
        let state = try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned-a", selection: nil, runner: runner, cancellation: token)
        #expect(state.selection == "system")
        let call = try #require(await runner.calls.first)
        #expect(call.environmentID == "owned-a")
        #expect(call.cancellation === token)
        #expect(Array(call.argv.prefix(2)) == ["/usr/bin/python3", "-c"])
        let data = try #require(call.input?.data(using: .utf8))
        let input = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(input["operation"] as? String == "inspect")
        #expect(input["selection"] == nil)
        #expect((input["catalog"] as? [String: Any])?["suite"] as? String == "trixie")
    }

    @Test func explicitPresetSelectionIsDataAndRequiresVerifiedEffectivePaths() async throws {
        let runner = SourceRunner(output: tuna)
        let state = try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned-b", selection: "tuna", runner: runner, cancellation: nil)
        #expect(state.selection == "tuna")
        let call = try #require(await runner.calls.first)
        let input = try #require(JSONSerialization.jsonObject(with: Data(call.input!.utf8)) as? [String: Any])
        #expect(input["operation"] as? String == "select")
        #expect(input["selection"] as? String == "tuna")
        let bad = SourceRunner(output: tuna.replacingOccurrences(of: "/etc/apt/sources.list", with: "/etc/floe/package-sources/tuna.sources"))
        await #expect(throws: (any Error).self) {
            try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned-b", selection: "tuna", runner: bad, cancellation: nil)
        }
        let unverified = SourceRunner(output: tuna.replacingOccurrences(of: "\"verified\":true", with: "\"verified\":false"))
        await #expect(throws: (any Error).self) {
            try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned-b", selection: "tuna", runner: unverified, cancellation: nil)
        }
    }

    @Test func legacyOverrideCanBeReadButCannotMasqueradeAsNewSelection() async throws {
        let legacy = tuna.replacingOccurrences(of: "/etc/apt/sources.list.d/", with: "/etc/floe/package-sources/empty.d/")
            .replacingOccurrences(of: "/etc/apt/sources.list", with: "/etc/floe/package-sources/tuna.sources")
            .replacingOccurrences(of: "\"verified\":true", with: "\"verified\":true,\"legacyOverride\":true")
        let read = SourceRunner(output: legacy)
        #expect(try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned", selection: nil, runner: read, cancellation: nil).legacyOverride == true)
        let select = SourceRunner(output: legacy)
        await #expect(throws: (any Error).self) {
            try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned", selection: "tuna", runner: select, cancellation: nil)
        }
        #expect(LinuxPackageSourceCatalog.modelInstructions.contains("ordinary exec.shell"))
        #expect(!LinuxPackageSourceCatalog.modelInstructions.contains("unless the user explicitly selects"))
    }

    @Test func unknownChoiceAndCancellationCannotDispatchOrReturnSuccess() async throws {
        let runner = SourceRunner(output: tuna)
        await #expect(throws: (any Error).self) {
            try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned", selection: "unreviewed", runner: runner, cancellation: nil)
        }
        let token = CancellationToken(); token.cancel()
        await #expect(throws: (any Error).self) {
            try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned", selection: "tuna", runner: runner, cancellation: token)
        }
        #expect(await runner.calls.isEmpty)
        let late = SourceRunner(output: tuna, cancelOnRun: true)
        await #expect(throws: (any Error).self) {
            try await LinuxGuestPackageSourceConfiguration.run(environmentID: "owned", selection: "tuna", runner: late, cancellation: CancellationToken())
        }
    }

    @Test func stoppedGuestIsNotStartedBySourceInspection() async throws {
        let runner = SourceRunner(output: system, running: false)
        let service = LinuxGuestLanguagePackages(runner: runner)
        let root = FileManager.default.temporaryDirectory
        await #expect(throws: (any Error).self) {
            try await service.aptSource(environment: ToolEnvironment(id: "stopped", writableLayerURL: root, layerURLs: [root], variables: [:]), cancellation: nil)
        }
        #expect(await runner.calls.isEmpty)
    }
}
