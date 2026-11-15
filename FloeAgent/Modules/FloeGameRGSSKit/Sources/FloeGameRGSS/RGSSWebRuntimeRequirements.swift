// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum RGSSWebFeature: String, Codable, CaseIterable, Sendable {
    case webAssembly
    case sameOriginFetch
    case inlineScripts
    case wasmMIME
    case singleThread
}

/// Exact host requirements for the reviewed RGSS Web adapter. The current
/// root-owned GameWebRuntimePolicy does not enable WebAssembly for RGSS engine
/// IDs; this type reports the missing host feature rather than editing it.
public enum RGSSWebRuntimeRequirements {
    public static let stateLimitBytes = 1_048_576
    public static let maximumSaveBinaryBytes = 700_000

    public static let requiredContentSecurityPolicy =
        "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; " +
        "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; " +
        "font-src 'self' data:; connect-src 'self'; frame-src 'none'; worker-src 'none'; " +
        "object-src 'none'; base-uri 'none'; form-action 'none'"

    public static let requiredFeatures: [RGSSWebFeature] = [
        .webAssembly, .sameOriginFetch, .inlineScripts, .wasmMIME, .singleThread
    ]

    public static let mimeTypeRequirements: [String: String] = [
        "html": "text/html",
        "js": "application/javascript",
        "wasm": "application/wasm",
        "json": "application/json",
        "png": "image/png",
        "ogg": "audio/ogg",
        "wav": "audio/wav",
        "mp3": "audio/mpeg",
        "rxdata": "application/octet-stream",
        "rvdata": "application/octet-stream",
        "rvdata2": "application/octet-stream"
    ]

    public static func missingFeatures(in policy: GameWebRuntimePolicy) -> [RGSSWebFeature] {
        var missing: [RGSSWebFeature] = []
        if !policy.allowsWebAssembly { missing.append(.webAssembly) }
        return missing
    }

    public static func validate(policy: GameWebRuntimePolicy) throws {
        guard policy.allowsWebAssembly else {
            throw RGSSRuntimeError.hostPolicyRequiresWebAssembly
        }
    }

    public static let hostNotes = [
        "The .wasm response must use application/wasm; GameWebArtifactPackage already does this.",
        "CSP must include 'wasm-unsafe-eval'; connect-src 'self' is required for on-demand package fetches.",
        "No COOP/COEP, SharedArrayBuffer, worker, service worker or cross-origin network is required.",
        "The harness does not use IndexedDB, localStorage, eval or a native bridge.",
        "Current GameWebRuntimePolicy(engine: .rpgMakerXP) has allowsWebAssembly == false; root must add RGSS IDs before App WebKit acceptance.",
        "The host state limit is 1 MiB for non-listed engines; this adapter caps save JSON to that limit."
    ]
}
