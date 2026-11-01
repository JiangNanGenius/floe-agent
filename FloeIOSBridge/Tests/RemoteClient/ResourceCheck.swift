import Foundation
import CryptoKit

import BridgeCore
import BridgeHost

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count >= 3 else {
    fail("usage: resource-check <test.bundle> <empty.bundle>")
}
let bundlePath = CommandLine.arguments[1]
guard let bundle = Bundle(path: bundlePath) else {
    fail("could not load test bundle at \(bundlePath)")
}
guard let emptyBundle = Bundle(path: CommandLine.arguments[2]) else {
    fail("could not load empty test bundle")
}
let resources = BridgeRemoteResources(bundle: bundle)
guard let page = resources.remotePageHTML() else {
    fail("BridgeRemoteResources did not load REMOTE.html from the folder reference")
}
guard page.contains("Floe Bridge Remote") else {
    fail("loaded page is not the Floe remote page")
}
guard page.utf8.count <= BridgeRemoteResources.maximumPageBytes else {
    fail("loaded page exceeds the bounded size")
}
guard page.contains("Content-Security-Policy") && page.contains("sha256-") else {
    fail("loaded page lost its CSP")
}
guard let policy = resources.remotePageHeaders["Content-Security-Policy"],
      policy.contains("frame-ancestors 'none'"),
      !policy.contains("'unsafe-inline'"), !policy.contains("'unsafe-eval'") else {
    fail("remote HTTP CSP must deny framing and require exact inline hashes")
}
for tag in ["style", "script"] {
    let regex = try NSRegularExpression(pattern: "<" + tag + "\\b[^>]*>([\\s\\S]*?)</" + tag + "\\s*>")
    let range = NSRange(page.startIndex..., in: page)
    let blocks = regex.matches(in: page, range: range)
    guard !blocks.isEmpty else { fail("remote page has no " + tag + " block") }
    for block in blocks {
        guard let contentRange = Range(block.range(at: 1), in: page) else { fail("invalid inline range") }
        let digest = Data(SHA256.hash(data: Data(page[contentRange].utf8))).base64EncodedString()
        guard policy.contains("'sha256-" + digest + "'") else {
            fail("HTTP CSP does not authorize the actual bundled " + tag + " bytes")
        }
    }
}
print("PASS exact HTTP CSP hashes and frame protection")
guard let skill = resources.skillMarkdown(), skill.contains("synthetic skill") else {
    fail("skillMarkdown() did not delegate to BridgeRPCBundleResources")
}
print("PASS folder-reference REMOTE.html (\(page.utf8.count) bytes)")
print("PASS delegated SKILL.md (\(skill.utf8.count) bytes)")

let empty = BridgeRemoteResources(bundle: emptyBundle, skillSource: BridgeRPCEmptyResources())
guard empty.remotePageHTML() == nil else {
    fail("missing REMOTE.html must report nil, not invented copy")
}
print("PASS missing resource returns nil")
