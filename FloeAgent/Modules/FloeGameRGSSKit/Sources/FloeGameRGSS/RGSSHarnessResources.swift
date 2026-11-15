// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Read-only access to the reviewed harness/template resources for host
/// qualification and tests. These are MPL-2.0 Floe sources, not engine binaries.
public enum RGSSHarnessResources {
    public static func runtimeJavaScript() throws -> Data {
        try read("floe-runtime.js", subdirectory: "Resources")
    }

    public static func indexTemplate() throws -> Data {
        try read("index.template.html", subdirectory: "Resources")
    }

    public static func templateFile(_ relative: String, engine: GameEngineID) throws -> Data {
        let folder: String
        switch engine {
        case .rpgMakerXP: folder = "XP"
        case .rpgMakerVX: folder = "VX"
        case .rpgMakerVXAce: folder = "VXAce"
        default: throw RGSSRuntimeError.invalidEngine(engine.rawValue)
        }
        return try read(relative, subdirectory: "Resources/Templates/\(folder)")
    }

    static func read(_ name: String, subdirectory: String) throws -> Data {
        // SwiftPM's Darwin bundle resource root may already be Resources/.
        // Keep the copied folder layout and resolve through Bundle instead of
        // unconditionally appending another Resources component.
        let trimmed = subdirectory == "Resources" ? nil
            : String(subdirectory.dropFirst("Resources/".count))
        for directory in [Optional(subdirectory), trimmed] {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil,
                                               subdirectory: directory) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            return try Data(contentsOf: url)
        }
        throw RGSSRuntimeError.io("missing module resource \(subdirectory)/\(name)")
    }
}
