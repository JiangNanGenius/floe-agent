import Crypto
import Foundation
import FloeCore

public struct SkillPackageValidator: Sendable {
    public var limits: SkillValidationLimits

    public init(limits: SkillValidationLimits = SkillValidationLimits()) {
        self.limits = limits
    }

    public func validate(packageAt rootURL: URL) throws -> ValidatedSkillPackage {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkillValidationError.unsafePath(root.path)
        }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rootValues.isSymbolicLink == true {
            throw SkillValidationError.symbolicLink(".")
        }

        let inventory = try inventory(root: root)
        guard inventory.contains(where: { $0.relativePath == "SKILL.md" }) else {
            throw SkillValidationError.missingRequiredFile("SKILL.md")
        }
        guard inventory.contains(where: { $0.relativePath == "floe.json" }) else {
            throw SkillValidationError.missingRequiredFile("floe.json")
        }

        let skillURL = root.appendingPathComponent("SKILL.md", isDirectory: false)
        let manifestURL = root.appendingPathComponent("floe.json", isDirectory: false)
        let skillData = try Data(floeContentsOf: skillURL, options: [.mappedIfSafe])
        let manifestData = try Data(floeContentsOf: manifestURL, options: [.mappedIfSafe])
        guard skillData.count <= limits.maximumSkillMarkdownBytes else {
            throw SkillValidationError.fileTooLarge(path: "SKILL.md", limit: limits.maximumSkillMarkdownBytes)
        }
        guard manifestData.count <= limits.maximumManifestBytes else {
            throw SkillValidationError.fileTooLarge(path: "floe.json", limit: limits.maximumManifestBytes)
        }

        let metadata = try parseSkillMarkdown(skillData)
        let manifest = try parseManifest(manifestData)
        guard metadata.name == manifest.id else {
            throw SkillValidationError.invalidManifest("id must match SKILL.md name")
        }
        let capabilities = try Set(manifest.capabilities.map { raw in
            guard let capability = SkillCapability(rawValue: raw) else {
                throw SkillValidationError.unknownCapability(raw)
            }
            return capability
        })
        let platforms = try Set(manifest.platforms.map { raw in
            guard let platform = SkillPlatform(rawValue: raw) else {
                throw SkillValidationError.unknownPlatform(raw)
            }
            return platform
        })

        try validatePythonPackages(manifest, capabilities: capabilities)
        try validateScripts(
            inventory,
            root: root,
            runtime: manifest.scriptRuntime,
            capabilities: capabilities
        )
        let digest = try canonicalDigest(root: root, files: inventory)
        return ValidatedSkillPackage(
            rootURL: root,
            metadata: metadata,
            manifest: manifest,
            declaredCapabilities: capabilities,
            supportedPlatforms: platforms,
            files: inventory,
            canonicalSHA256: digest
        )
    }

    private func inventory(root: URL) throws -> [SkillFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw SkillValidationError.unsafePath(root.path)
        }

        var files: [SkillFile] = []
        var normalizedPaths: Set<String> = []
        var totalBytes = 0
        var entryCount = 0
        let maximumEntryCount = limits.maximumFileCount > Int.max / 2
            ? Int.max
            : max(limits.maximumFileCount * 2, limits.maximumFileCount)
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        for case let url as URL in enumerator {
            entryCount += 1
            guard entryCount <= maximumEntryCount else {
                throw SkillValidationError.tooManyEntries(limit: maximumEntryCount)
            }
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(rootPrefix) else {
                throw SkillValidationError.unsafePath(url.path)
            }
            let relativePath = String(standardized.path.dropFirst(rootPrefix.count))
            try validate(relativePath: relativePath)
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw SkillValidationError.symbolicLink(relativePath)
            }
            if values.isDirectory == true {
                if relativePath == "SKILL.md" || relativePath == "floe.json" {
                    throw SkillValidationError.unsupportedFile(relativePath)
                }
                let forbiddenDirectoryExtensions: Set<String> = ["app", "framework", "bundle", "xcframework"]
                if forbiddenDirectoryExtensions.contains(url.pathExtension.lowercased()) {
                    throw SkillValidationError.unsupportedFile(relativePath)
                }
                continue
            }
            guard values.isRegularFile == true else {
                throw SkillValidationError.unsupportedFile(relativePath)
            }
            if ["references", "assets", "scripts", "agents"].contains(relativePath) {
                throw SkillValidationError.unsupportedFile(relativePath)
            }

            let collisionKey = relativePath.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedPaths.insert(collisionKey).inserted else {
                throw SkillValidationError.duplicatePath(relativePath)
            }
            let byteCount: Int
            if let fileSize = values.fileSize {
                byteCount = fileSize
            } else {
                byteCount = try Data(floeContentsOf: url, options: [.mappedIfSafe]).count
            }
            guard byteCount <= limits.maximumFileBytes else {
                throw SkillValidationError.fileTooLarge(path: relativePath, limit: limits.maximumFileBytes)
            }
            files.append(SkillFile(relativePath: relativePath, byteCount: byteCount))
            guard files.count <= limits.maximumFileCount else {
                throw SkillValidationError.tooManyFiles(limit: limits.maximumFileCount)
            }
            totalBytes += byteCount
            guard totalBytes <= limits.maximumPackageBytes else {
                throw SkillValidationError.packageTooLarge(limit: limits.maximumPackageBytes)
            }
            try rejectNativePayload(at: url, relativePath: relativePath)
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func validate(relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains(".."),
              relativePath.utf8.count <= 512
        else {
            throw SkillValidationError.unsafePath(relativePath)
        }
        let topLevel = relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let allowedRoots: Set<String> = ["SKILL.md", "floe.json", "references", "assets", "scripts", "agents"]
        guard allowedRoots.contains(topLevel),
              !(["SKILL.md", "floe.json"].contains(topLevel) && relativePath != topLevel)
        else {
            throw SkillValidationError.unsupportedFile(relativePath)
        }
    }

    private func rejectNativePayload(at url: URL, relativePath: String) throws {
        let forbiddenExtensions: Set<String> = ["dylib", "so", "wasm", "framework", "bundle", "a", "o"]
        if forbiddenExtensions.contains(url.pathExtension.lowercased()) {
            throw SkillValidationError.unsupportedFile(relativePath)
        }
        let prefix = try FileHandle(forReadingFrom: url)
        defer { try? prefix.close() }
        let bytes = try prefix.read(upToCount: 4) ?? Data()
        let nativeMagics: Set<[UInt8]> = [
            [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0x7F, 0x45, 0x4C, 0x46],
            [0x00, 0x61, 0x73, 0x6D]
        ]
        if nativeMagics.contains(Array(bytes)) {
            throw SkillValidationError.unsupportedFile(relativePath)
        }
    }

    private func parseSkillMarkdown(_ data: Data) throws -> SkillMetadata {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SkillValidationError.invalidFrontmatter("file must be UTF-8")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"),
              let end = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex)
        else {
            throw SkillValidationError.invalidFrontmatter("expected opening and closing --- delimiters")
        }
        let frontmatter = normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound]
        let body = String(normalized[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw SkillValidationError.invalidFrontmatter("instructions body must not be empty")
        }

        var values: [String: String] = [:]
        for lineSlice in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSlice)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            guard !line.contains("\t"), let colon = line.firstIndex(of: ":") else {
                throw SkillValidationError.invalidFrontmatter("frontmatter must use scalar key: value entries")
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !raw.isEmpty else {
                throw SkillValidationError.invalidFrontmatter("empty key or value")
            }
            values[key] = unquote(raw)
        }
        guard let name = values["name"] else {
            throw SkillValidationError.invalidFrontmatter("name is required")
        }
        guard let description = values["description"] else {
            throw SkillValidationError.invalidFrontmatter("description is required")
        }
        try validateIdentifier(name)
        guard description.count <= 1_024 else {
            throw SkillValidationError.invalidFrontmatter("description exceeds 1024 characters")
        }
        return SkillMetadata(name: name, description: description, instructions: body)
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func parseManifest(_ data: Data) throws -> SkillManifest {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw SkillValidationError.invalidManifest(error.localizedDescription) }
        guard let dictionary = object as? [String: Any] else {
            throw SkillValidationError.invalidManifest("top-level value must be an object")
        }
        let allowedKeys: Set<String> = [
            "schemaVersion", "id", "version", "capabilities", "tools",
            "platforms", "scriptRuntime", "pythonPackages"
        ]
        if let unknown = dictionary.keys.first(where: { !allowedKeys.contains($0) }) {
            throw SkillValidationError.invalidManifest("unknown field '\(unknown)'")
        }
        let manifest: SkillManifest
        do { manifest = try JSONDecoder().decode(SkillManifest.self, from: data) }
        catch { throw SkillValidationError.invalidManifest(error.localizedDescription) }
        guard manifest.schemaVersion == 1 else { throw SkillValidationError.unsupportedSchema(manifest.schemaVersion) }
        try validateIdentifier(manifest.id)
        guard SemanticVersion(manifest.version) != nil else { throw SkillValidationError.invalidVersion(manifest.version) }
        guard Set(manifest.capabilities).count == manifest.capabilities.count else {
            throw SkillValidationError.invalidManifest("capabilities must be unique")
        }
        guard Set(manifest.tools).count == manifest.tools.count else {
            throw SkillValidationError.invalidManifest("tools must be unique")
        }
        guard Set(manifest.pythonPackages.map { $0.spec.lowercased() }).count
                == manifest.pythonPackages.count else {
            throw SkillValidationError.invalidManifest("pythonPackages must be unique")
        }
        guard Set(manifest.platforms).count == manifest.platforms.count, !manifest.platforms.isEmpty else {
            throw SkillValidationError.invalidManifest("platforms must be non-empty and unique")
        }
        for tool in manifest.tools { try validateToolName(tool) }
        return manifest
    }

    private func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.count <= 64,
              value.first?.isLetter == true,
              value.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }),
              !value.hasSuffix("-"), !value.contains("--")
        else { throw SkillValidationError.invalidIdentifier(value) }
    }

    private func validateToolName(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.count <= 128, parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } })
        else { throw SkillValidationError.invalidManifest("invalid tool name '\(value)'") }
    }

    private func validateScripts(
        _ files: [SkillFile],
        root: URL,
        runtime: SkillScriptRuntime,
        capabilities: Set<SkillCapability>
    ) throws {
        let scripts = files.filter { $0.relativePath.hasPrefix("scripts/") }
        if scripts.isEmpty {
            guard runtime == .none else {
                throw SkillValidationError.incompatibleScriptRuntime("runtime declared but scripts/ is empty")
            }
            return
        }
        switch runtime {
        case .none:
            throw SkillValidationError.incompatibleScriptRuntime("scripts require an explicit runtime")
        case .javaScriptCore:
            guard capabilities.contains(.localJavaScript) else {
                throw SkillValidationError.incompatibleScriptRuntime("javascript.local capability is required")
            }
            for script in scripts where !["js", "mjs"].contains(URL(fileURLWithPath: script.relativePath).pathExtension.lowercased()) {
                throw SkillValidationError.unsupportedFile(script.relativePath)
            }
        case .localPython:
            guard capabilities.contains(.localPython) else {
                throw SkillValidationError.incompatibleScriptRuntime("python.local capability is required")
            }
            guard scripts.reduce(0, { $0 + $1.byteCount }) <= 192 * 1_024 else {
                throw SkillValidationError.incompatibleScriptRuntime(
                    "Bundled Python source exceeds the 192 KiB runtime prompt limit"
                )
            }
            for script in scripts {
                guard URL(fileURLWithPath: script.relativePath).pathExtension.lowercased() == "py" else {
                    throw SkillValidationError.unsupportedFile(script.relativePath)
                }
                let data = try Data(
                    floeContentsOf: root.appendingPathComponent(script.relativePath),
                    options: [.mappedIfSafe]
                )
                guard let source = String(data: data, encoding: .utf8) else {
                    throw SkillValidationError.incompatibleScriptRuntime(
                        "Python scripts must be UTF-8: \(script.relativePath)"
                    )
                }
                let normalized = source.lowercased()
                let forbidden = [
                    "import pip", "from pip", "ensurepip", "pip._internal",
                    "subprocess", "os.system(", "import ctypes", "from ctypes",
                    "import cffi", "from cffi"
                ]
                if let marker = forbidden.first(where: normalized.contains) {
                    throw SkillValidationError.incompatibleScriptRuntime(
                        "Python script \(script.relativePath) contains prohibited installer/native-execution marker '\(marker)'"
                    )
                }
            }
        case .remote:
            guard capabilities.contains(.remoteExecution) else {
                throw SkillValidationError.incompatibleScriptRuntime("execution.remote capability is required")
            }
            let allowed = Set(["js", "mjs", "py", "sh"])
            for script in scripts where !allowed.contains(URL(fileURLWithPath: script.relativePath).pathExtension.lowercased()) {
                throw SkillValidationError.unsupportedFile(script.relativePath)
            }
        }
    }

    private func validatePythonPackages(
        _ manifest: SkillManifest,
        capabilities: Set<SkillCapability>
    ) throws {
        let packages = manifest.pythonPackages
        guard packages.count <= 16 else {
            throw SkillValidationError.invalidManifest("pythonPackages accepts at most 16 entries")
        }
        guard !packages.isEmpty else { return }
        guard manifest.scriptRuntime == .localPython,
              capabilities.contains(.localPython),
              manifest.tools.contains("exec.localPython") else {
            throw SkillValidationError.incompatibleScriptRuntime(
                "pythonPackages require python.local runtime/capability and exec.localPython"
            )
        }
        let capabilityPattern = try NSRegularExpression(
            pattern: #"^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$"#
        )
        for package in packages {
            do { try ManagedPythonPackageSpecParser.validate(package.spec) }
            catch {
                throw SkillValidationError.invalidManifest("invalid Python package '\(package.spec)'")
            }
            guard package.spec.components(separatedBy: "==").count == 2 else {
                throw SkillValidationError.invalidManifest(
                    "Python package versions must be exact name==version values"
                )
            }
            let purpose = package.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !purpose.isEmpty, purpose.utf8.count <= 1_024 else {
                throw SkillValidationError.invalidManifest(
                    "Python package purpose must be 1-1024 bytes"
                )
            }
            guard !package.capabilities.isEmpty, package.capabilities.count <= 16,
                  Set(package.capabilities).count == package.capabilities.count else {
                throw SkillValidationError.invalidManifest(
                    "Python package capabilities must contain 1-16 unique values"
                )
            }
            for capability in package.capabilities {
                let range = NSRange(capability.startIndex..<capability.endIndex, in: capability)
                guard capabilityPattern.firstMatch(in: capability, range: range)?.range == range else {
                    throw SkillValidationError.invalidManifest(
                        "Python package capabilities must use dotted lowercase identifiers"
                    )
                }
            }
        }
    }

    private func canonicalDigest(root: URL, files: [SkillFile]) throws -> String {
        var hasher = SHA256()
        for file in files {
            let pathBytes = Data(file.relativePath.utf8)
            var length = UInt64(pathBytes.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: pathBytes)
            let data = try Data(floeContentsOf: root.appendingPathComponent(file.relativePath), options: [.mappedIfSafe])
            var dataLength = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &dataLength) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let core = string.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)[0]
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
