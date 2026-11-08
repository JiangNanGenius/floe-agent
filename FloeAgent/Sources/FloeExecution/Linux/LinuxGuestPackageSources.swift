// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools

public struct LinuxGuestAptSourceState: Decodable, Sendable, Equatable {
    public let selection: String
    public let sourceList: String
    public let sourceParts: String
    public let uri: String?
    public let verified: Bool
}

/// Fixed configuration transaction through the existing environment-owned
/// Linux runner. No apt update/install, arbitrary repo, host interpreter or
/// automatic startup is part of this operation.
enum LinuxGuestPackageSourceConfiguration {
    private struct Request: Encodable {
        let operation: String
        let selection: String?
        let catalog: LinuxPackageSourceCatalog
    }
    private struct Failure: Decodable { let error: String }
    private static let script: Result<String, Error> = Result {
        guard let scriptURL = Bundle.module.url(forResource: "linux_package_sources", withExtension: "py")
        else { throw LinuxPackageSourceCatalog.invalidCatalog() }
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        guard script.utf8.count <= 32 * 1024 else { throw LinuxPackageSourceCatalog.invalidCatalog() }
        return script
    }

    static func run(
        environmentID: String, selection: String?, runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestAptSourceState {
        let catalog = try LinuxPackageSourceCatalog.bundled()
        if let selection, selection != "system", !catalog.apt.contains(where: { $0.id == selection }) {
            throw failure("unknownPreset")
        }
        try cancellation?.throwIfCancelled()
        let sourceScript = try script.get()
        // Encode the reviewed native catalog as data, never interpolate a
        // URI, model argument, path or preset name into executable code.
        let request = try JSONEncoder().encode(Request(
            operation: selection == nil ? "inspect" : "select", selection: selection, catalog: catalog))
        let output = try await runner.run(
            environmentID: environmentID,
            argv: ["/usr/bin/python3", "-c", sourceScript],
            workingDirectory: nil,
            standardInput: String(decoding: request, as: UTF8.self),
            timeout: 15, maxOutputBytes: 16 * 1024, cancellation: cancellation)
        try cancellation?.throwIfCancelled()
        let bytes = Data(output.stdout.utf8)
        guard bytes.count <= 16 * 1024 else { throw failure("verificationFailed") }
        if output.exitCode != 0 {
            let code = (try? JSONDecoder().decode(Failure.self, from: bytes))?.error ?? "configurationUnavailable"
            if code == "cancelled" { throw CancellationError() }
            throw failure(code)
        }
        guard let state = try? JSONDecoder().decode(LinuxGuestAptSourceState.self, from: bytes),
              state.verified, ["system", "official", "tuna"].contains(state.selection),
              selection == nil || state.selection == selection else {
            throw failure("verificationFailed")
        }
        if state.selection != "system" {
            guard let preset = catalog.apt.first(where: { $0.id == state.selection }),
                  state.uri == preset.uri,
                  state.sourceList == "/etc/floe/package-sources/\(preset.id).sources",
                  state.sourceParts.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "etc/floe/package-sources/empty.d"
            else { throw failure("verificationFailed") }
        }
        return state
    }

    private static func failure(_ code: String) -> FloeError {
        let message: String
        switch code {
        case "missingKeyring":
            message = FloeL10n.isChinese ? "此环境缺少 Debian 签名密钥。请先修复系统软件源。" : "The Debian signing keyring is missing. Repair the system package sources first."
        case "configurationChanged", "customOverride", "unsafePath":
            message = FloeL10n.isChinese ? "检测到手动修改的软件源配置。请先检查当前配置。" : "The source configuration has manual changes. Check the current configuration first."
        case "verificationFailed":
            message = FloeL10n.isChinese ? "未能确认软件源已生效，原配置已保留。" : "The source could not be verified. The previous configuration was kept."
        default:
            message = FloeL10n.isChinese ? "无法读取或保存软件源。请确认 Linux 环境正在运行后重试。" : "The package source could not be read or saved. Check that Linux is running, then retry."
        }
        return .validationFailed(message)
    }
}
