// SPDX-License-Identifier: MPL-2.0
//
// IDEGitHubActionsPolicy — the pure decision layer for the IDE's third run
// target, GitHub Actions. It sits beside `IDELanguageRunPolicy` and, like it,
// never performs I/O: it maps a language plus an explicit repository/workflow
// selection to a typed plan, decides which workspace files may become a
// snapshot, catalogs the reviewable workflow templates, and holds the artifact
// download/verification rules.
//
// Honesty rules encoded here:
// * A GitHub Actions run builds on GitHub's Linux/macOS runners. Its output is
//   a compile artifact, never an iOS-executable binary, and iOS signing is out
//   of scope. The plan says `role` explicitly and the UI must not present a
//   cloud build as an on-device or iOS install.
// * Only an explicit, policy-filtered file snapshot is published: `.git`,
//   secret-looking files, symlinks, non-regular files and oversized files are
//   refused. The whole workspace, credentials and `.git` are never uploaded.
// * A user-selected existing workflow is never modified; when no workflow
//   exists, a Floe template is offered for review, export, or an explicit
//   fast-forward install on the repository's **default branch** (required
//   because `workflow_dispatch` only discovers workflows that exist there).
//   The run-owned snapshot branch carries the reviewed source, never a silent
//   workflow write.
// * Artifact downloads are bounded, SHA-256 verified, and staged so a failed
//   download never overwrites a user file.

import Foundation

// MARK: - Repository selection

/// One repository the connected GitHub account can dispatch to.
struct GitHubActionsRepositorySelection: Sendable, Equatable, Hashable, Identifiable {
    let id: Int64
    let fullName: String
    let defaultBranch: String
    let isPrivate: Bool

    var owner: String {
        fullName.split(separator: "/", maxSplits: 1).first.map(String.init) ?? fullName
    }

    var repository: String {
        let parts = fullName.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : fullName
    }
}

enum GitHubActionsRunnerPlatform: String, Sendable, CaseIterable, Equatable {
    case linux
    case macOS

    var runsOn: String { self == .macOS ? "macos-26" : "ubuntu-latest" }
}

enum IDEGitHubActionsRunRole: String, Sendable, CaseIterable, Equatable {
    /// Compiles the snapshot into a Linux/macOS binary artifact.
    case build
    /// Runs the language's own lint/format/test tooling on the snapshot.
    case lintTest

    /// A cloud build is a cross-compilation relative to the iPad: it never
    /// produces an executable this device can run.
    var isCrossCompile: Bool { self == .build }
}

// MARK: - Plan

/// The resolved GitHub Actions plan for one dispatch. The snapshot commit SHA
/// and run id are added by the controller once they exist; this value is the
/// pure, reviewable part.
struct IDEGitHubActionsRunPlan: Sendable, Equatable {
    let languageID: String
    let role: IDEGitHubActionsRunRole
    let repository: GitHubActionsRepositorySelection
    /// Base branch the run branch is created from and that the workflow file
    /// must exist on (or be added to).
    let ref: String
    /// The workspace-relative file the workflow builds or checks.
    let targetFile: String
    /// User-selected existing workflow, if any. When nil a Floe template is
    /// installed to the run-owned branch.
    let workflowPath: String?
    /// The artifact name Floe expects the workflow to upload. Nil for
    /// lint/test templates (they produce logs, not artifacts).
    let expectedArtifactName: String?
    let runnerPlatform: GitHubActionsRunnerPlatform
    /// Inputs passed to `workflow_dispatch`, empty for a user workflow whose
    /// inputs Floe does not know.
    let dispatchInputs: [String: String]
    /// True when the Floe template blob must be added to the snapshot tree.
    let installsTemplate: Bool

    var usesExistingWorkflow: Bool { workflowPath != nil }
}

// MARK: - Snapshot

struct IDEGitHubActionsSnapshotCandidate: Sendable, Equatable {
    let path: String
    let isRegularFile: Bool
    let isSymlink: Bool
    let byteCount: Int
    let sha256: String

    init(path: String, isRegularFile: Bool, isSymlink: Bool, byteCount: Int, sha256: String) {
        self.path = path
        self.isRegularFile = isRegularFile
        self.isSymlink = isSymlink
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

struct IDEGitHubActionsSnapshotEntry: Sendable, Equatable {
    let path: String
    let byteCount: Int
    let sha256: String
}

enum IDEGitHubActionsSnapshotExclusion: Sendable, Equatable {
    case unsafePath
    case gitMetadata
    case generatedArtifact
    case secretFile
    case notRegularFile
    case symlink
    case fileTooLarge(path: String, limit: Int)
    case totalTooLarge(limit: Int)
    case tooManyFiles(limit: Int)

    var path: String? {
        if case .fileTooLarge(let path, _) = self { return path }
        return nil
    }
}

enum IDEGitHubActionsSnapshotError: Error, Sendable, Equatable {
    case empty
    case tooManyFiles(limit: Int)
    case totalTooLarge(limit: Int)
}

struct IDEGitHubActionsSnapshotManifest: Sendable, Equatable {
    /// Deterministically sorted (path ascending) entries.
    let entries: [IDEGitHubActionsSnapshotEntry]
    let totalBytes: Int
    /// Files dropped by the filter, with the typed reason, so the UI can show
    /// exactly what was not uploaded.
    let excluded: [IDEGitHubActionsSnapshotExclusion]

    var fileCount: Int { entries.count }
}

enum IDEGitHubActionsSnapshotPolicy {
    /// A single snapshot file may not exceed 5 MiB (source code, small assets).
    static let maximumFileBytes = 5 * 1024 * 1024
    /// The whole snapshot may not exceed 64 MiB.
    static let maximumTotalBytes = 64 * 1024 * 1024
    /// Bounded file count so a mistaken directory selection cannot become an
    /// accidental full-repository upload.
    static let maximumFileCount = 2_000
    /// Recursion and page bounds for the recursive preview walk. A directory
    /// listing pages at 200 entries, so pages are followed to completion, but
    /// neither the depth nor the page count is unbounded.
    static let maximumDirectoryDepth = 12
    static let maximumDirectoryPages = 50

    /// Directories a project snapshot never descends into: VCS internals,
    /// Floe's own generated tree and dependency/build output that a remote
    /// build regenerates. This is a size/perf bound, not a trust boundary; the
    /// per-file filter below still runs on everything that is included.
    private static let skippedDirectories: Set<String> = [
        ".git", ".floe", ".build", ".swiftpm", "DerivedData", "node_modules",
        "Pods", ".venv", "venv", "__pycache__", ".gradle", ".idea", ".next"
    ]

    static func isSnapshotSkipDirectory(_ name: String) -> Bool {
        skippedDirectories.contains(name)
    }

    /// Applies the snapshot safety filter and returns a deterministic manifest
    /// or a typed error. Candidates are supplied by the caller after reading
    /// the workspace through `WorkspacePathGuard`; this function re-checks the
    /// path shape so a crafted candidate cannot slip past the caller.
    static func manifest(
        candidates: [IDEGitHubActionsSnapshotCandidate]
    ) throws -> IDEGitHubActionsSnapshotManifest {
        var entries: [IDEGitHubActionsSnapshotEntry] = []
        var excluded: [IDEGitHubActionsSnapshotExclusion] = []
        var seen = Set<String>()
        var total = 0

        for candidate in candidates.sorted(by: { $0.path < $1.path }) {
            guard !seen.contains(candidate.path) else { continue }
            seen.insert(candidate.path)

            guard IDELanguageRunPolicy.isSafeWorkspaceRelativePath(candidate.path) else {
                excluded.append(.unsafePath); continue
            }
            if isGitMetadata(candidate.path) {
                excluded.append(.gitMetadata); continue
            }
            if isGeneratedPath(candidate.path) {
                excluded.append(.generatedArtifact); continue
            }
            if isSecretPath(candidate.path) {
                excluded.append(.secretFile); continue
            }
            if candidate.isSymlink {
                excluded.append(.symlink); continue
            }
            guard candidate.isRegularFile else {
                excluded.append(.notRegularFile); continue
            }
            if candidate.byteCount > maximumFileBytes {
                excluded.append(.fileTooLarge(path: candidate.path, limit: maximumFileBytes)); continue
            }
            if entries.count >= maximumFileCount {
                excluded.append(.tooManyFiles(limit: maximumFileCount)); break
            }
            if total + candidate.byteCount > maximumTotalBytes {
                excluded.append(.totalTooLarge(limit: maximumTotalBytes)); continue
            }
            total += candidate.byteCount
            entries.append(IDEGitHubActionsSnapshotEntry(
                path: candidate.path, byteCount: candidate.byteCount, sha256: candidate.sha256
            ))
        }

        guard !entries.isEmpty else { throw IDEGitHubActionsSnapshotError.empty }
        guard entries.count <= maximumFileCount else { throw IDEGitHubActionsSnapshotError.tooManyFiles(limit: maximumFileCount) }
        guard total <= maximumTotalBytes else { throw IDEGitHubActionsSnapshotError.totalTooLarge(limit: maximumTotalBytes) }
        return IDEGitHubActionsSnapshotManifest(entries: entries, totalBytes: total, excluded: excluded)
    }

    /// Anything below a `.git` component is repository internals, never a
    /// user source snapshot.
    static func isGitMetadata(_ path: String) -> Bool {
        path == ".git" || path.hasPrefix(".git/") || path.contains("/.git/")
    }

    /// Floe's own generated tree (downloaded artifacts, exported templates) is
    /// never re-uploaded as if it were user source.
    static func isGeneratedPath(_ path: String) -> Bool {
        path == ".floe" || path.hasPrefix(".floe/") || path.contains("/.floe/")
    }

    /// Mirrors `WorkspacePathGuard`'s secret denylist for the snapshot filter.
    /// The guard remains the authoritative choke point for reads; this is a
    /// second, plan-level refusal so a secret can never reach a commit plan.
    static func isSecretPath(_ path: String) -> Bool {
        let exactNames: Set<String> = [".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd"]
        let prefixes = [".env", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".pgpass"]
        let secretExtensions: Set<String> = ["pem", "key", "keystore", "p12", "pfx", "jks"]
        let secretDirectories: Set<String> = [".ssh", ".aws", ".gnupg"]
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        let lowered = name.lowercased()
        if components.contains(where: { secretDirectories.contains($0) }) { return true }
        if exactNames.contains(lowered) { return true }
        if prefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty && secretExtensions.contains(ext) { return true }
        if let gitIndex = components.lastIndex(of: ".git"), gitIndex < components.count - 1 {
            let inside = components[(gitIndex + 1)...]
            if inside.first == "config" || inside.first == "credentials" { return true }
        }
        return false
    }

    /// Path of the run-owned branch a snapshot is committed to. Deterministic
    /// per run token and never the user's default branch.
    static func runBranch(runToken: String) -> String {
        "floe-ide/\(IDERunStagingLayout.sanitizedToken(runToken))"
    }
}

// MARK: - Workflow templates

/// A reviewable workflow template. `yaml` is complete and can be shown,
/// exported to `.floe/workflows` for manual review, or installed on the
/// repository's **default branch** with an explicit fast-forward commit (the
/// only place `workflow_dispatch` can discover it). Templates never overwrite
/// a divergent file: a collision returns a suggested Floe-owned path.
struct IDEGitHubActionsWorkflowTemplate: Sendable, Equatable, Identifiable {
    let id: String
    let languageID: String
    let role: IDEGitHubActionsRunRole
    let runnerPlatform: GitHubActionsRunnerPlatform
    /// Repository-relative file name Floe installs on the run branch.
    let fileName: String
    let expectedArtifactName: String?
    let inputs: [String: String]
    let yaml: String

    var workflowPath: String { ".github/workflows/\(fileName)" }
}

enum IDEGitHubActionsWorkflowCatalog {
    /// The user-supplied target path reaches the shell only through a
    /// workflow-level environment variable, never interpolated into the script
    /// text. `${{ inputs.target_file }}` inside a `run:` body would let a
    /// hostile path become shell source; `"$FLOE_TARGET_FILE"` keeps it data.
    /// The `./` prefix stops a name beginning with `-` being read as a flag.
    static let targetFileEnvironmentName = "FLOE_TARGET_FILE"
    static let targetFileReference = "./$\(targetFileEnvironmentName)"
    /// `checkout` pins to the exact Floe snapshot commit. The workflow is
    /// dispatched on the run-owned branch, but the source snapshot is the
    /// immutable identity the run must build.
    static let snapshotPlaceholder = "${{ inputs.snapshot_sha }}"
    /// Action commits already pinned elsewhere in this repository, so a
    /// generated template never executes a floating tag.
    static let pinnedCheckout = "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"
    static let pinnedUploadArtifact = "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
    /// A workflow template is a small YAML document; the export path bound.
    static let maximumTemplateBytes = 256 * 1024

    /// A workflow path is only a valid selection when it is a YAML file inside
    /// `.github/workflows`; a template may never be installed elsewhere.
    static func isWorkflowPath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.hasPrefix(".github/workflows/") else { return false }
        let remainder = normalized.dropFirst(".github/workflows/".count)
        guard !remainder.isEmpty, !remainder.contains("/") else { return false }
        let ext = (String(remainder) as NSString).pathExtension.lowercased()
        return ext == "yml" || ext == "yaml"
    }

    static func template(id: String) -> IDEGitHubActionsWorkflowTemplate? {
        templates.first { $0.id == id }
    }

    static func templates(for languageID: String) -> [IDEGitHubActionsWorkflowTemplate] {
        templates.filter { $0.languageID == languageID }
    }

    static func template(
        languageID: String, role: IDEGitHubActionsRunRole, platform: GitHubActionsRunnerPlatform
    ) -> IDEGitHubActionsWorkflowTemplate? {
        templates.first {
            $0.languageID == languageID && $0.role == role && $0.runnerPlatform == platform
        } ?? templates.first { $0.languageID == languageID && $0.role == role }
    }

    static let templates: [IDEGitHubActionsWorkflowTemplate] = [
        make(id: "build.rust", languageID: "rust", role: .build, platform: .linux,
             artifact: "floe-rust-build",
             body: """
             name: Floe IDE Build (Rust)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               build:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - name: Build
                     run: |
                       set -euo pipefail
                       if [ -f Cargo.toml ]; then
                         cargo build --release
                       else
                         rustc "{{TARGET}}" -o program
                       fi
                   - name: Upload artifact
                     uses: actions/upload-artifact@v4
                     with:
                       name: floe-rust-build
                       path: |
                         program
                         target/release/
                       if-no-files-found: ignore
             """),
        make(id: "lint.rust", languageID: "rust", role: .lintTest, platform: .linux,
             artifact: nil,
             body: """
             name: Floe IDE Check (Rust)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               check:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - name: Compile check
                     run: rustc --edition 2021 --emit=metadata "{{TARGET}}"
             """),
        make(id: "build.swift", languageID: "swift", role: .build, platform: .macOS,
             artifact: "floe-swift-build",
             body: """
             name: Floe IDE Build (Swift)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               build:
                 runs-on: macos-26
                 steps:
                   - uses: actions/checkout@v4
                   - name: Build
                     run: |
                       set -euo pipefail
                       if [ -f Package.swift ]; then
                         swift build -c release
                       else
                         swiftc "{{TARGET}}" -o program
                       fi
                   - name: Upload artifact
                     uses: actions/upload-artifact@v4
                     with:
                       name: floe-swift-build
                       path: |
                         program
                         .build/release/
                       if-no-files-found: ignore
             """),
        make(id: "build.c", languageID: "c", role: .build, platform: .linux,
             artifact: "floe-c-build",
             body: """
             name: Floe IDE Build (C)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               build:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - name: Build
                     run: |
                       set -euo pipefail
                       if [ -f Makefile ] || [ -f makefile ]; then make
                       elif [ -f CMakeLists.txt ]; then cmake -S . -B build && cmake --build build
                       else cc -Wall -Wextra "{{TARGET}}" -o program; fi
                   - name: Upload artifact
                     uses: actions/upload-artifact@v4
                     with:
                       name: floe-c-build
                       path: |
                         program
                         build/
                       if-no-files-found: ignore
             """),
        make(id: "build.cpp", languageID: "cpp", role: .build, platform: .linux,
             artifact: "floe-cpp-build",
             body: """
             name: Floe IDE Build (C++)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               build:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - name: Build
                     run: |
                       set -euo pipefail
                       if [ -f Makefile ] || [ -f makefile ]; then make
                       elif [ -f CMakeLists.txt ]; then cmake -S . -B build && cmake --build build
                       else c++ -Wall -Wextra "{{TARGET}}" -o program; fi
                   - name: Upload artifact
                     uses: actions/upload-artifact@v4
                     with:
                       name: floe-cpp-build
                       path: |
                         program
                         build/
                       if-no-files-found: ignore
             """),
        make(id: "build.go", languageID: "go", role: .build, platform: .linux,
             artifact: "floe-go-build",
             body: """
             name: Floe IDE Build (Go)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               build:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - name: Build
                     run: |
                       set -euo pipefail
                       if [ -f go.mod ]; then go build ./...
                       else go build -o program "{{TARGET}}"; fi
                   - name: Upload artifact
                     uses: actions/upload-artifact@v4
                     with:
                       name: floe-go-build
                       path: program
             """),
        make(id: "build.java", languageID: "java", role: .build, platform: .linux,
             artifact: "floe-java-build",
             body: """
             name: Floe IDE Build (Java)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               build:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - uses: actions/setup-java@v4
                     with:
                       distribution: temurin
                       java-version: '21'
                   - name: Build
                     run: |
                       set -euo pipefail
                       if [ -x ./gradlew ]; then ./gradlew --no-daemon build
                       elif [ -f pom.xml ]; then mvn -q -DskipTests package
                       else mkdir -p out && javac -d out "{{TARGET}}"; fi
                   - name: Upload artifact
                     uses: actions/upload-artifact@v4
                     with:
                       name: floe-java-build
                       path: |
                         out
                         build/
                         target/
                       if-no-files-found: ignore
             """),
        make(id: "build.kotlin", languageID: "kotlin", role: .build, platform: .linux,
             artifact: "floe-kotlin-build",
             body: """
             name: Floe IDE Build (Kotlin)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               build:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - name: Build
                     run: |
                       set -euo pipefail
                       if [ -x ./gradlew ]; then ./gradlew --no-daemon build
                       else
                         curl -sSL -o kotlin.zip https://github.com/JetBrains/kotlin/releases/download/v2.0.21/kotlin-compiler-2.0.21.zip
                         unzip -q kotlin.zip
                         kotlinc/bin/kotlinc "{{TARGET}}" -include-runtime -d program.jar
                       fi
                   - name: Upload artifact
                     uses: actions/upload-artifact@v4
                     with:
                       name: floe-kotlin-build
                       path: |
                         program.jar
                         build/
                       if-no-files-found: ignore
             """),
        make(id: "lint.python", languageID: "python", role: .lintTest, platform: .linux,
             artifact: nil,
             body: """
             name: Floe IDE Check (Python)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               check:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - uses: actions/setup-python@v5
                     with:
                       python-version: '3.12'
                   - name: Compile and run
                     run: python -m py_compile "{{TARGET}}"
             """),
        make(id: "lint.javascript", languageID: "javascript", role: .lintTest, platform: .linux,
             artifact: nil,
             body: """
             name: Floe IDE Check (JavaScript)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               check:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - uses: actions/setup-node@v4
                     with:
                       node-version: '20'
                   - name: Syntax check
                     run: node --check "{{TARGET}}"
             """),
        make(id: "lint.shell", languageID: "shell", role: .lintTest, platform: .linux,
             artifact: nil,
             body: """
             name: Floe IDE Check (Shell)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               check:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - name: Syntax check
                     run: sh -n "{{TARGET}}"
             """),
        make(id: "lint.lua", languageID: "lua", role: .lintTest, platform: .linux,
             artifact: nil,
             body: """
             name: Floe IDE Check (Lua)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               check:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - name: Install Lua
                     run: sudo apt-get update && sudo apt-get install -y lua5.4
                   - name: Syntax check
                     run: luac5.4 -p "{{TARGET}}"
             """),
        make(id: "lint.php", languageID: "php", role: .lintTest, platform: .linux,
             artifact: nil,
             body: """
             name: Floe IDE Check (PHP)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               check:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - uses: shivammathur/setup-php@v2
                     with:
                       php-version: '8.3'
                   - name: Lint
                     run: php -l "{{TARGET}}"
             """),
        make(id: "lint.ruby", languageID: "ruby", role: .lintTest, platform: .linux,
             artifact: nil,
             body: """
             name: Floe IDE Check (Ruby)
             on:
               workflow_dispatch:
                 inputs:
                   snapshot_sha:
                     description: Floe snapshot commit
                     required: true
                   target_file:
                     description: Workspace-relative source file
                     required: true
             jobs:
               check:
                 runs-on: ubuntu-latest
                 steps:
                   - uses: actions/checkout@v4
                   - uses: ruby/setup-ruby@v1
                     with:
                       ruby-version: '3.3'
                   - name: Syntax check
                     run: ruby -c "{{TARGET}}"
             """)
    ]

    private static func make(
        id: String, languageID: String, role: IDEGitHubActionsRunRole,
        platform: GitHubActionsRunnerPlatform, artifact: String?, body: String
    ) -> IDEGitHubActionsWorkflowTemplate {
        IDEGitHubActionsWorkflowTemplate(
            id: id, languageID: languageID, role: role, runnerPlatform: platform,
            fileName: "floe-\(id.replacingOccurrences(of: ".", with: "-")).yml",
            expectedArtifactName: artifact,
            inputs: ["snapshot_sha": "", "target_file": ""],
            yaml: IDEGitHubActionsWorkflowInstallationPolicy.generatedMarker
                + "\n" + hardened(
                    body.replacingOccurrences(of: "{{TARGET}}", with: targetFileReference)
                )
        )
    }

    /// Applies the non-negotiable safety envelope to a generated template:
    /// * `permissions: contents: read` — a build/lint run needs no write scope;
    /// * a workflow-level `env` carrying the user's target path as data, so a
    ///   hostile file name cannot become shell source;
    /// * a pinned `actions/checkout` that checks out the exact snapshot commit
    ///   and never persists credentials in the runner's git config;
    /// * a pinned `actions/upload-artifact`.
    /// The transform is line-based and indentation-preserving so every template
    /// gets exactly the same envelope.
    private static func hardened(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var insertedEnvelope = false
        for line in lines {
            let indent = String(line.prefix { $0 == " " })
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "jobs:", !insertedEnvelope {
                output.append("\(indent)permissions:")
                output.append("\(indent)  contents: read")
                output.append("\(indent)env:")
                output.append("\(indent)  \(targetFileEnvironmentName): ${{ inputs.target_file }}")
                insertedEnvelope = true
            }
            if trimmed == "- uses: actions/checkout@v4" {
                output.append("\(indent)- uses: \(pinnedCheckout) # v5")
                output.append("\(indent)  with:")
                output.append("\(indent)    ref: \(snapshotPlaceholder)")
                output.append("\(indent)    persist-credentials: false")
                continue
            }
            output.append(
                line.replacingOccurrences(
                    of: "actions/upload-artifact@v4",
                    with: "\(pinnedUploadArtifact) # v4.6.2"
                )
            )
        }
        return output.joined(separator: "\n")
    }
}

// MARK: - Workflow installation contract

/// How a Floe template may be placed on a repository. `workflow_dispatch`
/// cannot see a workflow that exists only on a non-default branch, so a Floe
/// template must be installed on the repository's **default branch** before it
/// can ever be dispatched. This is a write to the user's repository, so it is
/// always an explicit user action and never overwrites a divergent file.
enum IDEGitHubActionsWorkflowInstallDecision: Sendable, Equatable {
    /// The path does not exist on the default branch: install the template.
    case install
    /// The identical template is already there; nothing to do.
    case alreadyInstalled
    /// A different file occupies the path. Floe never overwrites it: the
    /// caller offers an export and/or installing under `suggestedPath`.
    case conflict(suggestedPath: String)
}

enum IDEGitHubActionsWorkflowInstallationPolicy {
    /// Every Floe template starts with this marker so a later run can tell a
    /// Floe-installed workflow from a hand-written one.
    static let generatedMarker = "# Generated by Floe IDE"

    static func decision(
        existingSHA256: String?, templateSHA256: String,
        templatePath: String, existingPaths: [String]
    ) -> IDEGitHubActionsWorkflowInstallDecision {
        guard let existingSHA256, !existingSHA256.isEmpty else { return .install }
        if existingSHA256 == templateSHA256 { return .alreadyInstalled }
        return .conflict(
            suggestedPath: uniquePath(base: templatePath, existingPaths: existingPaths)
        )
    }

    /// A collision-free Floe-owned path, so installing never touches the
    /// user's existing workflow of the same base name.
    static func uniquePath(
        base: String, existingPaths: [String], token: String = "floe"
    ) -> String {
        let directory = (base as NSString).deletingLastPathComponent
        let file = (base as NSString).lastPathComponent
        let stem = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        var candidate = directory.isEmpty
            ? "\(stem)-\(token).\(ext)"
            : "\(directory)/\(stem)-\(token).\(ext)"
        var attempt = 2
        while existingPaths.contains(candidate) {
            let next = directory.isEmpty
                ? "\(stem)-\(token)\(attempt).\(ext)"
                : "\(directory)/\(stem)-\(token)\(attempt).\(ext)"
            candidate = next
            attempt += 1
        }
        return candidate
    }

    /// True only for a template Floe itself generated; a user workflow that
    /// merely shares the path is never silently replaced.
    static func isFloeGenerated(_ yaml: String) -> Bool {
        yaml.hasPrefix(generatedMarker)
    }
}

// MARK: - Artifact policy

enum IDEGitHubActionsArtifactPolicy {
    static let maximumArtifactBytes = 64 * 1024 * 1024
    /// Root below the workspace where downloaded artifacts are staged.
    static let artifactRoot = ".floe/artifacts"

    struct Destination: Sendable, Equatable {
        let relativePath: String
        let overwrite: Bool
    }

    /// Deterministic destination inside the workspace. The center resolves it
    /// through `WorkspacePathGuard` before writing; a second download of the
    /// same run/artifact does not silently replace the first file.
    static func destination(runID: Int64, suggestedFileName: String, overwrite: Bool) -> Destination {
        let safe = suggestedFileName.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression
        )
        let name = safe.isEmpty ? "artifact.zip" : safe
        return Destination(relativePath: "\(artifactRoot)/\(runID)/\(name)", overwrite: overwrite)
    }

    /// Rejects an unsafe or absolute destination before the guard sees it.
    static func isSafeDestination(_ relativePath: String) -> Bool {
        IDELanguageRunPolicy.isSafeWorkspaceRelativePath(relativePath)
            && relativePath.hasPrefix(artifactRoot + "/")
    }

    /// Normalizes GitHub's `sha256:<hex>` digest form to a bare lowercase hex
    /// string. Returns nil for an absent/blank digest, which means the server
    /// did not attest the bytes.
    static func normalizedSHA256(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sha256:") {
            let hex = String(trimmed.dropFirst("sha256:".count))
            return hex.isEmpty ? nil : hex
        }
        return trimmed
    }

    /// The downloaded bytes must match the API-attested digest the caller will
    /// surface. A missing expected digest fails closed rather than writing
    /// unverified bytes; callers that have no remote digest must record the
    /// download as checksum-only instead of "verified".
    static func verify(data: Data, expectedSHA256: String?, sha256: (Data) -> String) -> Bool {
        guard let expectedSHA256, !expectedSHA256.isEmpty, !data.isEmpty else { return false }
        return sha256(data).lowercased() == expectedSHA256.lowercased()
    }
}
