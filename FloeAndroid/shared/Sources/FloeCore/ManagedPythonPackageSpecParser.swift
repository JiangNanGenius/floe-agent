import Foundation

/// Parses the declarative pip command accepted by `exec.localPython`.
/// Floe never forwards flags, URLs, paths, shell syntax, or VCS references to
/// pip. The resulting package specs still pass through the package-review
/// model and the quarantined pure-Python wheel installer.
public enum ManagedPythonPackageSpecParser {
    public static func parse(command: String?) throws -> [String] {
        guard let command else { return [] }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.utf8.count <= 1_024 else {
            throw FloeError.validationFailed("pipCommand exceeds 1024 bytes")
        }
        let tokens = trimmed.split(whereSeparator: \Character.isWhitespace).map(String.init)
        let packageStart: Int
        if tokens.count >= 3,
           ["pip", "pip3"].contains(tokens[0].lowercased()),
           tokens[1].lowercased() == "install" {
            packageStart = 2
        } else if tokens.count >= 5,
                  ["python", "python3"].contains(tokens[0].lowercased()),
                  tokens[1] == "-m",
                  tokens[2].lowercased() == "pip",
                  tokens[3].lowercased() == "install" {
            packageStart = 4
        } else {
            throw FloeError.validationFailed(
                "pipCommand must be `pip install package...` or `python -m pip install package...`"
            )
        }
        let packages = Array(tokens.dropFirst(packageStart))
        guard !packages.isEmpty, packages.count <= 16 else {
            throw FloeError.validationFailed("pipCommand must request 1-16 packages")
        }
        try packages.forEach(validate)
        return packages
    }

    public static func validate(_ package: String) throws {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]*(?:\[[A-Za-z0-9_,.-]+\])?(?:==[A-Za-z0-9][A-Za-z0-9.*+!_-]*)?$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(package.startIndex..<package.endIndex, in: package)
        guard expression.firstMatch(in: package, range: range)?.range == range else {
            throw FloeError.validationFailed(
                "Package specs must be a PyPI name or exact name==version; flags, URLs, paths, ranges, shell syntax, and VCS sources are rejected"
            )
        }
    }
}

public extension ManagedPythonPackageSpecParser {
    enum ShellOperation: Sendable {
        case install([String]), remove(String), inspect(String, [String])
    }
    static func parseShell(arguments: [String]) throws -> ShellOperation {
        guard let command = arguments.first else { return .inspect("help", []) }
        var values = Array(arguments.dropFirst())
        switch command {
        case "install":
            // The complete generation is already replaced atomically. These
            // flags do not grant a different target or permit source builds.
            values.removeAll { ["-U", "--upgrade", "--no-input", "--disable-pip-version-check"].contains($0) }
            guard !values.isEmpty, values.count <= 16 else { throw FloeError.validationFailed(FloeL10n.l("core.managed_python_package_spec_parser.pip_install_requires_1_16_package")) }
            try values.forEach(validate)
            return .install(values)
        case "uninstall", "remove":
            values.removeAll { ["-y", "--yes", "--no-input"].contains($0) }
            guard values.count == 1, values[0].range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
                throw FloeError.validationFailed(FloeL10n.l("core.managed_python_package_spec_parser.pip_uninstall_takes_one_package_name"))
            }
            return .remove(values[0])
        case "--version", "-V", "help", "--help", "-h", "freeze", "check":
            guard values.isEmpty else { throw FloeError.validationFailed(FloeL10n.l("core.managed_python_package_spec_parser.this_pip_command_takes_no_extra")) }
            return .inspect(command, [])
        case "list":
            guard values.isEmpty || values == ["--format=json"] else { throw FloeError.validationFailed(FloeL10n.l("core.managed_python_package_spec_parser.pip_list_supports_only_format_json")) }
            return .inspect(command, values)
        case "show":
            guard !values.isEmpty, values.count <= 16 else { throw FloeError.validationFailed(FloeL10n.l("core.managed_python_package_spec_parser.specify_1_16_package_names")) }
            for value in values {
                guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { throw FloeError.validationFailed(FloeL10n.l("core.managed_python_package_spec_parser.pip_show_accepts_only_a_package")) }
            }
            return .inspect(command, values)
        default: throw FloeError.validationFailed(FloeL10n.l("core.managed_python_package_spec_parser.supported_commands"))
        }
    }
}
