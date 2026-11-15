// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import FloeCore

enum LocalLinuxAccelerationInstaller {
    /// Pass the signed app's offline package over the selected guest runner's stdin.
    static func command() throws -> (argv: [String], standardInput: String) {
        guard let package = Bundle.main.url(forResource: "floe-acceleration-tools", withExtension: "deb"),
              let installer = Bundle.main.url(forResource: "floe-install-acceleration", withExtension: "sh") else {
            throw FloeError.validationFailed(IDELanguageRunText.t("无法读取加速工具安装包。", "Could not load the acceleration package."))
        }
        let bytes = try Data(contentsOf: package, options: .mappedIfSafe)
        let script = try String(contentsOf: installer, encoding: .utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (["/bin/sh", "-c", script, "floe-install-acceleration", digest], bytes.base64EncodedString())
    }
}
