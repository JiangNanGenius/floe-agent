// FloeExecution — capability-family migration guidance.
//
// The retired mixed `apt` shim and historical package routes still answer
// read-only queries and migration guidance for old conversations. This small
// helper keeps every family pointing at the entry that actually owns it; it is
// shared by the shim and its focused test after the retired Python package
// tool implementation was deleted.

import FloeTools

public enum PackageFamilyGuidance {
    /// Points each family at its own entry instead of letting one tool stand
    /// in for every kind of capability.
    public static func message(for entry: CapabilityCatalog.Entry) -> String {
        switch entry.kind {
        case .pythonPackage:
            return "\(entry.id) is a Python package; use python3 -m pip through exec.shell in the Linux environment"
        case .wasmCommand:
            return "\(entry.id) is a signed WASI command; use Settings to manage signed capabilities"
        case .skill:
            return "\(entry.id) is a workflow skill; use skill.manage"
        case .font:
            return "\(entry.id) is a font; use the font tools"
        case .model:
            return "\(entry.id) is a local model; use the model manager"
        case .debData:
            return "\(entry.id) is a data-only .deb payload; extract it with dpkg-deb -x or install it inside a Linux environment"
        case .shellTool:
            return "\(entry.id) is a reviewed shell tool route, not an installable Python package"
        }
    }
}
