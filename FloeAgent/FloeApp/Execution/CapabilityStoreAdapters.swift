// FloeApp — Adapters that let the apt capability installer reuse the app's
// existing skill and font stores without FloeExecution importing app code.

import Foundation
import FloeExecution
import FloeSkills

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
            root: root.appendingPathComponent("wasm")) { url, destination in
                _ = try await HTTPRequestService().download(url: url, timeout: 60, maxBytes: 4 * 1024 * 1024, to: destination)
            }
    }
}
