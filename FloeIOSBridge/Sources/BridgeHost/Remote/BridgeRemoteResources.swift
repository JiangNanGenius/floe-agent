import Foundation

import BridgeCore

/// Host resource adapter for the self-contained browser remote page.
///
/// The page ships in `Resources/BridgeRemote/REMOTE.html` and is served by the
/// existing `GET /remote` route. This adapter only supplies bytes: it does not
/// add HTTP routes, change RPC/auth, or make any engine call. The host should
/// inject it when constructing `BridgeRPCHostService`:
///
///     BridgeRPCHostService(resources: BridgeRemoteResources())
///
/// `skillMarkdown()` deliberately delegates to the existing bundle provider so
/// the remote package cannot silently replace the canonical SKILL.md. The
/// project must bundle the `BridgeRemote` folder as a folder reference (or add
/// its `REMOTE.html` as a resource named `REMOTE.html`) for lookup to succeed.
public struct BridgeRemoteResources: BridgeRPCResourceProvider {
    public static let directoryName = "BridgeRemote"
    public static let fileName = "REMOTE"
    public static let fileExtension = "html"
    /// The page is one file; 2 MiB is the same bounded read budget used by the
    /// existing SKILL/REMOTE bundle provider.
    public static let maximumPageBytes = 2 * 1_024 * 1_024

    private let bundle: Bundle
    private let skillSource: any BridgeRPCResourceProvider

    /// Uses the app bundle and the existing `BridgeRPCBundleResources` for
    /// SKILL.md. This is the production convenience initializer.
    public init(bundle: Bundle = .main) {
        self.init(bundle: bundle, skillSource: BridgeRPCBundleResources(bundle: bundle))
    }

    /// Explicit injection for qualification hosts and tests. `skillSource` is
    /// read-only; `remotePageHTML()` always comes from this adapter.
    public init(bundle: Bundle, skillSource: any BridgeRPCResourceProvider) {
        self.bundle = bundle
        self.skillSource = skillSource
    }

    public func skillMarkdown() -> String? {
        skillSource.skillMarkdown()
    }

    public var remotePageHeaders: [String: String] {
        ["Content-Security-Policy": "default-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-ancestors 'none'; frame-src 'none'; worker-src 'none'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; style-src 'sha256-P0TKVgiYyE3AVCUPUlKMvkH2PmMhbntBbl15MKh1YbA='; script-src 'sha256-00DAUpsQFtxWwd2wyN3BOeQcnTwpghpeMLAxdYVaSQQ=' 'sha256-KZhm5JzqZiyymjxNKRhHhaNht3Z26LVqHG2oMsTl0xw='"]
    }

    public func remotePageHTML() -> String? {
        let candidates: [URL?] = [
            bundle.url(forResource: Self.fileName,
                       withExtension: Self.fileExtension,
                       subdirectory: Self.directoryName),
            bundle.url(forResource: Self.fileName,
                       withExtension: Self.fileExtension,
                       subdirectory: "Resources/" + Self.directoryName),
            bundle.url(forResource: Self.fileName, withExtension: Self.fileExtension),
        ]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !data.isEmpty,
                  data.count <= Self.maximumPageBytes,
                  let page = String(data: data, encoding: .utf8) else {
                continue
            }
            let head = page.drop { $0.isWhitespace }.prefix(64).lowercased()
            guard head.hasPrefix("<!doctype html") || head.hasPrefix("<html") else {
                continue
            }
            return page
        }
        return nil
    }
}
