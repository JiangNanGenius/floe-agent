import Foundation

/// Policy for tool capability offered to on-device (MLX) models.
///
/// Small on-device models cannot reliably discover tools through a
/// `tools.list` round-trip: the first run in a fresh conversation may
/// answer prose-only and falsely report an action as finished. The names
/// below are therefore offered as a stable, budgeted base set on every
/// tool-capable local run. The set is budgeted at prompt construction —
/// schemas that do not fit the per-window token/character allowance are
/// dropped in a deterministic order — and cloud providers keep their
/// existing dynamic discovery behaviour.
public enum LocalModelToolPolicy {
    /// Admission order for the base file tools: the create/read/write chain
    /// first, so a small context window that can only afford a few schemas
    /// still gets the tools the observed failure needed. Deterministic, so
    /// the same window always produces the same offered set.
    public static let baseFileToolAdmissionOrder: [String] = [
        "workspace.readFile",
        "workspace.createFile",
        "workspace.writeFile",
        "workspace.listDirectory",
        "workspace.searchFiles",
        "workspace.applyPatch",
        "workspace.inspectFileMetadata"
    ]

    /// Complete file-tool schemas always offered to local models without a
    /// `tools.list` call.
    public static let baseFileToolNames: Set<String> = Set(baseFileToolAdmissionOrder)

    /// Explicit capability that prepares (downloads, verifies and installs)
    /// the Linux environment image. Execution that needs Linux invokes this
    /// first, waits for the installation to settle, then resumes the
    /// original command.
    public static let prepareLinuxToolName = "environment.prepareLinux"

    /// All names the runtime must keep loaded on a local run even without a
    /// discovery call.
    public static let alwaysLoadedToolNames: Set<String> =
        baseFileToolNames.union([prepareLinuxToolName])

    /// Admission order for every always-loaded schema: the file chain first,
    /// then the explicit Linux preparation capability.
    public static let admissionOrder: [String] =
        baseFileToolAdmissionOrder + [prepareLinuxToolName]
}
