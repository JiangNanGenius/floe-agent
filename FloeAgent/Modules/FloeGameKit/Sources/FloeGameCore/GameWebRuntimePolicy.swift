// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Fixed browser capabilities for reviewed engine adapters. A project manifest
/// cannot request native access, arbitrary network access or weaker CSP rules.
public struct GameWebRuntimePolicy: Equatable, Sendable {
    public let allowsWebAssembly: Bool
    public let allowsJavaScriptEvaluation: Bool
    public let allowsWorkers: Bool
    public let maximumStateBytes: Int

    public init(engine: GameEngineID) {
        allowsWebAssembly = [.godot, .unity, .wasm4, .tic80, .love, .renpy].contains(engine)
        // These source interpreters implement their language/macros using JS
        // functions. WASM-4 2.7.1 also uses new Function for its documented
        // ScriptProcessor fallback when AudioWorklet cannot load. GDevelop's
        // official PIXI runtime compiles WebGL uniform synchronizers the same
        // way. RPG Maker evaluates event scripts/damage formulas; TyranoScript
        // evaluates KAG expressions and script tags; the reviewed
        // LÖVE Emscripten runtime exposes its run-script callback. These browser
        // features provide no native execution/file bridge.
        allowsJavaScriptEvaluation = [.microStudio, .twine, .renpy, .wasm4, .gdevelop,
                                      .rpgMakerMV, .rpgMakerMZ, .love, .tyranoScript].contains(engine)
        // Web single-thread builds remain the default. No COOP/SAB/secure-origin
        // support is claimed by enabling a worker directive.
        allowsWorkers = [.godot, .unity, .tic80, .love, .renpy].contains(engine)
        maximumStateBytes = [.wasm4, .tic80, .renpy, .love].contains(engine) ? 4_194_304 : 1_048_576
    }

    public var contentSecurityPolicy: String {
        var scripts = "'self' 'unsafe-inline'"
        if allowsWebAssembly { scripts += " 'wasm-unsafe-eval'" }
        if allowsJavaScriptEvaluation { scripts += " 'unsafe-eval'" }
        return "default-src 'none'; script-src \(scripts); style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self' data:; connect-src 'self'; frame-src 'none'; worker-src \(allowsWorkers ? "'self' blob:" : "'none'"); object-src 'none'; base-uri 'none'; form-action 'none'"
    }
}
