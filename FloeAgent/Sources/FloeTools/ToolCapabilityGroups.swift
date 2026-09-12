import Foundation

/// Capability roles, deliberately independent of historical wire-name prefixes.
public enum ToolCapabilityGroups {
    public static func group(_ name: String) -> String {
        if ["ssh.execute", "ssh.taskStatus", "ssh.cancelTask"].contains(name) { return "executor" }
        if ["ssh.shellOpen", "ssh.shellExchange", "ssh.shellClose"].contains(name)
            || name.hasPrefix("remote.connection.") || name.hasPrefix("bluetooth.serial.") { return "terminal" }
        if name.hasPrefix("ssh.") { return "hosts" }
        if name == "exec.shell" || name.hasPrefix("shell.") { return "shell" }
        if name == "apt" { return "packages" }
        if name == "exec.localPython" { return "python" }
        if name.hasPrefix("document.pdf.") { return "pdf" }
        if name.hasPrefix("document.") || name.hasPrefix("font.") { return "office" }
        if name == "network.http" { return "http" }
        return String(name.split(separator: ".").first ?? "other")
    }
}
