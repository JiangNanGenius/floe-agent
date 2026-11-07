// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public enum LaTeXWorkerResources {
    public static func verifiedSource() throws -> Data {
        guard let manifest=Bundle.module.url(forResource:"worker-manifest",withExtension:"json"),let source=Bundle.module.url(forResource:"latex_worker",withExtension:"py") else {throw CocoaError(.fileNoSuchFile)}
        struct Manifest:Decodable {var sha256:String;var byteCount:Int}
        let expected=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:manifest)),data=try Data(contentsOf:source)
        guard data.count==expected.byteCount,SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==expected.sha256 else {throw CocoaError(.fileReadCorruptFile)}
        return data
    }
    public static var protocolVersion:Int {1}
}
