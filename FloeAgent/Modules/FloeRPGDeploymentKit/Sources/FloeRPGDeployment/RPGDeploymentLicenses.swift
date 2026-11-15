// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Full original notices accompany the compiled module. The host can attach
/// them to its existing acknowledgements and source/export packaging flow.
/// These terms apply to this SDK, not to user-imported games or their assets.
public enum RPGDeploymentLicenses {
    public static func documents() throws -> [String: String] {
        var result: [String: String] = [:]
        for name in ["MPL-2.0", "RPGMakerDecrypter-MIT"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else { throw CocoaError(.fileNoSuchFile) }
            result[name] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }
}
