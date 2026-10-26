// FloeSkillsTests — strict official Skill dependency declaration v1.
//
// Locks the frozen author contract the app-side preparation center consumes:
//   * exact top/profile/requirement key sets per tagged kind; unknown fields
//     (url/command/env/permission/approval/digest) fail closed;
//   * exact single-version pins only — ranges, wildcards and floating aliases
//     ("latest", "stable") can never pass, including for the font kind, which
//     carries an exact Debian version like apt (v1 has no unversioned
//     exception);
//   * schemaVersion compatibility: 1 decodes, a newer unknown value fails
//     compatibility (never guessed), older/invalid values fail shape;
//   * lock paths are package-local under references/ with no traversal, and
//     cross-validation requires the declared lock/descriptor bytes to exist
//     inside the signed package (the contentDigest already covers them);
//   * the runtimeComponent kind may only point at the frozen
//     references/engine-dependency.json and inherits the existing strict
//     descriptor decode + allowlist unchanged (never widened here);
//   * the minimumAppVersion candidate (1.7.60) gates hub entries on the
//     publisher side; the native helper is consistent with SignedContentVersion.

import Foundation
import Testing
@testable import FloeSkills

// MARK: - Fixtures

private func repoFile(_ relative: String) throws -> Data {
    // Tests/FloeSkillsTests/<file> -> repo root is three levels above this file.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FloeSkillsTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // FloeAgent
        .deletingLastPathComponent()   // repo root
    let url = root.appendingPathComponent(relative)
    return try #require(try? Data(contentsOf: url), "required contract fixture missing: \(relative)")
}

/// Builds one coherent declaration dictionary; tests perturb one field.
private func makeDeclaration(
    schemaVersion: Any = 1,
    requirements: [[String: Any]] = [
        [
            "kind": "pip", "name": "pypdf", "version": "5.4.0",
            "purpose": "Read and merge PDF pages.", "required": true
        ]
    ],
    profileID: Any = "linux-guest",
    target: Any = ["os": "linux", "architectures": ["any"]],
    extraTop: [String: Any] = [:]
) -> [String: Any] {
    var object: [String: Any] = [
        "schemaVersion": schemaVersion,
        "profiles": [
            ["id": profileID, "target": target, "requirements": requirements]
        ]
    ]
    for (key, value) in extraTop { object[key] = value }
    return object
}

private func encoded(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func expectDecodeError(
    _ object: [String: Any],
    _ predicate: (SkillDependencyError) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    do {
        _ = try SkillDependency.decode(encoded(object))
        Issue.record("expected a strict failure", at: sourceLocation)
    } catch let error as SkillDependencyError {
        #expect(predicate(error), "unexpected failure \(error)", at: sourceLocation)
    }
}

/// A byte-coherent frozen runtime-component descriptor (published content).
private func engineDescriptorBytes() throws -> Data {
    try encoded([
        "schemaVersion": 1,
        "componentID": "impeccable-engine",
        "componentVersion": "0.1.17+floe.1.0.0",
        "minimumAppVersion": "1.7.59",
        "target": [
            "os": "linux", "arch": "riscv64",
            "triple": "riscv64gc-unknown-linux-musl",
            "format": "elf64-little-riscv-exec-static"
        ],
        "artifact": [
            "path": "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable",
            "size": 5579704,
            "sha256": String(repeating: "a", count: 64)
        ],
        "captureContract": ["version": 1, "sha256": String(repeating: "b", count: 64)]
    ])
}

@Suite("FloeSkills.SkillDependency")
struct SkillDependencyTests {
    // MARK: - Frozen positives (including the shipped docs examples)

    @Test(arguments: [
        "docs/skills/examples/dependencies.minimal.json",
        "docs/skills/examples/dependencies.purepip.json",
        "docs/skills/examples/dependencies.debian.json",
        "docs/skills/examples/dependencies.npm.json",
        "docs/skills/examples/dependencies.cjk.json"
    ])
    func publishedExamplesDecode(path: String) throws {
        let declaration = try SkillDependency.decode(repoFile(path))
        #expect(declaration.schemaVersion == 1)
        #expect(!declaration.profiles.isEmpty)
        for profile in declaration.profiles {
            #expect(profile.os == "linux")
            #expect(!profile.requirements.isEmpty)
        }
    }

    @Test func positiveKindsDecodeExactly() throws {
        let declaration = try SkillDependency.decode(encoded(makeDeclaration(requirements: [
            ["kind": "pip", "name": "sympy", "version": "1.14.0", "purpose": "Symbolic math.",
             "required": true, "lockfile": "references/requirements.lock.txt"],
            ["kind": "apt", "name": "python3-scipy", "version": "1.15.3-1", "purpose": "Numeric.", "required": true],
            ["kind": "npm", "name": "@scope/validator", "version": "1.2.0", "purpose": "Validate.", "required": false],
            ["kind": "font", "name": "fonts-noto-cjk", "version": "1:20240730+repack1-1", "purpose": "CJK glyphs.", "required": false],
            ["kind": "runtimeComponent", "componentDescriptorPath": "references/engine-dependency.json",
             "purpose": "Engine.", "required": true]
        ])))
        let requirements = declaration.profiles[0].requirements
        #expect(requirements.count == 5)
        #expect(requirements[0].pipSpec == "sympy==1.14.0")
        #expect(requirements[0].lockfile == "references/requirements.lock.txt")
        #expect(requirements[1].aptPin == "python3-scipy=1.15.3-1")
        #expect(requirements[2].npmSpec == "@scope/validator@1.2.0")
        // The font kind pins an exact Debian version like apt (no v1 exception).
        #expect(requirements[3].kind == .font)
        #expect(requirements[3].aptPin == "fonts-noto-cjk=1:20240730+repack1-1")
        #expect(requirements[4].componentDescriptorPath == "references/engine-dependency.json")
        #expect(requirements[4].name == "")
    }

    @Test func pinDigestHelperAndConstants() throws {
        #expect(SkillDependency.frozenSchemaVersion == 1)
        #expect(SkillDependency.packagePath == "references/dependencies.json")
        #expect(SkillDependency.componentDescriptorPath == "references/engine-dependency.json")
        // Old-client gate candidate: first capable release; the native side is
        // honest about capability for current + future versions.
        #expect(SkillDependency.minimumCapableAppVersion == "1.7.60")
        #expect(SkillDependency.isProvisioningCapable(appVersion: "1.7.60"))
        #expect(SkillDependency.isProvisioningCapable(appVersion: "1.7.61"))
        #expect(!SkillDependency.isProvisioningCapable(appVersion: "1.7.59"))
        #expect(!SkillDependency.isProvisioningCapable(appVersion: "1.8"))
        #expect(!SkillDependency.isProvisioningCapable(appVersion: "garbage"))
    }

    // MARK: - SchemaVersion compatibility (the frozen distinction #2)

    @Test func newerSchemaFailsCompatibilityNotGuessing() throws {
        try expectDecodeError(makeDeclaration(schemaVersion: 2)) { error in
            if case .unsupportedSchemaVersion(2) = error { return true }
            return false
        }
        try expectDecodeError(makeDeclaration(schemaVersion: 99)) { error in
            if case .unsupportedSchemaVersion = error { return true }
            return false
        }
        try expectDecodeError(makeDeclaration(schemaVersion: 0)) { error in
            error == .invalidField("schemaVersion")
        }
        try expectDecodeError(makeDeclaration(schemaVersion: true)) { _ in true }
        try expectDecodeError(makeDeclaration(schemaVersion: "1")) { _ in true }
    }

    // MARK: - Exact-key discipline (no URL/command/env/approval can exist)

    @Test func unknownFieldsFailClosed() throws {
        for smuggled in ["url", "command", "script", "env", "permission", "approval", "sha256", "index", "registry"] {
            var requirement: [String: Any] = [
                "kind": "pip", "name": "pypdf", "version": "5.4.0",
                "purpose": "OK.", "required": true
            ]
            requirement[smuggled] = "anything"
            try expectDecodeError(makeDeclaration(requirements: [requirement])) { error in
                if case .unknownFields(let fields) = error { return fields == [smuggled] }
                return false
            }
        }
        try expectDecodeError(makeDeclaration(extraTop: ["hooks": "x"])) { error in
            if case .unknownFields(let fields) = error { return fields == ["hooks"] }
            return false
        }
        try expectDecodeError(makeDeclaration(profileID: "p", extraTop: ["minimumAppVersion": "1.7.60"])) { _ in true }
    }

    @Test func missingFieldsFailClosed() throws {
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "pip", "name": "pypdf", "version": "5.4.0", "purpose": "OK."]
        ])) { error in
            if case .missingFields(let fields) = error { return fields == ["required"] }
            return false
        }
        // v1 has NO unversioned font exception: missing version is missingFields.
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "font", "name": "fonts-noto-cjk", "purpose": "OK.", "required": false]
        ])) { error in
            if case .missingFields(let fields) = error { return fields == ["version"] }
            return false
        }
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "runtimeComponent", "purpose": "OK.", "required": true]
        ])) { error in
            if case .missingFields(let fields) = error { return fields == ["componentDescriptorPath"] }
            return false
        }
    }

    // MARK: - Empty documents never exist (no-deps omits the file instead)

    @Test func emptyShapesFailClosed() throws {
        try expectDecodeError(makeDeclaration(requirements: [])) { error in
            error == .invalidField("profiles[0].requirements")
        }
        var object = makeDeclaration()
        object["profiles"] = []
        try expectDecodeError(object) { error in
            error == .invalidField("profiles")
        }
    }

    // MARK: - Exact pins only (the frozen distinction #3)

    @Test func rangedAndFloatingVersionsFailClosed() throws {
        for bad in [">=2.0", "1.*,2.0", "==2.0", "latest", "stable", "~2.0", "2.0 || 3.0", ""] {
            try expectDecodeError(makeDeclaration(requirements: [
                ["kind": "pip", "name": "pypdf", "version": bad, "purpose": "OK.", "required": true]
            ])) { _ in true }
        }
        for bad in ["latest", "stable", "1:latest", "", "1.2 3"] {
            try expectDecodeError(makeDeclaration(requirements: [
                ["kind": "apt", "name": "python3-scipy", "version": bad, "purpose": "OK.", "required": true]
            ])) { _ in true }
        }
        // Fonts carry the same exact-version discipline as apt.
        for bad in ["latest", "1:latest", ""] {
            try expectDecodeError(makeDeclaration(requirements: [
                ["kind": "font", "name": "fonts-noto-cjk", "version": bad, "purpose": "OK.", "required": true]
            ])) { _ in true }
        }
        for bad in ["5.x", ">=5.0", "5.9.3.1", "latest", "5.9.3+build.9"] {
            try expectDecodeError(makeDeclaration(requirements: [
                ["kind": "npm", "name": "typescript", "version": bad, "purpose": "OK.", "required": true]
            ])) { _ in true }
        }
        // Exact real pins that MUST pass (digits present, PEP440/Debian/semver).
        for (kind, version, name) in [
            ("pip", "2026.10.23", "certifi"), ("pip", "1.14.0.post1", "sympy"),
            ("pip", "2.34.2", "requests"),
            ("apt", "1:2.2.4+ds-1", "python3-numpy"),
            ("apt", "25.03.0-5+deb13u4", "poppler-utils"),
            ("apt", "20221105+dfsg-1.1~deb13u1", "pdfminer.six"),
            ("font", "1:20240730+repack1-1", "fonts-noto-cjk"),
            ("npm", "5.9.3", "typescript"), ("npm", "1.2.0-alpha.9", "tool")
        ] as [(String, String, String)] {
            _ = try SkillDependency.decode(encoded(makeDeclaration(requirements: [
                ["kind": kind, "name": name, "version": version, "purpose": "OK.", "required": true]
            ])))
        }
    }

    @Test func namesAndIdentitiesFailClosed() throws {
        for bad in ["pypdf;rm", "pyp df", "-pypdf", "pypdf ", "@/x", "pypdf["] as [String] {
            try expectDecodeError(makeDeclaration(requirements: [
                ["kind": "pip", "name": bad, "version": "1.0", "purpose": "OK.", "required": true]
            ])) { _ in true }
        }
        for bad in ["Python3-scipy", "sci py", "scipy;rm -rf", ""] as [String] {
            try expectDecodeError(makeDeclaration(requirements: [
                ["kind": "apt", "name": bad, "version": "1.0-1", "purpose": "OK.", "required": true]
            ])) { _ in true }
        }
        // Font identities must be `fonts-…` Debian identities.
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "font", "name": "noto-cjk", "version": "1.0-1", "purpose": "OK.", "required": true]
        ])) { _ in true }
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "npm", "name": "TypeScript", "version": "1.2.3", "purpose": "OK.", "required": true]
        ])) { _ in true }
        // Profile ids follow the skill identifier grammar.
        try expectDecodeError(makeDeclaration(profileID: "Linux Guest")) { _ in true }
        try expectDecodeError(makeDeclaration(profileID: "-lead")) { _ in true }
        try expectDecodeError(makeDeclaration(profileID: "trailing-")) { _ in true }
    }

    @Test func kindsTargetsAndArchitecturesAreClosed() throws {
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "cargo", "name": "x", "version": "1.0.0", "purpose": "OK.", "required": true]
        ])) { error in
            if case .unsupportedKind("cargo") = error { return true }
            return false
        }
        try expectDecodeError(makeDeclaration(target: ["os": "ios", "architectures": ["arm64"]])) { error in
            if case .unsupportedTarget("ios") = error { return true }
            return false
        }
        try expectDecodeError(makeDeclaration(target: ["os": "linux", "architectures": ["mips"]])) { _ in true }
        try expectDecodeError(makeDeclaration(target: ["os": "linux", "architectures": []])) { _ in true }
        try expectDecodeError(makeDeclaration(target: ["os": "linux", "architectures": ["any", "any"]])) { _ in true }
        try expectDecodeError(makeDeclaration(target: ["os": "linux"])) { _ in true }
    }

    @Test func duplicatesAndLimitsFailClosed() throws {
        let one: [String: Any] = ["kind": "pip", "name": "pypdf", "version": "5.4.0", "purpose": "OK.", "required": true]
        try expectDecodeError(makeDeclaration(requirements: [one, one])) { error in
            if case .duplicateRequirement = error { return true }
            return false
        }
        var twoProfiles = makeDeclaration()
        twoProfiles["profiles"] = [
            ["id": "same", "target": ["os": "linux", "architectures": ["any"]], "requirements": [one]],
            ["id": "same", "target": ["os": "linux", "architectures": ["any"]], "requirements": [one]]
        ]
        try expectDecodeError(twoProfiles) { error in
            if case .duplicateProfileID("same") = error { return true }
            return false
        }
        twoProfiles["profiles"] = (1...9).map { index in
            ["id": "p\(index)", "target": ["os": "linux", "architectures": ["any"]], "requirements": [one]]
        }
        try expectDecodeError(twoProfiles) { error in
            if case .tooManyProfiles(9) = error { return true }
            return false
        }
    }

    @Test func purposeAndRequiredShape() throws {
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "pip", "name": "x", "version": "1.0", "purpose": "", "required": true]
        ])) { _ in true }
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "pip", "name": "x", "version": "1.0", "purpose": String(repeating: "字", count: 200), "required": true]
        ])) { _ in true }
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "pip", "name": "x", "version": "1.0", "purpose": "line\nbreak", "required": true]
        ])) { _ in true }
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "pip", "name": "x", "version": "1.0", "purpose": "OK.", "required": "true"]
        ])) { error in
            error == .invalidField("profiles[0].requirements[0].required")
        }
    }

    @Test func lockPathsArePackageLocalOnly() throws {
        for bad in ["../secret.txt", "references/../secret.txt", "scripts/req.txt",
                    "references/req.md", "references/req txt", "http://x/req.txt"] as [String] {
            try expectDecodeError(makeDeclaration(requirements: [
                ["kind": "pip", "name": "x", "version": "1.0", "purpose": "OK.", "required": true, "lockfile": bad]
            ])) { error in
                if case .lockPathRejected = error { return true }
                return false
            }
        }
        // Locks belong to pip only.
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "apt", "name": "x", "version": "1.0-1", "purpose": "OK.", "required": true, "lockfile": "references/a.txt"]
        ])) { error in
            if case .unknownFields(let fields) = error { return fields == ["lockfile"] }
            return false
        }
        // Good path shape.
        _ = try SkillDependency.decode(encoded(makeDeclaration(requirements: [
            ["kind": "pip", "name": "x", "version": "1.0", "purpose": "OK.", "required": true, "lockfile": "references/pkg/requirements.lock.txt"]
        ])))
    }

    @Test func runtimeComponentPathIsFrozenAndOwnFieldsBanned() throws {
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "runtimeComponent", "componentDescriptorPath": "references/other.json",
             "purpose": "OK.", "required": true]
        ])) { error in
            if case .descriptorPathRejected("references/other.json") = error { return true }
            return false
        }
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "runtimeComponent", "componentDescriptorPath": "references/engine-dependency.json",
             "name": "impeccable-engine", "purpose": "OK.", "required": true]
        ])) { error in
            if case .unknownFields(let fields) = error { return fields == ["name"] }
            return false
        }
        try expectDecodeError(makeDeclaration(requirements: [
            ["kind": "runtimeComponent", "componentDescriptorPath": "references/engine-dependency.json",
             "sha256": String(repeating: "0", count: 64), "purpose": "OK.", "required": true]
        ])) { error in
            if case .unknownFields(let fields) = error { return fields == ["sha256"] }
            return false
        }
    }

    // MARK: - Package cross-validation (signed bytes cover locks)

    @Test func validateRequiresDeclaredBytesPresent() throws {
        let declaration = try SkillDependency.decode(encoded(makeDeclaration(requirements: [
            ["kind": "pip", "name": "x", "version": "1.0", "purpose": "OK.", "required": true,
             "lockfile": "references/requirements.lock.txt"],
            ["kind": "runtimeComponent", "componentDescriptorPath": "references/engine-dependency.json",
             "purpose": "OK.", "required": true]
        ])))
        // Missing both -> lock error first (deterministic order).
        do {
            try SkillDependency.validate(declaration, packageFiles: ["SKILL.md": Data()])
            Issue.record("missing lock must fail")
        } catch let error as SkillDependencyError {
            guard case .lockFileMissing("references/requirements.lock.txt") = error else {
                Issue.record("unexpected \(error)"); return
            }
        }
        let withLockMissingDescriptor = [
            "references/requirements.lock.txt": Data("x==1.0 --hash=sha256:ab\n".utf8)
        ]
        do {
            try SkillDependency.validate(declaration, packageFiles: withLockMissingDescriptor)
            Issue.record("missing descriptor must fail")
        } catch let error as SkillDependencyError {
            guard case .descriptorFileMissing("references/engine-dependency.json") = error else {
                Issue.record("unexpected \(error)"); return
            }
        }
        // Complete package validates; a foreign descriptor fails through the
        // frozen SkillRuntimeDependency gate unchanged.
        var files = withLockMissingDescriptor
        files["references/engine-dependency.json"] = try engineDescriptorBytes()
        try SkillDependency.validate(declaration, packageFiles: files)
        files["references/engine-dependency.json"] = Data("{\"schemaVersion\":2}".utf8)
        #expect(throws: (any Error).self) {
            try SkillDependency.validate(declaration, packageFiles: files)
        }
    }

    @Test func declarationAndLocksAreCoveredByCanonicalDigest() {
        // The signed package digest covers the declaration and lock bytes, so
        // the curated receipt equality (existing single trust transition) is
        // already the signature binding for this channel — no external hashes.
        let lock = Data("pypdf==5.4.0 --hash=sha256:aa\n".utf8)
        let good: [String: Data] = [
            "SKILL.md": Data("x".utf8),
            "references/dependencies.json": Data("{\"schemaVersion\":1}".utf8),
            "references/requirements.lock.txt": lock
        ]
        let tampered: [String: Data] = [
            "SKILL.md": Data("x".utf8),
            "references/dependencies.json": Data("{\"schemaVersion\":2}".utf8),
            "references/requirements.lock.txt": lock
        ]
        let modifiedLock: [String: Data] = [
            "SKILL.md": Data("x".utf8),
            "references/dependencies.json": Data("{\"schemaVersion\":1}".utf8),
            "references/requirements.lock.txt": Data("pypdf==5.5.0 --hash=sha256:bb\n".utf8)
        ]
        let baseline = SkillPackageValidator.canonicalDigest(files: good)
        #expect(baseline != SkillPackageValidator.canonicalDigest(files: tampered))
        #expect(baseline != SkillPackageValidator.canonicalDigest(files: modifiedLock))
    }

    @Test func oldClientValidatorTreatsTheFileAsInertData() throws {
        // references/ stays whitelisted and .json payload is inert: an OLD
        // package (or an external skill that happens to carry the reserved
        // name) still passes the historical validator exactly as before.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skill-dep-inert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        ---
        name: dep-channel
        description: Exercises the dependency declaration path.
        ---
        Use exec.shell for everything.
        """.write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try """
        {"schemaVersion":1,"id":"dep-channel","version":"1.0.0"}
        """.write(to: root.appendingPathComponent("floe.json"), atomically: true, encoding: .utf8)
        let references = root.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let declaration = makeDeclaration(requirements: [
            ["kind": "pip", "name": "x", "version": "1.0", "purpose": "OK.", "required": true,
             "lockfile": "references/requirements.lock.txt"]
        ])
        try encoded(declaration).write(to: references.appendingPathComponent("dependencies.json"))
        try Data("x==1.0 --hash=sha256:ab\n".utf8)
            .write(to: references.appendingPathComponent("requirements.lock.txt"))
        let package = try SkillPackageValidator().validate(packageAt: root)
        #expect(package.canonicalSHA256.count == 64)
        #expect(package.files.contains { $0.relativePath == "references/dependencies.json" })
    }
}
