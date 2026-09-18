// FloeApp — Adapters that let the apt capability installer reuse the app's
// existing skill and font stores without FloeExecution importing app code.

import Foundation
import FloeCore
import FloeExecution
import FloePackages
import FloeSkills
import FloeTools

struct SkillCenterCapabilityAdapter: CapabilitySkillInstalling {
    let center: SkillsCenter

    func installCapabilitySkill(id: String) async throws {
        if BundledDomainSkills.all.first(where: { $0.id == id })?.exposed == false {
            _ = try await center.readSkills(id: id)
            return
        }
        await center.installOfficialSkill(id: id)
        _ = try await center.readSkills(id: id)
    }
}

struct FontStoreCapabilityAdapter: CapabilityFontInstalling {
    let store: DeviceFontStore

    func installCapabilityFont(downloadedFile: URL, sha256: String?) async throws {
        _ = try await store.importFont(from: downloadedFile)
    }
}

/// apt/pkg routing for signed WASM command capabilities. Capability facts
/// (id, command, version, install state) come only from the verified signed
/// catalog; installs go through CapabilityInstaller so the purpose policy,
/// ledger and busy/integrity checks keep a single owner. WASM commands are
/// app-global immutable resources: this route never writes into an
/// environment layer or the dpkg database, and removal is honest about that.
/// Cancellation is taken from the active shell invocation when the caller
/// does not supply one.
struct ShellWasmCapabilityRouter: WasmCapabilityRouter {
    func capabilities() async -> [WasmCapabilityInfo] {
        guard let store = FloeShellCommandRegistry.shared.wasm else { return [] }
        let installed = Set(await store.installedIDs())
        return store.catalog.packages.map {
            WasmCapabilityInfo(
                id: $0.id,
                command: $0.command,
                version: $0.version,
                summary: "Signed WASI command (verified catalog)",
                installed: installed.contains($0.id)
            )
        }
    }

    func resolve(operand: String) async -> WasmCapabilityInfo? {
        let normalized = operand.lowercased()
        return await capabilities().first {
            $0.id.lowercased() == normalized || $0.command.lowercased() == normalized
        }
    }

    func install(id: String, cancellation: CancellationToken?) async throws -> String {
        guard let installer = FloeShellCommandRegistry.shared.installer else {
            throw FloeError.invalidConfiguration("Signed capability installer is unavailable in this build")
        }
        let token = cancellation ?? FloeShellCommandRegistry.shared.context?.cancellation
        _ = try await installer.install(
            id: id,
            purpose: "apt install \(id) from the Floe shell",
            capabilities: [],
            cancellation: token
        )
        return "installed app-wide as an immutable signed WASM command resource; it is not an environment package"
    }

    func remove(id: String) async throws -> String {
        guard let installer = FloeShellCommandRegistry.shared.installer else {
            throw FloeError.invalidConfiguration("Signed capability installer is unavailable in this build")
        }
        _ = try await installer.remove(id: id)
        return "removed the app-wide WASM command resource; environment layers are unchanged"
    }
}

/// The key is pinned in executable code; a downloaded catalog cannot replace it.
enum BundledWasmCapabilities {
    static func load(root: URL) -> SignedWasmCapabilityStore? {
        guard let catalogURL = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Capabilities"),
              let signatureURL = Bundle.main.url(forResource: "catalog", withExtension: "sig", subdirectory: "Capabilities"),
              let data = try? Data(contentsOf: catalogURL),
              let encoded = try? String(contentsOf: signatureURL, encoding: .utf8),
              let signature = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = Data(base64Encoded: "qOMhhkiyMpw1tWRgbuNH79PjlL6nynbFGqBxeNX2Hco=") else { return nil }
        return try? SignedWasmCapabilityStore(catalogData: data, signature: signature, publicKey: key,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            root: root.appendingPathComponent("wasm"), boundedDownload: { url, destination, maxBytes, cancellation in
                // The signed entry supplies its reviewed ceiling; the transport
                // is additionally clamped to the catalog-wide maximum so a
                // malformed entry cannot request an unbounded transfer.
                let transportLimit = max(1, min(maxBytes, WasmPackageLimits.maximumDownloadBytes))
                _ = try await HTTPRequestService().download(url: url, timeout: 120, maxBytes: transportLimit, to: destination, cancellation: cancellation)
            })
    }
}
