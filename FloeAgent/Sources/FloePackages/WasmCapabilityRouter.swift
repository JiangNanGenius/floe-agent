import FloeCore
import FloeTools

/// One signed WASM command capability surfaced through the apt-compatible
/// shell CLI. WASM commands are app-global immutable artifacts verified
/// against the signed capability catalog; they are never Debian packages and
/// must not be routed into a container layer or the dpkg database.
public struct WasmCapabilityInfo: Sendable, Equatable {
    /// Canonical catalog id, e.g. `floe/lua`.
    public var id: String
    /// Bare-shell command name, e.g. `floe-lua`.
    public var command: String
    public var version: String
    public var summary: String
    public var installed: Bool

    public init(id: String, command: String, version: String, summary: String, installed: Bool) {
        self.id = id
        self.command = command
        self.version = version
        self.summary = summary
        self.installed = installed
    }
}

/// Routes apt/pkg operands that name signed WASM capabilities to the store
/// that owns them. `resolve` returning nil means "not a WASM capability";
/// the caller then falls through to the Debian package engine unchanged.
public protocol WasmCapabilityRouter: Sendable {
    /// Every signed WASM capability known to the verified catalog.
    func capabilities() async -> [WasmCapabilityInfo]
    /// Exact match by catalog id or bare command name; nil falls through.
    func resolve(operand: String) async -> WasmCapabilityInfo?
    /// Installs the artifact; returns a short human-readable detail line.
    func install(id: String, cancellation: CancellationToken?) async throws -> String
    /// Removes the artifact; returns a short human-readable detail line.
    func remove(id: String) async throws -> String
}
