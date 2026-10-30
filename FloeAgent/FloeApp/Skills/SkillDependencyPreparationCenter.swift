// FloeApp — service-owned official Skill dependency preparation.
//
// The app-side half of the reviewed `references/dependencies.json` channel
// (author contract: docs/skills/SKILL_DEPENDENCIES_AUTHOR_GUIDE.md, schema
// v1). It mirrors the proven lazy runtime-component skeleton without touching
// that channel: separated states, none implied by another, and a serialized
// copy is never a ready token.
//
//   install — an official curated install (typed receipt, production feed,
//       approve review) commits the package; the declaration bytes are
//       strict-decoded and persisted here (service-owned persistence).
//       Global UI install has NO run/environment, so this half may show only
//       "installed/verified" and never "packages ready".
//   plan — a verified exact `skill.read` inside a task bound to a resolved
//       external target records an immutable (environmentID, runID,
//       target-identity)-bound plan pinning package VERSION + contentDigest +
//       dependencyManifest digest (SHA-256 of the declaration bytes).
//       Recording installs nothing.
//   prepare — at the skill's approved `exec.shell` invocation that carries
//       `skillID`, requirements install automatically INTO THAT SAME
//       environment (no user target picker, no rerouting, no new environment,
//       no new execution alias): pip through the managed installer with venv
//       inventory readback, apt through the guest's own single
//       `apt-get install -y --no-install-recommends name=version` transaction
//       with dpkg readback, npm as exact `name@version` pins with real tree
//       readback (a packaged package-lock.json is never replayed), fonts as an
//       exact apt identity+version pin plus the fixed CJK glyph-rendering
//       probe (stdlib ctypes FreeType: open face, nonzero Chinese/Japanese
//       glyph indices, render at 32 px), and runtime components observed
//       through the EXISTING allowlisted managed deployment (its allowlist,
//       caps and nonblocking hook stay exactly as designed). Downloads
//       deduplicate in the environment's shared `/floe/cache` like every
//       managed install; install state always lives in the environment layer.
//   target — the trusted actual target is SELECTED, never inferred from the
//       client OS or the native CPU. Profile OS + `target.architectures` must
//       intersect the resolved backend's verified facts (Linux ARM64/x86_64,
//       the pinned Linux guest, or a typed SSH host). apt/font preparation is
//       Debian-family Linux only; macOS never gets apt or a Homebrew
//       auto-install. Zero matching profiles refuses honestly before any
//       mutation; matching profiles that pin the same identity to different
//       exact versions contradict and refuse before any transaction, while
//       identical exact duplicates reuse instead of conflicting.
//   lock — a declared pip lockfile is binding, not decoration: its
//       sha256 pins for the exact spec gate persisted store wheels
//       (contradicted bytes are removed before pip can see them) and put
//       the guest pip transaction into its own --require-hashes mode. A
//       lock without a digest for the declared spec fails honestly;
//       lock-free exact pins keep today's behavior.
//   migration — the environment migration coordinator calls the native-only
//       `prepareForMigration` after the user's explicit "Prepare and Migrate"
//       consent. It uses the same authority/recordPlan/prepare/readback path
//       without minting or reusing a tool ApprovalGrant; ordinary exec.shell
//       invocation still requires the real grant.
//   receipt — per requirement, bound to (packageVersion, contentDigest,
//       declarationSHA256, environmentID, target identity, generation token).
//       Reusable only while the live authority still matches, the resolved
//       target fingerprint is identical and the generation is current; boot
//       rotation, target change, disable, uninstall, edit or a revoked grant
//       invalidates it. A same-environment collision with a different
//       installed version is a fail-closed conflict checked BEFORE any
//       mutation: never a silent downgrade, never an implicit upgrade.
//
// Version management (the frozen four): the Skill package id/version stays
// the single user-visible authority. An update or rollback replaces the
// immutable package + descriptor pair; a running invocation remains pinned to
// the pair its run verified (a later install/update cannot swap those bytes —
// revalidation fails closed and the run must re-read), unknown newer schema
// versions fail compatibility for provisioning only, and the existing
// minimumAppVersion hub gate keeps old clients from ever installing a
// dependency-carrying entry. Uninstall removes ownership records ONLY — never
// automatic apt/pip/npm deletion; explicit environment-package removal stays
// a user action in the environment package UI where nothing else installed
// still needs the exact spec.
//
// Cancellation/coalescing: preparation runs once per (environment, skill,
// profile, requirement identity) and coalesces concurrent callers. A waiter
// cancellation detaches only that waiter (the owned operation keeps serving
// the others); the last departing waiter — or `releaseEnvironment` — cancels
// and JOINS the owned operation before returning. Failed required
// preparation leaves the skill honestly NOT ready (retry happens on the next
// approved invocation); optional gaps never block and appear as a visible
// annotation.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeExecution
import FloeSkills
import FloeTools

// MARK: - Authority (constructed only by SkillsCenter from verified facts)

/// Live authority facts for one dependency-bearing official skill. Built ONLY
/// by `SkillsCenter` from the actual installed + ENABLED row, its typed
/// curated receipt and the digest-verified pinned snapshot. The center
/// re-checks the formal shape and re-fetches this on every fresh use —
/// serialized declaration bytes are never authority.
struct SkillDependencyAuthority: Sendable, Equatable {
    let skillID: String
    /// The floe.json semantic package version — the single user-visible
    /// authority. Plans and receipts pin it together with the digests.
    let packageVersion: String
    /// Canonical package digest; equals the row digest and the snapshot digest.
    let contentDigest: String
    let packageSHA256: String
    let catalogSHA256: String
    let reviewSHA256: String
    /// Immutable publication Y (receipt identity; provenance for locks).
    let publicationCommit: String
    let feedStatus: CuratedSkillFeedStatus
    let reviewDecision: CuratedSkillReviewDecision
    let feedSignatureKeyID: String
    let reviewKeyID: String
    let hubRepository: String
    /// Exact bytes of references/dependencies.json in the pinned snapshot.
    let declarationBytes: Data
    let declarationSHA256: String
    /// Exact pinned package bytes for lock + descriptor cross-validation
    /// (same discipline as the runtime-component authority).
    let packageFiles: [String: Data]
}

// MARK: - Outcome / receipt / state values

/// One verified requirement fact. `evidence` is model-safe readback text
/// (e.g. `venv 2.2.3`, `dpkg 1:20240616-1`, `node 5.9.3`, `cjk-probe ok`).
struct SkillDependencyEntry: Sendable, Equatable {
    let kind: SkillDependencyRequirement.Kind
    let name: String
    let version: String?
    let required: Bool
    let evidence: String
}

enum SkillDependencyRequirementOutcome: Sendable, Equatable {
    case verified(SkillDependencyEntry)
    case deferred(reason: String)
}

/// Per-(environment, requirement identity) verified receipt, bound to the
/// exact immutable package + descriptor pair and the guest launch generation.
struct SkillDependencyRequirementReceipt: Sendable, Equatable {
    let skillID: String
    let packageVersion: String
    let contentDigest: String
    let declarationSHA256: String
    /// Comparable generation token (guest launch generation or the core
    /// bridge/SSH runtime generation). Nil/foreign tokens are never reused.
    let generationToken: String?
    /// OS/architecture/backend/distribution identity this receipt was verified
    /// against. A receipt is NEVER reused across target identities.
    let targetFingerprint: String
    let entry: SkillDependencyEntry
    let verifiedAt: Date
}

struct SkillDependencyState: Sendable, Equatable {
    var planRecorded = false
    var sourceAuthorized = false
    var prepared = false
    var readbackVerified = false
    var deferredReason: String?
}

enum SkillDependencyPlanOutcome: Sendable, Equatable {
    case recorded(environmentID: String, runID: UUID)
    case rejected(reason: String)
}

enum SkillDependencyInvocationOutcome: Sendable, Equatable {
    /// Every required resource is verified for THIS run/environment/package
    /// pair; `annotation` lists optional gaps. The owning command proceeds.
    case ready(annotation: String)
    /// A required resource is not verified. This skill's dependency-aware
    /// invocation is refused with the honest reason; the default shell path
    /// (no `skillID`) is untouched, so a run can always repair itself.
    case refused(reason: String)
}

/// One participating requirement's migration-preparation state. Non-matching
/// profiles do not participate on the resolved target and are not emitted as
/// a readiness claim.
struct SkillDependencyMigrationRequirement: Sendable, Equatable {
    enum State: String, Sendable, Equatable {
        case verified
        case refused
        case unavailable
    }

    let kind: String
    let name: String
    let version: String?
    let required: Bool
    let state: State
    let reason: String?
}

/// Native-only preparation result for the migration coordinator. The caller
/// has already obtained the user's explicit "Prepare and Migrate" consent for
/// the displayed target and declared dependencies; this method mints no
/// approval grant and never reuses an exec.shell tool-call grant.
enum SkillDependencyMigrationPreparationOutcome: Sendable, Equatable {
    /// Every required participating dependency is verified for this exact
    /// target/package pair. `annotation` lists optional gaps.
    case verified(annotation: String, requirements: [SkillDependencyMigrationRequirement])
    /// A required dependency is not ready; the migration must not commit.
    case refused(reason: String, requirements: [SkillDependencyMigrationRequirement])
    /// No reviewed declaration/authority, or no resolvable external target.
    /// No readiness is claimed; an external skill remains model-managed.
    case unavailable(reason: String)
}

/// Stable, model-safe reasons. None carries a host path.
enum SkillDependencyReason {
    static let noEnvironment = "no task execution environment is bound to this run"
    static let noRun = "no run identity is bound to this read or invocation"
    static let authorizationUnavailable = "the installed skill authorization could not be revalidated"
    static let declarationRejected = "the packaged dependency declaration failed strict validation"
    static let unsupportedSchema = "the dependency declaration schemaVersion is newer than this build supports"
    static let environmentUnavailable = "the resolved execution environment is unavailable"
    static let cancelled = "dependency preparation was cancelled"
    static let provisioningUnavailable = "official Skill dependency provisioning is not configured in this build"
    static func sharedPreparationDeferred(skillID: String) -> String {
        "official skill \(skillID) is installed/verified with a validated dependency declaration; the shared-store prefetch (host-side audited wheels / cached component artifact, if any) is recorded in the preparation status, and the environment install + readback half runs automatically at the skill's first exec.shell invocation with skillID in a task bound to a resolved external target — a global install picks no environment, reroutes nothing and claims no readiness"
    }
    static func conflict(name: String, installed: String, pinned: String) -> String {
        "the environment already installs \(name) at \(installed), which conflicts with the reviewed pin \(pinned); nothing was changed and no silent downgrade or upgrade is performed"
    }
    static func failed(requirement: String, reason: String) -> String {
        "required dependency \(requirement) is not ready: \(reason)"
    }
    static func optionalGap(requirement: String, reason: String) -> String {
        "optional dependency \(requirement) is not available: \(reason)"
    }
    static let planStale = "the installed package changed since this run's verified read; re-read the skill with skill.read before invoking it"
    /// Architecture is part of the ORIGINAL declaration contract: a profile
    /// that does not target the actual local Linux backend (TinyEMU riscv64
    /// today — deliberately NOT the native Mac CPU) never installs here.
    static func noMatchingProfile(architectures: [String]) -> String {
        "none of the reviewed profiles targets this Linux environment's architecture (\(architectures.joined(separator: ", "))); nothing was installed or prefetched for the non-matching profiles"
    }
    static func profileConflict(name: String, first: String, second: String) -> String {
        "two profiles matching this environment's architecture pin \(name) to conflicting exact versions (\(first) and \(second)); the declaration is ambiguous, nothing was installed"
    }
    static func lockUnpinned(name: String) -> String {
        "the declared pip lock pins no sha256 digest for the exact declared spec \(name); the wheel bytes could not be bound to the signed lock"
    }
    static func lockSyntaxRejected(name: String) -> String {
        "the declared pip lock for \(name) is not a strict exact name==version closure with a sha256 pin per entry (no operators, URLs, flags or contradictory duplicates are guessed); refusing instead of a partial hash mode that could never verify the transitive set"
    }
    static func lockMismatch(name: String) -> String {
        "the wheel bound in the shared store for \(name) does not match the signed lock's sha256 pins; installing a silent different artifact is refused"
    }
    static func wheelNameRejected(spec: String) -> String {
        "the fetched wheel filename is not the canonical PEP 427 basename of the exact pinned spec (\(spec)); refusing to persist it into the shared wheel store"
    }
    static func nonMatchingArchSkipped(architectures: [String], supported: [String]) -> String {
        "profile targets \(architectures.joined(separator: ", ")), not this Linux backend (\(supported.joined(separator: ", "))); install/readback never runs for it here"
    }

    // MARK: - Actual target reasons (injected target facts)

    /// No trusted target was produced. This is final: the caller must not
    /// substitute the Mac host, the first environment or a foreign cache.
    static let targetUnavailable = "the task's resolved execution target is unavailable; no local or Mac-host fallback was used"
    static let targetDisconnected = "the task's resolved execution target is not connected; nothing was installed and no local fallback ran"
    /// The target is the App's own native toolchain, not an external shell.
    static let targetUnsupported = "the resolved execution target runs App-native tools only; external scripts and dependencies need a Linux or macOS target"
    /// The plan was recorded for a different target identity.
    static let targetChanged = "the task's execution target changed since this run read the skill; re-read the skill on the new target"
    /// A dependency-aware migration request for a package with no reviewed
    /// declaration/authority. It is not a failure of a declared requirement:
    /// the external skill stays model-managed and nothing is claimed ready.
    static let noDeclaration = "this skill has no reviewed dependency declaration or its installed authorization cannot be revalidated; external work remains model-managed and no readiness is claimed"
    static func noMatchingTarget(os: String, architectures: [String]) -> String {
        "none of the reviewed profiles targets the resolved \(os) architecture (\(architectures.joined(separator: ", "))); nothing was installed or prefetched"
    }
    static func unsupportedPackageManager(kind: String, target: String) -> String {
        "\(kind) preparation is not supported on the resolved \(target) target; the reviewed profile requires a Debian-family Linux target"
    }
    static func runtimeComponentTargetMismatch(component: String, target: String, required: String) -> String {
        "runtime component \(component) is built for \(required), not the resolved \(target) target; nothing was staged"
    }
}

// MARK: - Guest package operations (concrete reuse of the existing verbs)

/// The exact per-family operations. Production uses
/// `LinuxGuestSkillDependencyPackageOperations`, which reuses the existing
/// managed pip service, the guest's own npm transaction and the single signed
/// apt-get transaction — no new installer, index, permission or alias.
protocol SkillDependencyPackageOperating: Sendable {
    /// ACTIVE venv-visible inventory (normalized name -> installed version),
    /// INCLUDING `--system-site-packages` inherited distributions. Success
    /// readback checks all active versions; conflicts are decided ONLY on
    /// owned pins (see pythonOwnedVenvVersions).
    func pythonInstalledVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String]
    /// Versions OWNED by the environment's writable venv layer. `nil` means
    /// the conformer cannot distinguish ownership and every ACTIVE pin is
    /// treated as owned (legacy behavior). A mismatching OWNED pin refuses
    /// before any mutation; an inherited system distribution at a different
    /// version never blocks — the reviewed pin is shadowed inside the venv
    /// through normal pip behavior, and the APT base is never touched.
    func pythonOwnedVenvVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String]?
    /// Managed pip install of the exact `name==version` spec; the returned
    /// text embeds the venv verification line. `hashes` are the signed lock's
    /// canonical sha256 digests for that exact spec: non-empty runs the
    /// guest's own pip in `--require-hashes` mode (digest-verified bytes, not
    /// just a version readback); empty keeps today's exact-version behavior.
    func pythonEnsure(spec: String, hashes: [String], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String
    /// Installs a signed lock's FULL pinned closure through the EXISTING
    /// managed installer in ONE call: every `name==version` spec carries its
    /// own lock digests, which pip's `--require-hashes` mode demands for every
    /// requirement it processes — installing only the root while discarding
    /// the hashed transitive entries would always refuse real closures
    /// (requests/urllib3/…). Default loops `pythonEnsure` per pin; production
    /// overrides it with the single managed transaction.
    func pythonInstallPins(_ pins: [(spec: String, hashes: [String])], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String
    /// dpkg readback of one Debian identity (nil when not installed).
    func aptInstalledVersion(identity: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String?
    /// The single `apt-get install -y --no-install-recommends name=version`
    /// transaction; the implementation MUST read the exact version back.
    func aptEnsure(identity: String, version: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String
    /// Environment-level node tree (name -> version).
    func nodeInstalledVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String]
    /// Exact `name@version` npm install with real tree readback (never a
    /// package-lock replay).
    func npmEnsure(spec: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String
    /// apt identity+version install for a font plus the fixed CJK probe.
    func fontEnsure(identity: String, version: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String
    /// Fixed CJK availability probe only (used when the exact pin is already
    /// installed; never installs, never mutates).
    func cjkProbePasses(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> Bool
}

extension SkillDependencyPackageOperating {
    /// Legacy default: ownership indistinguishable → every active pin is owned.
    func pythonOwnedVenvVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String]? {
        nil
    }

    /// Default per-pin loop; production overrides with the single managed
    /// closure transaction. Conformers that override this must NOT also be
    /// relied on through `pythonEnsure` for lock installs.
    func pythonInstallPins(_ pins: [(spec: String, hashes: [String])], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        var outputs: [String] = []
        for pin in pins {
            outputs.append(try await pythonEnsure(spec: pin.spec, hashes: pin.hashes, environment: environment, cancellation: cancellation))
        }
        return outputs.joined(separator: "\n")
    }
}

/// Production operations: every verb is the existing reviewed path.
struct LinuxGuestSkillDependencyPackageOperations: SkillDependencyPackageOperating {
    let managedPython: ManagedPythonInstallService
    let languagePackages: LinuxGuestLanguagePackages
    /// Already-mapped guest path of the shared official wheel store (same
    /// bytes the install-time prefetch persisted). `nil` keeps the managed
    /// pip command byte-for-byte what it is today.
    let wheelStoreGuestPath: String?

    init(managedPython: ManagedPythonInstallService, languagePackages: LinuxGuestLanguagePackages,
         wheelStoreGuestPath: String? = nil) {
        self.managedPython = managedPython
        self.languagePackages = languagePackages
        self.wheelStoreGuestPath = wheelStoreGuestPath
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
    }

    func pythonInstalledVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String] {
        let rows = try await languagePackages.pythonInventory(environment: environment, cancellation: cancellation)
        var map: [String: String] = [:]
        for row in rows { map[Self.normalized(row.name)] = row.version }
        return map
    }

    /// Ownership preserved from `LinuxGuestPythonDistribution.writable`: only
    /// distributions living in the environment's venv site-packages can
    /// conflict; `--system-site-packages` inherited rows stay in the ACTIVE
    /// map for reuse/shadow decisions only.
    func pythonOwnedVenvVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String]? {
        let rows = try await languagePackages.pythonInventory(environment: environment, cancellation: cancellation)
        var map: [String: String] = [:]
        for row in rows where row.writable { map[Self.normalized(row.name)] = row.version }
        return map
    }

    func pythonEnsure(spec: String, hashes: [String], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        try await Self.mapInstallOutcome(
            await managedPython.install(
                specs: [spec],
                timeout: 300,
                maxOutputBytes: 64 * 1024,
                findLinksGuestPath: wheelStoreGuestPath,
                hashesBySpec: hashes.isEmpty ? [:] : [spec: hashes],
                cancellation: cancellation,
                environment: environment
            )
        )
    }

    /// The FULL lock closure in ONE managed transaction: the guest's own pip
    /// `--require-hashes` mode then verifies every root and transitive wheel
    /// against its pinned digest (the store supplies canonical cached bytes;
    /// anything missing falls back to the bounded index download).
    func pythonInstallPins(_ pins: [(spec: String, hashes: [String])], environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        guard !pins.isEmpty else { return "" }
        var pinsBySpec: [String: [String]] = [:]
        for pin in pins where !pin.hashes.isEmpty { pinsBySpec[pin.spec] = pin.hashes }
        return try await Self.mapInstallOutcome(
            await managedPython.install(
                specs: pins.map(\.spec),
                timeout: 300,
                maxOutputBytes: 64 * 1024,
                findLinksGuestPath: wheelStoreGuestPath,
                hashesBySpec: pinsBySpec,
                cancellation: cancellation,
                environment: environment
            )
        )
    }

    private static func mapInstallOutcome(_ outcome: ManagedPythonInstallService.Outcome) throws -> String {
        switch outcome {
        case .ok(let output): return output
        case .failed(let message): throw FloeError.validationFailed(message)
        case .timedOut(let partial):
            throw FloeError.validationFailed("the managed pip install reached its budget: " + String(partial.suffix(400)))
        case .cancelled: throw CancellationError()
        }
    }

    func aptInstalledVersion(identity: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String? {
        try await languagePackages.aptReadback(identity: identity, environment: environment, cancellation: cancellation)
    }

    func aptEnsure(identity: String, version: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        _ = try await languagePackages.aptInstallExact(
            identity: identity, version: version, environment: environment, cancellation: cancellation
        )
        guard let installed = try await languagePackages.aptReadback(
            identity: identity, environment: environment, cancellation: cancellation
        ), installed == version else {
            throw FloeError.validationFailed("the guest dpkg readback did not confirm \(identity) at the pinned version")
        }
        return "dpkg \(installed)"
    }

    func nodeInstalledVersions(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> [String: String] {
        let rows = try await languagePackages.nodeInventory(environment: environment, cancellation: cancellation)
        var map: [String: String] = [:]
        for row in rows { map[row.name] = row.version }
        return map
    }

    func npmEnsure(spec: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        _ = try await languagePackages.nodeChange(
            environment: environment,
            specifications: [spec],
            remove: false,
            manager: .npm,
            timeout: 600,
            cancellation: cancellation
        )
        // Exact readback of the installed tree (never a package-lock replay).
        let name: String
        let want: String
        if let at = spec.lastIndex(of: "@") {
            name = String(spec[spec.startIndex..<at])
            want = String(spec[spec.index(after: at)...])
        } else {
            name = spec
            want = ""
        }
        let installed = try await languagePackages.nodeInventory(environment: environment, cancellation: cancellation)
        guard !want.isEmpty, installed.contains(where: { $0.name == name && $0.version == want }) else {
            throw FloeError.validationFailed("the node readback did not confirm \(spec) in the environment tree")
        }
        return "node \(name)@\(want)"
    }

    func fontEnsure(identity: String, version: String, environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> String {
        let evidence = try await aptEnsure(identity: identity, version: version, environment: environment, cancellation: cancellation)
        guard try await languagePackages.cjkFontProbe(environment: environment, cancellation: cancellation) else {
            throw FloeError.validationFailed("the pinned font installed but the fixed CJK availability probe did not pass")
        }
        return evidence + ", cjk-probe ok"
    }

    func cjkProbePasses(environment: ToolEnvironment, cancellation: CancellationToken?) async throws -> Bool {
        try await languagePackages.cjkFontProbe(environment: environment, cancellation: cancellation)
    }
}

// MARK: - Shared-store prefetch (install-time; download-only, host never runs
// package commands)

/// Prefetch states are deliberately NOT readiness. `verified` means the exact
/// pinned resource bytes were fetched host-side through an EXISTING reviewed
/// download client and hash/size-verified into app-owned storage; the
/// environment install + readback still runs only in the task's resolved
/// Linux guest. `awaitingTarget` means the kind can only resolve inside a
/// resolved task environment (guest sources/arch) or a seam is not wired.
/// One exact pinned wheel whose bytes were fetched and hash-verified
/// host-side by the existing managed inspector path (download-only; pip is
/// never run on the host). The center persists these bytes into the shared
/// official wheel store so first task install consumes them with no
/// redownload; a transient fetch with no store is never counted as prepared.
struct SkillDependencyWheelBundle: Sendable, Equatable {
    let spec: String
    let filename: String
    let sha256: String
    let size: Int
    let bytes: Data

    var isCanonical: Bool {
        spec.utf8.count <= 256
            && !filename.isEmpty && !filename.contains("/") && !filename.contains("..")
            && filename.hasSuffix(".whl")
            && size == bytes.count
            && size >= 1 && size <= 12 * 1_024 * 1024
            && SkillDependency.isCanonicalHex(sha256, length: 64)
            && FloeDigest.sha256Hex(bytes) == sha256
    }
}

enum SkillDependencyPrefetchState: String, Codable, Sendable {
    case verified
    case awaitingTarget
    case failed
}

struct SkillDependencyPrefetchEntry: Codable, Sendable, Equatable {
    let kind: String
    let name: String
    let version: String?
    let state: SkillDependencyPrefetchState
    /// Model-safe detail; never a host path or raw upstream error text.
    let detail: String?
}

/// Lock-protected publication of the two install-time seams that need the
/// fully initialized `AppEnvironment` (the GitHub-only transport and the
/// managed wheel auditor live there). Mirrors the component center's proven
/// late-binding pattern; unset seams keep prefetch honestly `awaitingTarget`.
final class SkillDependencyLateBindings: @unchecked Sendable {
    typealias ComponentTransport = @Sendable (_ owner: String, _ repository: String, _ ref: String, _ path: String) async throws -> Data

    private let lock = NSLock()
    private var transportBox: ComponentTransport?
    private var componentStoreRootBox: URL?

    init(componentTransport: ComponentTransport? = nil, componentStoreRoot: URL? = nil) {
        transportBox = componentTransport
        componentStoreRootBox = componentStoreRoot
    }

    func publish(transport: @escaping ComponentTransport, componentStoreRoot: URL) {
        lock.lock()
        transportBox = transport
        componentStoreRootBox = componentStoreRoot
        lock.unlock()
    }

    var componentTransport: ComponentTransport? { lock.lock(); defer { lock.unlock() }; return transportBox }
    var componentStoreRoot: URL? { lock.lock(); defer { lock.unlock() }; return componentStoreRootBox }
}

// MARK: - Center

/// Service-owned dependency preparation for official reviewed/signed installs.
actor SkillDependencyPreparationCenter {
    typealias LiveAuthorization = @Sendable (_ skillID: String) async -> SkillDependencyAuthority?
    typealias EnvironmentResolver = @Sendable (_ environmentID: String) async -> ToolEnvironment?
    typealias EnvironmentPreparation = @Sendable (_ environmentID: String, _ cancellation: CancellationToken?) async throws -> Void
    typealias LaunchGenerationProvider = @Sendable (_ environmentID: String) async -> UInt64?
    /// Trusted actual-target lookup (App/core-owned). A configured provider
    /// returning nil is final and must never fall back to a legacy target.
    typealias TargetProvider = @Sendable (_ environmentID: String, _ runID: UUID?) async -> SkillRuntimeTarget?
    /// Operations bound to the actual target. Returning nil refuses this
    /// target; Linux-guest operations are never used for a Mac/SSH target.
    typealias OperationsResolver = @Sendable (_ target: SkillRuntimeTarget)
        async -> (any SkillDependencyPackageOperating)?
    /// Connect/boot/prepare the actual target only (never installs packages,
    /// never picks another environment).
    typealias TargetPreparation = @Sendable (_ target: SkillRuntimeTarget, _ cancellation: CancellationToken?) async throws -> Void
    /// Observes the EXISTING allowlisted managed runtime-component deployment
    /// without broadening it: nil when the component is probed-ready for this
    /// environment/run, otherwise a model-safe deferral reason.
    typealias RuntimeComponentProbe = @Sendable (_ environmentID: String, _ runID: UUID, _ cancellation: CancellationToken?) async -> String?

    private struct PlanKey: Hashable { let environmentID: String; let runID: UUID; let skillID: String }
    private struct ReceiptKey: Hashable {
        let environmentID: String
        let requirementKey: String
        /// Foreign-target in-flight work/receipts never coalesce even under a
        /// reused environment id.
        let targetFingerprint: String
    }
    private struct StateKey: Hashable { let environmentID: String; let skillID: String }

    private struct Plan {
        let skillID: String
        let environmentID: String
        let runID: UUID
        let declaration: SkillDependencyDeclaration
        let authority: SkillDependencyAuthority
        /// Actual target identity captured by the verified read. Invoke
        /// re-resolves and refuses a changed target; a reboot keeps the plan
        /// but forces receipt re-verification through the generation.
        let target: SkillRuntimeTarget
        let recordedAt: Date
    }

    /// Synchronous cancellation mirror of one waiting subscriber (Swift-task
    /// cancellation flips it inside the wait's own handler before the waiter
    /// resumes — the same discipline as the proven component center).
    private final class WaiterCancelMirror: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
        }
    }

    private struct SubscriberDemand: Sendable {
        let token: CancellationToken?
        let mirror: WaiterCancelMirror
        var isCancelled: Bool { token?.isCancelled == true || mirror.isCancelled }
    }

    /// One coalesced per-requirement preparation with live subscriber
    /// accounting; generation-guarded so a departed waiter can never retire a
    /// newer preparation for the same identity.
    private struct Preparation {
        let generation: UUID
        let task: Task<SkillDependencyRequirementOutcome, Never>
        let token: CancellationToken
        var subscribers: [UUID: SubscriberDemand]
    }

    let authorityProvider: LiveAuthorization
    let environmentResolver: EnvironmentResolver
    let prepareEnvironment: EnvironmentPreparation?
    let launchGenerationProvider: LaunchGenerationProvider
    let operations: (any SkillDependencyPackageOperating)?
    let targetProvider: TargetProvider?
    let operationsResolver: OperationsResolver?
    let targetPreparation: TargetPreparation?
    let runtimeComponentProbe: RuntimeComponentProbe?
    let lateBindings: SkillDependencyLateBindings
    private let appVersion: @Sendable () -> String
    private let persistenceRoot: URL?
    /// Exact-pinned wheel bytes are fetched through the existing managed
    /// inspector path (download-only) and persisted into the shared official
    /// wheel store; `wheelStoreGuestPath` is that same store's already-mapped
    /// path so the task's managed pip consumes cached bytes via `--find-links`
    /// with zero redownload. Absent pieces stay honestly `awaitingTarget`.
    let pipWheels: (@Sendable ([String]) async throws -> [SkillDependencyWheelBundle])?
    let wheelStoreURL: URL?
    let wheelStoreGuestPath: String?
    /// Architectures the ACTUAL local Linux backend executes (the pinned
    /// TinyEMU guest is riscv64 — never the native Mac CPU, which would let
    /// arm64-labelled profiles mutate this guest). Injectable for tests and
    /// future backends; profiles whose target does not intersect this set
    /// are filtered before any plan, prefetch or mutation.
    let localLinuxArchitectures: [String]

    private var plans: [PlanKey: Plan] = [:]
    private var receipts: [ReceiptKey: SkillDependencyRequirementReceipt] = [:]
    private var states: [StateKey: SkillDependencyState] = [:]
    private var preparations: [ReceiptKey: Preparation] = [:]
    private var pendingSharedPreparation: [String: String] = [:]

    init(
        authorityProvider: @escaping LiveAuthorization,
        environmentResolver: @escaping EnvironmentResolver,
        launchGeneration: @escaping LaunchGenerationProvider,
        operations: (any SkillDependencyPackageOperating)?,
        prepareEnvironment: EnvironmentPreparation? = nil,
        runtimeComponentProbe: RuntimeComponentProbe? = nil,
        targetProvider: TargetProvider? = nil,
        operationsResolver: OperationsResolver? = nil,
        targetPreparation: TargetPreparation? = nil,
        pipWheels: (@Sendable ([String]) async throws -> [SkillDependencyWheelBundle])? = nil,
        wheelStoreURL: URL? = nil,
        wheelStoreGuestPath: String? = nil,
        appVersion: @escaping @Sendable () -> String = { "0.0.0" },
        bindings: SkillDependencyLateBindings = SkillDependencyLateBindings(),
        persistenceRoot: URL?,
        localLinuxArchitectures: [String] = ["riscv64"]
    ) {
        self.authorityProvider = authorityProvider
        self.environmentResolver = environmentResolver
        self.launchGenerationProvider = launchGeneration
        self.operations = operations
        self.targetProvider = targetProvider
        self.operationsResolver = operationsResolver
        self.targetPreparation = targetPreparation
        self.prepareEnvironment = prepareEnvironment
        self.runtimeComponentProbe = runtimeComponentProbe
        self.appVersion = appVersion
        self.lateBindings = bindings
        self.persistenceRoot = persistenceRoot
        self.pipWheels = pipWheels
        self.wheelStoreURL = wheelStoreURL
        self.wheelStoreGuestPath = wheelStoreGuestPath
        // Injected backend fact (default = the pinned TinyEMU RISC-V guest).
        // An explicitly EMPTY set fails closed: `profileMatches` refuses every
        // target until a real architecture is known — never a silent guess.
        self.localLinuxArchitectures = localLinuxArchitectures
    }

    /// Publishes the install-time prefetch seams after phase-1 completes
    /// (nonisolated; callable from synchronous init contexts).
    nonisolated func setLateBindings(
        transport: @escaping SkillDependencyLateBindings.ComponentTransport,
        componentStoreRoot: URL
    ) {
        lateBindings.publish(transport: transport, componentStoreRoot: componentStoreRoot)
    }

    // MARK: - Profile target matching (original declaration contract)

    /// The profile `target.architectures` field is part of the ORIGINAL
    /// declaration contract, so it must be SELECTED, not ignored: a profile
    /// only participates when its OS and architectures intersect the ACTUAL
    /// target ("any" always participates).
    ///
    /// Legacy overload used ONLY by the pre-integration fallback and the
    /// unbound shared prefetch. It keeps the historical Linux/riscv64 fact.
    nonisolated static func profileMatches(_ profile: SkillDependencyProfile, architectures supported: [String]) -> Bool {
        guard profile.os == "linux", !supported.isEmpty else { return false }
        return profile.architectures.contains("any")
            || !Set(profile.architectures.map(SkillRuntimeTarget.normalizeArchitecture))
                .isDisjoint(with: supported.map(SkillRuntimeTarget.normalizeArchitecture))
    }

    /// Actual-target matching: v1 Linux or v2 Linux/macOS profiles use the
    /// verified system/architecture. App-native execution matches nothing.
    nonisolated static func profileMatches(_ profile: SkillDependencyProfile, target: SkillRuntimeTarget) -> Bool {
        guard target.isResolved, target.hasExternalExecution,
              let os = target.profileOS, profile.os == os else { return false }
        let supported = target.normalizedArchitectures
        guard !supported.isEmpty else { return false }
        return profile.architectures.contains("any")
            || !Set(profile.architectures.map(SkillRuntimeTarget.normalizeArchitecture))
                .isDisjoint(with: supported)
    }

    func matchingProfiles(_ declaration: SkillDependencyDeclaration) -> [SkillDependencyProfile] {
        declaration.profiles.filter { Self.profileMatches($0, architectures: localLinuxArchitectures) }
    }

    func matchingProfiles(
        _ declaration: SkillDependencyDeclaration,
        target: SkillRuntimeTarget
    ) -> [SkillDependencyProfile] {
        declaration.profiles.filter { Self.profileMatches($0, target: target) }
    }

    /// Cross-profile overlap check over the matching profiles: the SAME
    /// requirement identity pinned to DIFFERENT exact versions is ambiguous
    /// and must refuse BEFORE any install transaction; identical exact
    /// duplicates across profiles are reuse (the inventory-first verbs make
    /// the second one verify without mutation), never a conflict.
    nonisolated static func crossProfileConflict(in profiles: [SkillDependencyProfile])
        -> (identity: String, first: String, second: String)? {
        var seen: [String: String] = [:]
        for profile in profiles {
            for requirement in profile.requirements {
                guard let version = requirement.version else { continue }
                let key = requirement.kind == .pip
                    ? "pip:" + normalizedPip(requirement.name)
                    : requirement.identityKey.lowercased()
                if let prior = seen[key], prior != version {
                    return (requirement.identityKey, prior, version)
                }
                if seen[key] == nil { seen[key] = version }
            }
        }
        return nil
    }

    /// Resolve the ACTUAL target. With no injected provider the legacy
    /// in-process fact is used (tests/pre-integration). Once a provider is
    /// injected, nil is final: there is no fallback to the Mac host or the
    /// first environment.
    private func resolveTarget(environmentID: String, runID: UUID?) async -> SkillRuntimeTarget? {
        if let targetProvider {
            return await targetProvider(environmentID, runID)
        }
        return .legacyLinuxGuest(
            environmentID: environmentID,
            architectures: localLinuxArchitectures
        )
    }

    /// Operations bound to the actual target. Linux-guest verbs are reused
    /// only for a Linux VM target; a Mac bridge/SSH target with no injected
    /// resolver returns nil (refusal), never the guest adapter.
    private func operationsForTarget(_ target: SkillRuntimeTarget) async -> (any SkillDependencyPackageOperating)? {
        if let operationsResolver { return await operationsResolver(target) }
        if targetProvider == nil { return operations }
        if target.backend == .linuxVM, target.operatingSystem == .linux { return operations }
        return nil
    }

    /// One requirement's target support. Package-manager kinds are checked
    /// against the actual OS/distribution; the frozen runtime component is
    /// cross-checked against its descriptor target.
    nonisolated static func targetRefusal(
        requirement: SkillDependencyRequirement,
        target: SkillRuntimeTarget,
        authority: SkillDependencyAuthority?
    ) -> String? {
        switch requirement.kind {
        case .apt, .font:
            guard target.supportsDebianAPT else {
                return SkillDependencyReason.unsupportedPackageManager(
                    kind: requirement.kind.rawValue, target: target.runtimeDescription
                )
            }
        case .pip, .npm:
            guard target.supportsPackageManager(requirement.kind.rawValue) else {
                return SkillDependencyReason.unsupportedPackageManager(
                    kind: requirement.kind.rawValue, target: target.runtimeDescription
                )
            }
        case .runtimeComponent:
            guard let path = requirement.componentDescriptorPath,
                  let bytes = authority?.packageFiles[path],
                  let descriptor = try? SkillRuntimeDependency.decode(bytes) else {
                return SkillDependencyReason.declarationRejected
            }
            let descriptorArch = SkillRuntimeTarget.normalizeArchitecture(descriptor.target.arch)
            guard let targetOS = target.profileOS, targetOS == descriptor.target.os,
                  target.normalizedArchitectures.contains(descriptorArch) else {
                return SkillDependencyReason.runtimeComponentTargetMismatch(
                    component: descriptor.componentID,
                    target: target.runtimeDescription,
                    required: "\(descriptor.target.os) \(descriptor.target.arch)"
                )
            }
        }
        return nil
    }

    /// The shared pre-mutation target validation used by recordPlan and
    /// invoke: the actual target must exist and support external execution;
    /// at least one reviewed profile must match its OS/architecture/package
    /// manager facts; matching profiles must not contradict exact pins.
    private func targetValidation(
        _ declaration: SkillDependencyDeclaration,
        target: SkillRuntimeTarget?,
        authority: SkillDependencyAuthority?
    ) -> String? {
        guard let target, target.isResolved else {
            return SkillDependencyReason.targetUnavailable
        }
        guard target.hasExternalExecution else {
            return SkillDependencyReason.targetUnsupported
        }
        let matching = matchingProfiles(declaration, target: target)
        guard !matching.isEmpty else {
            if targetProvider == nil {
                return SkillDependencyReason.noMatchingProfile(architectures: localLinuxArchitectures)
            }
            return SkillDependencyReason.noMatchingTarget(
                os: target.profileOS ?? target.runtimeDescription,
                architectures: target.normalizedArchitectures
            )
        }
        if let clash = Self.crossProfileConflict(in: matching) {
            return SkillDependencyReason.profileConflict(
                name: clash.identity, first: clash.first, second: clash.second
            )
        }
        for profile in matching {
            for requirement in profile.requirements where requirement.required {
                if let reason = Self.targetRefusal(
                    requirement: requirement, target: target, authority: authority
                ) {
                    return reason
                }
            }
        }
        return nil
    }

    // MARK: - Install half (service-owned persistence; never a ready token)

    /// Called by the official install paths after a canonical curated commit.
    /// Strict-decodes the declaration from the live authority bytes and
    /// persists a non-authoritative ownership record (digests + identity).
    /// Installs nothing — global UI install has no run/environment, so this
    /// half can only ever say "installed/verified", never "packages ready".
    @discardableResult
    func declareInstalledPackage(skillID: String) async -> SkillDependencyDeclaration? {
        guard let authority = await authorityProvider(skillID),
              Self.isFormallyValid(authority) else {
            return nil
        }
        guard let declaration = try? Self.decodeAndValidate(authority) else {
            return nil
        }
        persistDeclarationRecord(for: authority)
        return declaration
    }

    /// Install-boundary half of the contract. Official installs call this:
    /// the declaration is always strict-decoded and the ownership record
    /// persisted (service-owned). Where the install itself is bound to a
    /// resolved task environment (the tool path), the shared resource
    /// preparation runs automatically IN THAT actual target now — coalesced
    /// downloads into the environment's shared `/floe/cache`, per-family
    /// installs and exact readback — so the first ordinary task invocation
    /// later reuses verified receipts instead of starting from zero. A
    /// global-UI install has no task environment: nothing is faked ready;
    /// the deferral is recorded honestly and preparation runs at the first
    /// use bound to a resolved Linux environment. Selection is never ambient:
    /// only the environment the installing run already owns is used.
    @discardableResult
    func prepareAtInstall(
        skillID: String,
        environmentID: String?,
        runID: UUID?,
        cancellation: CancellationToken?
    ) async -> SkillDependencyInvocationOutcome? {
        guard let authority = await authorityProvider(skillID),
              Self.isFormallyValid(authority) else {
            return .refused(reason: SkillDependencyReason.authorizationUnavailable)
        }
        let declaration: SkillDependencyDeclaration
        do {
            declaration = try Self.decodeAndValidate(authority)
        } catch let error as SkillDependencyError {
            if case .unsupportedSchemaVersion = error {
                return .refused(reason: SkillDependencyReason.unsupportedSchema)
            }
            return .refused(reason: SkillDependencyReason.declarationRejected)
        } catch {
            return .refused(reason: SkillDependencyReason.declarationRejected)
        }
        persistDeclarationRecord(for: authority)
        let trimmedEnvironmentID = environmentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let environmentID = trimmedEnvironmentID, !environmentID.isEmpty, let runID else {
            // Global / unbound official install: prepare the shared store now
            // for every kind that resolves host-side (download-only, no
            // package commands), persist the honest status across views and
            // restarts, and defer the environment half explicitly.
            let entries = await prefetchSharedResources(
                skillID: skillID, authority: authority, declaration: declaration
            )
            persistDeclarationRecord(for: authority, prefetch: entries)
            pendingSharedPreparation[skillID] = SkillDependencyReason.sharedPreparationDeferred(skillID: skillID)
            return nil
        }
        pendingSharedPreparation[skillID] = nil
        persistDeclarationRecord(for: authority)
        let plan = await recordPlan(
            skillID: skillID,
            environmentID: environmentID,
            runID: runID,
            authority: authority
        )
        if case .rejected(let reason) = plan { return .refused(reason: reason) }
        return await invoke(
            skillID: skillID,
            environmentID: environmentID,
            runID: runID,
            cancellation: cancellation
        )
    }

    /// Honest "installed/verified, packages not yet prepared" marker for the
    /// skill.read footer and diagnostics. Never a ready token.
    func pendingSharedPreparationReason(skillID: String) -> String? {
        pendingSharedPreparation[skillID]
    }

    /// Ownership records only. Never deletes installed apt/pip/npm packages —
    /// explicit environment-package removal stays a user action elsewhere.
    func forgetSkill(_ skillID: String) async {
        plans = plans.filter { $0.value.skillID != skillID }
        receipts = receipts.filter { $0.value.skillID != skillID }
        states = states.filter { $0.key.skillID != skillID }
        pendingSharedPreparation[skillID] = nil
        let prefix = skillID + "|"
        let owned = preparations.filter { $0.key.requirementKey.hasPrefix(prefix) }
        for (key, entry) in owned {
            if preparations[key]?.generation == entry.generation {
                preparations[key] = nil
            }
        }
        for (_, entry) in owned {
            entry.token.cancel()
            entry.task.cancel()
        }
        for (_, entry) in owned {
            _ = await entry.task.value
        }
        if let root = persistenceRoot {
            try? FileManager.default.removeItem(at: Self.recordURL(root: root, skillID: skillID))
        }
    }

    // MARK: - Plan recording (verified exact read; never installs)

    /// Records an immutable (environmentID, runID)-bound plan pinning the
    /// package version + contentDigest + declaration digest. Rejects
    /// bytes-only "authority"; downloads and installs nothing.
    func recordPlan(
        skillID: String,
        environmentID: String?,
        runID: UUID?,
        authority: SkillDependencyAuthority?
    ) async -> SkillDependencyPlanOutcome {
        guard let environmentID = environmentID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !environmentID.isEmpty else {
            return .rejected(reason: SkillDependencyReason.noEnvironment)
        }
        guard let runID else { return .rejected(reason: SkillDependencyReason.noRun) }
        guard let authority, Self.isFormallyValid(authority), authority.skillID == skillID else {
            setState(environmentID, skillID) { $0.deferredReason = SkillDependencyReason.authorizationUnavailable }
            return .rejected(reason: SkillDependencyReason.authorizationUnavailable)
        }
        let declaration: SkillDependencyDeclaration
        do {
            declaration = try Self.decodeAndValidate(authority)
        } catch let error as SkillDependencyError {
            if case .unsupportedSchemaVersion = error {
                setState(environmentID, skillID) { $0.deferredReason = SkillDependencyReason.unsupportedSchema }
                return .rejected(reason: SkillDependencyReason.unsupportedSchema)
            }
            setState(environmentID, skillID) { $0.deferredReason = SkillDependencyReason.declarationRejected }
            return .rejected(reason: SkillDependencyReason.declarationRejected)
        } catch {
            setState(environmentID, skillID) { $0.deferredReason = SkillDependencyReason.declarationRejected }
            return .rejected(reason: SkillDependencyReason.declarationRejected)
        }
        // Target contract is validated at the earliest honest point: the
        // plan is pinned to the ACTUAL target identity, and a declaration that
        // cannot run there (or whose matching profiles contradict each other)
        // is refused before any invocation, prefetch or mutation.
        let target = await resolveTarget(environmentID: environmentID, runID: runID)
        if let refusal = targetValidation(declaration, target: target, authority: authority) {
            setState(environmentID, skillID) { $0.deferredReason = refusal }
            return .rejected(reason: refusal)
        }
        guard let target else {
            setState(environmentID, skillID) { $0.deferredReason = SkillDependencyReason.targetUnavailable }
            return .rejected(reason: SkillDependencyReason.targetUnavailable)
        }
        plans[PlanKey(environmentID: environmentID, runID: runID, skillID: skillID)] = Plan(
            skillID: skillID,
            environmentID: environmentID,
            runID: runID,
            declaration: declaration,
            authority: authority,
            target: target,
            recordedAt: Date()
        )
        setState(environmentID, skillID) {
            $0.planRecorded = true
            $0.sourceAuthorized = true
            $0.deferredReason = nil
        }
        persistDeclarationRecord(for: authority)
        return .recorded(environmentID: environmentID, runID: runID)
    }

    // MARK: - Shared-store prefetch at official install

    /// Download-only preparation of everything the install boundary can
    /// honestly prepare WITHOUT a task environment, reusing existing reviewed
    /// clients: pip pins through the managed pure-wheel auditor (PyPI JSON +
    /// exact wheel bytes, sha256/size verified, native rejected — no package
    /// command ever runs on the host), runtime components through the
    /// GitHub-only transport into the SAME app-owned cache namespace as the
    /// component center (exact size + sha256 + static-ELF gate, atomic commit,
    /// verified reuse on first use). apt/npm/font identities resolve only
    /// inside a real guest (configured sources + architecture), so they get an
    /// explicit `awaitingTarget` state. Nothing here claims readiness; the
    /// environment install + readback still runs at the skill's first approved
    /// invocation, and no environment is ever picked or faked.
    private func prefetchSharedResources(
        skillID: String,
        authority: SkillDependencyAuthority,
        declaration: SkillDependencyDeclaration
    ) async -> [SkillDependencyPrefetchEntry] {
        var entries: [SkillDependencyPrefetchEntry] = []
        var seenPipSpecs = Set<String>()
        let matchingIDs = Set(matchingProfiles(declaration).map(\.id))
        for profile in declaration.profiles {
            // Global prefetch is for the relevant LOCAL profiles only: a
            // profile that does not target this Linux backend's architecture
            // records the honest skip and never downloads.
            guard matchingIDs.contains(profile.id) else {
                for requirement in profile.requirements {
                    entries.append(SkillDependencyPrefetchEntry(
                        kind: requirement.kind.rawValue, name: requirement.name, version: requirement.version,
                        state: .awaitingTarget,
                        detail: SkillDependencyReason.nonMatchingArchSkipped(
                            architectures: profile.architectures, supported: localLinuxArchitectures
                        )
                    ))
                }
                continue
            }
            for requirement in profile.requirements {
                switch requirement.kind {
                case .pip:
                    guard let spec = requirement.pipSpec else { continue }
                    // Dedup happens per CLOSURE MEMBER inside (root and every
                    // transitive), so the same shared transitive across two
                    // locked requirements is persisted once.
                    entries.append(contentsOf: await prefetchWheel(
                        spec: spec, requirement: requirement, authority: authority,
                        seenPipSpecs: &seenPipSpecs
                    ))
                case .runtimeComponent:
                    entries.append(await prefetchComponentArtifact(authority: authority))
                case .apt, .npm, .font:
                    entries.append(SkillDependencyPrefetchEntry(
                        kind: requirement.kind.rawValue, name: requirement.name, version: requirement.version,
                        state: .awaitingTarget,
                        detail: requirement.kind == .npm
                            ? "npm resolves against the guest registry only; exact name@version install + real tree readback run in the task's resolved Linux environment"
                            : "Debian sources/architecture resolve only inside the task's resolved Linux guest; the exact pin installs and reads back at the skill's exec.shell invocation"
                    ))
                }
            }
        }
        return entries
    }

    /// Persist the exact pinned wheel's VERIFIED BYTES in the shared official
    /// wheel store under its REAL canonical PEP 427 basename — pip's
    /// `--find-links` directory scan only sees files whose NAME is a valid
    /// wheel name, so an invented basename would hold bytes nothing can ever
    /// consume. A declared lock is a FULL pinned closure: root and every
    /// transitive wheel are each fetched, digest-bound to their OWN lock
    /// pins, and persisted the same way. Alongside each wheel lives a
    /// bounded binding sidecar (`spec + filename + sha256 + size`); reuse
    /// re-reads the actual bytes, recomputes the digest and re-checks the
    /// binding, the filename shape and the size. Anything stale or foreign
    /// is replaced or refused, never trusted by name. Without a wired
    /// fetcher or store the state stays honestly `awaitingTarget` — a
    /// transient audit is never labeled "resource prepared".
    private func prefetchWheel(
        spec: String,
        requirement: SkillDependencyRequirement,
        authority: SkillDependencyAuthority,
        seenPipSpecs: inout Set<String>
    ) async -> [SkillDependencyPrefetchEntry] {
        var closure: [String: [String]]? = nil
        if let lockPath = requirement.lockfile {
            guard let lockBytes = authority.packageFiles[lockPath] else {
                return [SkillDependencyPrefetchEntry(
                    kind: "pip", name: requirement.name, version: requirement.version,
                    state: .failed, detail: SkillDependencyReason.declarationRejected
                )]
            }
            guard let parsed = Self.pipLockClosure(bytes: lockBytes) else {
                return [SkillDependencyPrefetchEntry(
                    kind: "pip", name: requirement.name, version: requirement.version,
                    state: .failed, detail: SkillDependencyReason.lockSyntaxRejected(name: requirement.name)
                )]
            }
            guard Self.pipLockCovers(parsed, name: requirement.name, version: requirement.version ?? "") else {
                return [SkillDependencyPrefetchEntry(
                    kind: "pip", name: requirement.name, version: requirement.version,
                    state: .failed, detail: SkillDependencyReason.lockUnpinned(name: requirement.name)
                )]
            }
            closure = parsed
        }
        let members: [(spec: String, hashes: [String]?)]
        if let closure {
            members = closure.keys.sorted().map { key in (key, closure[key]) }
        } else {
            members = [(spec, nil)]
        }
        var entries: [SkillDependencyPrefetchEntry] = []
        for member in members {
            if let entry = await prefetchWheelMember(
                memberSpec: member.spec,
                lockHashes: member.hashes,
                requirement: requirement,
                seenPipSpecs: &seenPipSpecs
            ) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// One closure member through the existing trusted fetch/persist path.
    /// Returns nil only when this exact spec was already prefetched by an
    /// earlier requirement (duplicate members never redownload or double-
    /// report).
    private func prefetchWheelMember(
        memberSpec: String,
        lockHashes: [String]?,
        requirement: SkillDependencyRequirement,
        seenPipSpecs: inout Set<String>
    ) async -> SkillDependencyPrefetchEntry? {
        guard seenPipSpecs.insert(memberSpec).inserted else { return nil }
        let isRoot = memberSpec.caseInsensitiveCompare(requirement.pipSpec ?? "") == .orderedSame
        let displayName: String
        let displayVersion: String?
        if isRoot {
            displayName = requirement.name
            displayVersion = requirement.version
        } else {
            let parsed = Self.specNameVersion(memberSpec)
            displayName = parsed.name
            displayVersion = parsed.version
        }
        func entry(_ state: SkillDependencyPrefetchState, _ detail: String) -> SkillDependencyPrefetchEntry {
            SkillDependencyPrefetchEntry(
                kind: "pip", name: displayName, version: displayVersion,
                state: state,
                detail: isRoot ? detail : "transitive closure member of \(requirement.name) — \(detail)"
            )
        }
        guard let storeURL = wheelStoreURL else {
            guard pipWheels != nil else {
                return entry(.awaitingTarget, "host wheel fetch not wired in this build; exact pin verifies during environment install/readback")
            }
            return entry(.awaitingTarget, "wheel bytes verify transiently only; persistent shared wheel store not wired, so nothing is counted prepared")
        }
        if let cached = Self.cachedWheelBinding(storeURL: storeURL, spec: memberSpec) {
            if let lockHashes, !lockHashes.contains(cached.binding.sha256) {
                // The persisted wheel contradicts the signed lock: pip must
                // never be handed it through --find-links.
                Self.removeWheelBinding(storeURL: storeURL, wheelURL: cached.url, binding: cached.binding)
            } else {
                return entry(.verified, "verified wheel bytes already present in the shared official store under their canonical wheel name (digest-reverified against the recorded binding; no download)")
            }
        }
        guard let pipWheels else {
            return entry(.awaitingTarget, "host wheel fetch not wired in this build; exact pin verifies during environment install/readback")
        }
        let bundle: SkillDependencyWheelBundle
        do {
            let bundles = try await pipWheels([memberSpec])
            guard let fetched = bundles.first(where: { $0.spec.caseInsensitiveCompare(memberSpec) == .orderedSame }),
                  fetched.isCanonical else {
                return entry(.failed, "the fetched wheel did not match the exact reviewed pin's digest/size")
            }
            bundle = fetched
        } catch is CancellationError {
            return entry(.failed, "prefetch was cancelled")
        } catch {
            return entry(.failed, "the exact reviewed wheel could not be fetched/persisted: " + String(error.localizedDescription.prefix(160)))
        }
        if let lockHashes, !lockHashes.contains(bundle.sha256) {
            return entry(.failed, "the fetched wheel's digest is not pinned by the signed lock; a silent different artifact is refused")
        }
        let nameVersion = Self.specNameVersion(memberSpec)
        guard let pin = nameVersion.version,
              Self.isCanonicalWheelFilename(bundle.filename, name: nameVersion.name, version: pin) else {
            return entry(.failed, SkillDependencyReason.wheelNameRejected(spec: memberSpec))
        }
        let binding = WheelStoreBinding(spec: memberSpec, filename: bundle.filename, sha256: bundle.sha256, size: bundle.size)
        do {
            try Self.persistWheelBinding(storeURL: storeURL, bundle: bundle, binding: binding)
        } catch {
            return entry(.failed, "committing the verified wheel into the shared store failed")
        }
        return entry(.verified, "verified wheel bytes persisted in the shared official store under the canonical wheel name; the task's managed pip consumes them through the mapped --find-links path with no redownload, and a signed lock install runs the FULL closure in pip's own --require-hashes mode (missing/evicted bytes fall back to the bounded index download)")
    }

    nonisolated static func specNameVersion(_ spec: String) -> (name: String, version: String?) {
        guard let separator = spec.range(of: "==") else { return (spec, nil) }
        return (String(spec[spec.startIndex..<separator.lowerBound]), String(spec[separator.upperBound...]))
    }

    // MARK: - Shared wheel store (canonical names + bounded binding sidecars)

    /// One persisted wheel's own record: the exact spec, the REAL wheel file
    /// name, the digest and the size. Never trusted as a marker — reuse
    /// always re-hashes the bytes; but it is what makes the cache CONSUMABLE
    /// (pip scans the canonical `.whl` itself) and auditable.
    struct WheelStoreBinding: Codable, Equatable, Sendable {
        let spec: String
        let filename: String
        let sha256: String
        let size: Int
    }

    nonisolated static func wheelDirectory(in storeURL: URL) -> URL {
        // The wiring passes the shared pip cache ROOT (exported into the
        // guest as /floe/cache/pip); the store adds exactly one
        // official-wheels level so --find-links stays
        // /floe/cache/pip/official-wheels. A root that already IS that
        // directory never gets a doubled level.
        storeURL.lastPathComponent == "official-wheels"
            ? storeURL
            : storeURL.appendingPathComponent("official-wheels", isDirectory: true)
    }

    /// `<canonical>.whl.floebinding` — pip's find-links scan only recognizes
    /// `*.whl` files, so the sidecar sits beside the wheel without becoming
    /// visible to it.
    nonisolated static func wheelBindingURL(for wheelURL: URL) -> URL {
        wheelURL.appendingPathExtension("floebinding")
    }

    /// Locate and FULLY re-validate the persisted binding for the exact spec
    /// (case-insensitive pin equality): decoded sidecar within size bound,
    /// canonical wheel basename re-derived from the binding spec, wheel file
    /// present with the recorded size and the recomputed digest equal to the
    /// recorded sha256. Any stale/damaged pair reads as absent and is
    /// replaced by the next successful fetch.
    nonisolated static func cachedWheelBinding(storeURL: URL, spec: String) -> (url: URL, binding: WheelStoreBinding, bytes: Data)? {
        let directory = wheelDirectory(in: storeURL)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              names.count <= 2_048 else { return nil }
        for name in names where name.hasSuffix(".whl.floebinding") {
            let bindingURL = directory.appendingPathComponent(name)
            guard let data = try? Data(floeContentsOf: bindingURL), data.count <= 4 * 1024,
                  let binding = try? JSONDecoder().decode(WheelStoreBinding.self, from: data),
                  binding.spec.caseInsensitiveCompare(spec) == .orderedSame,
                  binding.filename.hasSuffix(".whl"),
                  !binding.filename.contains("/"), !binding.filename.contains("\\"),
                  !binding.filename.contains(".."),
                  SkillDependency.isCanonicalHex(binding.sha256, length: 64),
                  binding.size >= 1, binding.size <= 12 * 1_024 * 1024
            else { continue }
            guard let pinSplit = binding.spec.range(of: "==") else { continue }
            let declaredName = String(binding.spec[binding.spec.startIndex..<pinSplit.lowerBound])
            let declaredVersion = String(binding.spec[pinSplit.upperBound...])
            guard isCanonicalWheelFilename(binding.filename, name: declaredName, version: declaredVersion) else { continue }
            let wheelURL = directory.appendingPathComponent(binding.filename)
            guard let bytes = try? Data(floeContentsOf: wheelURL),
                  bytes.count == binding.size,
                  wheelBytesValid(bytes, expectedSHA256: binding.sha256) else { continue }
            return (wheelURL, binding, bytes)
        }
        return nil
    }

    /// Atomically (re)write the wheel under its canonical name plus its
    /// binding sidecar; an existing different artifact at the same name is
    /// replaced only AFTER the new bytes pass the read-back digest check.
    nonisolated static func persistWheelBinding(storeURL: URL, bundle: SkillDependencyWheelBundle, binding: WheelStoreBinding) throws {
        let directory = wheelDirectory(in: storeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = directory.appendingPathComponent(binding.filename)
        let temporary = stored.appendingPathExtension("tmp-\(UUID().uuidString)")
        try bundle.bytes.write(to: temporary, options: .atomic)
        let reread = try Data(floeContentsOf: temporary)
        guard wheelBytesValid(reread, expectedSHA256: binding.sha256), reread.count == binding.size else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        let bindingData = try JSONEncoder().encode(binding)
        if FileManager.default.fileExists(atPath: stored.path) {
            try FileManager.default.removeItem(at: stored)
        }
        try FileManager.default.moveItem(at: temporary, to: stored)
        try bindingData.write(to: wheelBindingURL(for: stored), options: .atomic)
    }

    /// Remove a contradicted wheel + sidecar pair so pip's find-links scan
    /// can never pick up an artifact that broke its own binding/lock.
    nonisolated static func removeWheelBinding(storeURL: URL, wheelURL: URL, binding: WheelStoreBinding) {
        let expected = wheelDirectory(in: storeURL).appendingPathComponent(binding.filename)
        guard wheelURL.standardizedFileURL.path == expected.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: wheelURL)
        try? FileManager.default.removeItem(at: wheelBindingURL(for: wheelURL))
    }

    /// PEP 427 shape + PIN check: `{name}-{version}(-{build})?-{python}-{abi}-
    /// {platform}.whl`, five or six dash-separated components, a `-none-any`
    /// tag tail (this pipeline only ever accepts platform-independent
    /// wheels), an empty-safe distribution, the distribution component
    /// canonicalizing to the pinned name and the version component equal to
    /// the pinned version. No path separators, no `..`, bounded length.
    nonisolated static func isCanonicalWheelFilename(_ filename: String, name: String, version: String) -> Bool {
        guard !filename.isEmpty, filename.utf8.count <= 255,
              filename.hasSuffix("-none-any.whl"),
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("..")
        else { return false }
        let stem = String(filename.dropLast(4))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 || parts.count == 6 else { return false }
        let distribution = String(parts[0])
        let fileVersion = String(parts[1])
        guard !distribution.isEmpty,
              distribution.range(of: "^[A-Za-z0-9][A-Za-z0-9._]*$", options: .regularExpression) != nil,
              !fileVersion.isEmpty else { return false }
        var tagStart = 2
        if parts.count == 6 {
            guard parts[2].allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            tagStart = 3
        }
        let tags = Array(parts[tagStart...])
        guard tags.count == 3, tags.allSatisfy({ !$0.isEmpty }) else { return false }
        return normalizedPip(distribution) == normalizedPip(name) && fileVersion == version
    }

    /// Decode a signed pip wheel lock as its FULL pinned closure. Accepts
    /// ONLY hash-mode lines: `name==version` (+ optional bracketed extras
    /// forbidden) followed by one or more `--hash=sha256:<64hex>`, with
    /// backslash continuations and `#` comments. Operators/ranges (`>=`,
    /// `~=`, `!=`…), bare names, URLs/paths, `-r/--requirement`,
    /// `--index-url`, any other flag, an entry WITHOUT a sha256 pin, or the
    /// same normalized name at two different versions all return nil —
    /// guessing is refused, because a partial closure would make the guest's
    /// own `--require-hashes` transaction (which verifies EVERY processed
    /// requirement, transitives included) impossible. Keys are the canonical
    /// `name==version` strings pip consumes; same-spec duplicates merge their
    /// digest sets.
    nonisolated static func pipLockClosure(bytes: Data) -> [String: [String]]? {
        guard bytes.count <= 512 * 1024 else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        var statements: [String] = []
        var buffer = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasSuffix("\\") {
                buffer += String(line.dropLast()) + " "
                continue
            }
            buffer += line
            statements.append(buffer)
            buffer = ""
        }
        if !buffer.isEmpty { statements.append(buffer) }
        guard !statements.isEmpty else { return nil }
        var closure: [String: [String]] = [:]
        var nameToVersion: [String: String] = [:]
        for statement in statements {
            let tokens = statement.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let requirement = tokens.first, !requirement.hasPrefix("-") else { return nil }
            // EXACT `name==version` only: reject other operators outright.
            for forbidden in [">=", "<=", "~=", "!=", "===", "<", ">"] where requirement.contains(forbidden) {
                return nil
            }
            guard let separator = requirement.range(of: "==") else { return nil }
            let name = String(requirement[requirement.startIndex..<separator.lowerBound])
            let version = String(requirement[separator.upperBound...])
            guard !version.isEmpty,
                  requirement.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*==[0-9][0-9A-Za-z.!+~-]*$"#, options: .regularExpression) != nil else {
                return nil
            }
            let normalized = normalizedPip(name)
            var digests: [String] = []
            for token in tokens.dropFirst() {
                guard token.hasPrefix("--hash=sha256:") else { return nil }
                let digest = String(token.dropFirst("--hash=sha256:".count)).lowercased()
                guard SkillDependency.isCanonicalHex(digest, length: 64) else { return nil }
                digests.append(digest)
            }
            guard !digests.isEmpty else { return nil }
            if let priorVersion = nameToVersion[normalized], priorVersion != version {
                return nil // contradictory duplicate identity
            }
            nameToVersion[normalized] = version
            let specKey = "\(name)==\(version)"
            if let existing = closure[specKey] {
                closure[specKey] = Array(Set(existing + digests)).sorted()
            } else {
                closure[specKey] = digests.sorted()
            }
        }
        guard closure.count <= 256 else { return nil }
        return closure
    }

    /// True when the closure contains the declared requirement's exact pin.
    nonisolated static func pipLockCovers(_ closure: [String: [String]], name: String, version: String) -> Bool {
        closure.keys.contains { key in
            guard let separator = key.range(of: "==") else { return false }
            let lockName = String(key[key.startIndex..<separator.lowerBound])
            let lockVersion = String(key[separator.upperBound...])
            return normalizedPip(lockName) == normalizedPip(name) && lockVersion == version
        }
    }

    nonisolated static func wheelBytesValid(_ bytes: Data, expectedSHA256: String) -> Bool {
        bytes.count >= 1 && bytes.count <= 12 * 1_024 * 1024
            && SkillDependency.isCanonicalHex(expectedSHA256, length: 64)
            && FloeDigest.sha256Hex(bytes) == expectedSHA256
    }

    private func prefetchComponentArtifact(authority: SkillDependencyAuthority) async -> SkillDependencyPrefetchEntry {
        let fallbackName = "runtimeComponent"
        guard let descriptorBytes = authority.packageFiles[SkillDependency.componentDescriptorPath],
              let descriptor = try? SkillRuntimeDependency.decode(descriptorBytes) else {
            return SkillDependencyPrefetchEntry(
                kind: "runtimeComponent", name: fallbackName, version: nil,
                state: .failed,
                detail: "the pinned runtime-component descriptor is missing or foreign; the existing strict allowlist gate refused it"
            )
        }
        guard SkillRuntimeDependency.isCompatible(
            minimumAppVersion: descriptor.minimumAppVersion, appVersion: appVersion()
        ) else {
            return SkillDependencyPrefetchEntry(
                kind: "runtimeComponent", name: descriptor.componentID, version: descriptor.componentVersion,
                state: .awaitingTarget,
                detail: "the component requires a newer app than this build (existing minimumAppVersion gate unchanged)"
            )
        }
        guard let transport = lateBindings.componentTransport, let storeRoot = lateBindings.componentStoreRoot else {
            return SkillDependencyPrefetchEntry(
                kind: "runtimeComponent", name: descriptor.componentID, version: descriptor.componentVersion,
                state: .awaitingTarget,
                detail: "component transport/store not wired in this build; the existing managed deployment stays authoritative"
            )
        }
        let cacheFile = storeRoot
            .appendingPathComponent(descriptor.componentID, isDirectory: true)
            .appendingPathComponent(descriptor.componentVersion, isDirectory: true)
            .appendingPathComponent(descriptor.target.triple, isDirectory: true)
            .appendingPathComponent(SkillRuntimeDependency.frozenEngineFileName, isDirectory: false)
        let directory = cacheFile.deletingLastPathComponent()
        // Reuse verified cache bytes (hash reverified — a marker is never
        // trusted). Damaged bytes inside the app-owned namespace are replaced;
        // nothing outside this namespace is ever touched.
        if FileManager.default.fileExists(atPath: cacheFile.path),
           Self.verifiedCacheFile(cacheFile, size: descriptor.artifact.size, sha256: descriptor.artifact.sha256) {
            return SkillDependencyPrefetchEntry(
                kind: "runtimeComponent", name: descriptor.componentID, version: descriptor.componentVersion,
                state: .verified, detail: "verified cache bytes reused (no download)"
            )
        }
        guard SkillDependency.isCanonicalHex(authority.publicationCommit, length: 40) else {
            return SkillDependencyPrefetchEntry(
                kind: "runtimeComponent", name: descriptor.componentID, version: descriptor.componentVersion,
                state: .failed, detail: "the receipt publication commit is not an immutable 40-hex pin"
            )
        }
        let bytes: Data
        do {
            // GitHub-only transport at the SAME pinned publication commit Y;
            // there is deliberately no fallback source.
            bytes = try await transport(
                CuratedSkillHub.owner, CuratedSkillHub.repository,
                authority.publicationCommit, descriptor.artifact.path
            )
        } catch {
            return SkillDependencyPrefetchEntry(
                kind: "runtimeComponent", name: descriptor.componentID, version: descriptor.componentVersion,
                state: .failed,
                detail: "the trusted Hub artifact could not be downloaded and no verified cache exists"
            )
        }
        guard bytes.count == descriptor.artifact.size,
              bytes.count <= SkillRuntimeDependency.maximumArtifactBytes,
              FloeDigest.sha256Hex(bytes) == descriptor.artifact.sha256,
              (try? SkillRuntimeDependency.verifyStaticRISCVExecELF(bytes)) != nil else {
            return SkillDependencyPrefetchEntry(
                kind: "runtimeComponent", name: descriptor.componentID, version: descriptor.componentVersion,
                state: .failed, detail: "the downloaded bytes failed the existing size/digest/static-ELF gate"
            )
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".download-prefetch-\(UUID().uuidString)")
            try bytes.write(to: temporary, options: .atomic)
            guard Self.verifiedCacheFile(temporary, size: descriptor.artifact.size, sha256: descriptor.artifact.sha256) else {
                try? FileManager.default.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
            if FileManager.default.fileExists(atPath: cacheFile.path) {
                try FileManager.default.removeItem(at: cacheFile)
            }
            try FileManager.default.moveItem(at: temporary, to: cacheFile)
        } catch {
            return SkillDependencyPrefetchEntry(
                kind: "runtimeComponent", name: descriptor.componentID, version: descriptor.componentVersion,
                state: .failed, detail: "committing the verified artifact into the app-owned cache failed"
            )
        }
        return SkillDependencyPrefetchEntry(
            kind: "runtimeComponent", name: descriptor.componentID, version: descriptor.componentVersion,
            state: .verified,
            detail: "exact bytes fetched through the GitHub-only transport at the pinned publication commit, size+sha256+static-ELF verified, atomically committed to the component cache; staging/probing still run only inside the resolved guest"
        )
    }

    private static func verifiedCacheFile(_ url: URL, size: Int, sha256: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true, values.fileSize == size else { return false }
        guard let bytes = try? Data(floeContentsOf: url),
              FloeDigest.sha256Hex(bytes) == sha256 else { return false }
        return true
    }

    /// The honest, durable install-boundary summary for `skill.read` and any
    /// later view/restart: prefetch state per declared resource plus the
    /// environment-bound half. Never a "packages ready" claim.
    func sharedPreparationStatus(skillID: String) -> String? {
        guard let record = loadPersistedRecord(skillID: skillID), let prefetch = record.prefetch else { return nil }
        var lines: [String] = []
        for entry in prefetch {
            let version = entry.version.map { "@" + $0 } ?? ""
            let label: String
            switch entry.state {
            case .verified: label = "prefetched/verified"
            case .awaitingTarget: label = "awaiting task environment"
            case .failed: label = "prefetch failed"
            }
            lines.append("\(entry.kind) \(entry.name)\(version) = \(label)\(entry.detail.map { " (\($0))" } ?? "")")
        }
        // The "runs (or has run)" half is claimed only when THIS live center
        // holds a plan bound to a resolved task environment (recordPlan /
        // prepareAtInstall with an environmentID + runID). A persisted
        // install-time record alone — a global prefetch summary read by
        // another center instance, a restart or a released environment — never
        // claims environment readiness: the environment half honestly stays
        // "deferred" until a task binds a resolved external target again.
        let planTarget = plans.values.first { $0.skillID == skillID }?.target
        let targetLabel = planTarget.map { "resolved \($0.runtimeDescription) target" } ?? "resolved external environment"
        let pendingEnvironmentInstall = pendingSharedPreparation[skillID] != nil
            || planTarget == nil
        lines.append(pendingEnvironmentInstall
            ? "environment install/readback: deferred to the skill's first exec.shell invocation with skillID in a task bound to a \(targetLabel) (global installs prepare no task state and claim no readiness)"
            : "environment install/readback: runs (or has run) in the task's \(targetLabel) with receipts bound to the package version + digests + target identity + launch generation")
        lines.append("shared prefetch bytes are an app-owned download cache only; target readiness is never inferred from them")
        return lines.joined(separator: "\n")
    }

    // MARK: - exec.shell invocation gate

    /// Verifies the installed record, the current-run binding and the live
    /// authority, then automatically prepares and reads back the declared
    /// resources IN THIS SAME resolved environment. Required-not-ready refuses
    /// THIS skill's invocation; optional gaps annotate; the default path (no
    /// `skillID`) never reaches this code.
    func invoke(
        skillID: String,
        environmentID: String?,
        runID: UUID,
        cancellation: CancellationToken?
    ) async -> SkillDependencyInvocationOutcome {
        let trimmedEnvironmentID = environmentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let environmentID = trimmedEnvironmentID, !environmentID.isEmpty else {
            return .refused(reason: SkillDependencyReason.noEnvironment)
        }
        guard let plan = plans[PlanKey(environmentID: environmentID, runID: runID, skillID: skillID)] else {
            return .refused(reason: SkillDependencyReason.noRun)
        }
        // Live reauthorization first. An update/rollback/disable/edit/uninstall
        // replacing the immutable package + descriptor pair since the verified
        // read fails the pinned digests closed: the invocation stays bound to
        // the bytes its run verified and the run must re-read — never a silent
        // byte swap under a live plan.
        guard let authority = await authorityProvider(skillID),
              Self.isFormallyValid(authority),
              authority.contentDigest == plan.authority.contentDigest,
              authority.declarationSHA256 == plan.authority.declarationSHA256,
              authority.packageVersion == plan.authority.packageVersion else {
            plans[PlanKey(environmentID: environmentID, runID: runID, skillID: skillID)] = nil
            setState(environmentID, skillID) {
                $0.sourceAuthorized = false
                $0.deferredReason = SkillDependencyReason.planStale
            }
            return .refused(reason: SkillDependencyReason.planStale)
        }
        // Re-resolve the ACTUAL target and require the exact identity the
        // plan pinned. A changed backend/OS/architecture/distribution refuses;
        // a disconnected or unresolved target refuses. There is deliberately
        // no fallback to the Mac host, the local guest or a foreign receipt.
        guard let resolvedTarget = await resolveTarget(environmentID: environmentID, runID: runID),
              resolvedTarget.isResolved else {
            setState(environmentID, skillID) { $0.deferredReason = SkillDependencyReason.targetUnavailable }
            return .refused(reason: SkillDependencyReason.targetUnavailable)
        }
        guard resolvedTarget.identityFingerprint == plan.target.identityFingerprint else {
            setState(environmentID, skillID) { $0.deferredReason = SkillDependencyReason.targetChanged }
            return .refused(reason: SkillDependencyReason.targetChanged)
        }
        guard resolvedTarget.isConnected else {
            setState(environmentID, skillID) { $0.deferredReason = SkillDependencyReason.targetDisconnected }
            return .refused(reason: SkillDependencyReason.targetDisconnected)
        }
        // Re-check the target contract BEFORE anything can mutate (this also
        // covers plans recorded by an older build): non-matching profiles or
        // unsupported package managers refuse honestly, and no boot/install
        // runs for them. The operations-free allowance is judged ONLY on the
        // requirements that would actually participate here.
        if let refusal = targetValidation(plan.declaration, target: resolvedTarget, authority: authority) {
            setState(environmentID, skillID) { $0.deferredReason = refusal }
            return .refused(reason: refusal)
        }
        let targetOperations = await operationsForTarget(resolvedTarget)
        guard targetOperations != nil || matchingProfiles(plan.declaration, target: resolvedTarget).allSatisfy({ profile in
            profile.requirements.allSatisfy { $0.kind == .runtimeComponent }
        }) else {
            return .refused(reason: SkillDependencyReason.provisioningUnavailable)
        }
        do {
            try Task.checkCancellation()
            try cancellation?.throwIfCancelled()
            if let targetPreparation {
                try await targetPreparation(resolvedTarget, cancellation)
            } else if resolvedTarget.backend == .linuxVM {
                try await prepareEnvironment?(environmentID, cancellation)
            }
            try Task.checkCancellation()
            try cancellation?.throwIfCancelled()
        } catch {
            return .refused(reason: cancellation?.isCancelled == true || Task.isCancelled
                ? SkillDependencyReason.cancelled : SkillDependencyReason.environmentUnavailable)
        }
        guard let environment = await environmentResolver(environmentID) else {
            return .refused(reason: SkillDependencyReason.environmentUnavailable)
        }
        // Preparation may have booted/connected the target: take the fresh
        // generation and connection state, but never a different identity.
        let liveTarget = (await resolveTarget(environmentID: environmentID, runID: runID))
            ?? SkillRuntimeTarget.unresolved
        guard liveTarget.isResolved else {
            return .refused(reason: SkillDependencyReason.targetUnavailable)
        }
        guard liveTarget.identityFingerprint == plan.target.identityFingerprint else {
            return .refused(reason: SkillDependencyReason.targetChanged)
        }
        guard liveTarget.isConnected else {
            return .refused(reason: SkillDependencyReason.targetDisconnected)
        }
        let generationToken = liveTarget.generationToken
            ?? (await launchGenerationProvider(environmentID)).map { String($0) }
        let liveOperations = targetOperations ?? await operationsForTarget(liveTarget)

        let prepared = await prepareMatchingRequirements(
            skillID: skillID,
            plan: plan,
            authority: authority,
            target: liveTarget,
            environment: environment,
            operations: liveOperations,
            generationToken: generationToken,
            cancellation: cancellation
        )
        if let refusal = prepared.refusal {
            return .refused(reason: refusal)
        }
        return .ready(annotation: Self.verifiedAnnotation(
            authority: authority,
            verified: prepared.verified,
            optionalNotes: prepared.optionalNotes
        ))
    }

    // MARK: - Native migration preparation (no tool-call grant)

    /// App-native preparation used by the environment migration coordinator
    /// AFTER the user explicitly chose "Prepare and Migrate" for the displayed
    /// target and declared dependencies under the existing task policy. This
    /// method mints no ApprovalGrant and never reuses an `exec.shell` call
    /// grant: it is an internal service entrypoint, not a model-callable tool.
    /// Ordinary `invoke` still requires the actual approval grant at its
    /// existing gate. Nothing is committed here; the migration coordinator
    /// commits only after `verified`.
    ///
    /// Returns `.unavailable` when no reviewed declaration/authority exists or
    /// no external target can be resolved (an external skill without a
    /// declaration stays model-managed and no readiness is claimed),
    /// `.refused` when a required participating dependency is not ready, and
    /// `.verified` only when every required participating dependency readback
    /// succeeded on this exact target/package pair.
    func prepareForMigration(
        skillID: String,
        environmentID: String,
        migrationID: UUID,
        cancellation: CancellationToken?
    ) async -> SkillDependencyMigrationPreparationOutcome {
        let trimmed = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unavailable(reason: SkillDependencyReason.noEnvironment)
        }
        // A migration must use actual target facts. The legacy riscv64
        // pre-integration fallback is never acceptable for a target switch.
        guard targetProvider != nil else {
            return .unavailable(reason: SkillDependencyReason.targetUnavailable)
        }
        guard let authority = await authorityProvider(skillID),
              Self.isFormallyValid(authority),
              authority.skillID == skillID else {
            // No declaration and a no-longer-valid install both mean this
            // native path cannot prepare anything; never fake readiness.
            return .unavailable(reason: SkillDependencyReason.noDeclaration)
        }
        do {
            _ = try Self.decodeAndValidate(authority)
        } catch let error as SkillDependencyError {
            if case .unsupportedSchemaVersion = error {
                return .refused(reason: SkillDependencyReason.unsupportedSchema, requirements: [])
            }
            return .refused(reason: SkillDependencyReason.declarationRejected, requirements: [])
        } catch {
            return .refused(reason: SkillDependencyReason.declarationRejected, requirements: [])
        }
        guard let target = await resolveTarget(environmentID: trimmed, runID: migrationID),
              target.isResolved else {
            return .unavailable(reason: SkillDependencyReason.targetUnavailable)
        }
        guard target.hasExternalExecution else {
            return .unavailable(reason: SkillDependencyReason.targetUnsupported)
        }
        guard target.isConnected else {
            return .unavailable(reason: SkillDependencyReason.targetDisconnected)
        }
        let planKey = PlanKey(environmentID: trimmed, runID: migrationID, skillID: skillID)
        let planOutcome = await recordPlan(
            skillID: skillID,
            environmentID: trimmed,
            runID: migrationID,
            authority: authority
        )
        guard case .recorded = planOutcome, let plan = plans[planKey] else {
            if case .rejected(let reason) = planOutcome {
                if reason == SkillDependencyReason.targetUnavailable
                    || reason == SkillDependencyReason.targetUnsupported
                    || reason == SkillDependencyReason.targetDisconnected {
                    return .unavailable(reason: reason)
                }
                return .refused(reason: reason, requirements: [])
            }
            return .unavailable(reason: SkillDependencyReason.targetUnavailable)
        }
        // A migration id is an ownership/retry token, not a task run. The
        // plan exists only for this preparation pass; the post-commit run
        // re-reads and pins its own plan.
        defer { plans[planKey] = nil }

        do {
            try Task.checkCancellation()
            try cancellation?.throwIfCancelled()
            if let targetPreparation {
                try await targetPreparation(target, cancellation)
            } else if target.backend == .linuxVM {
                try await prepareEnvironment?(trimmed, cancellation)
            }
            try Task.checkCancellation()
            try cancellation?.throwIfCancelled()
        } catch {
            return .unavailable(reason: cancellation?.isCancelled == true || Task.isCancelled
                ? SkillDependencyReason.cancelled : SkillDependencyReason.environmentUnavailable)
        }
        guard let environment = await environmentResolver(trimmed) else {
            return .unavailable(reason: SkillDependencyReason.environmentUnavailable)
        }
        let liveTarget = (await resolveTarget(environmentID: trimmed, runID: migrationID))
            ?? SkillRuntimeTarget.unresolved
        guard liveTarget.isResolved else {
            return .unavailable(reason: SkillDependencyReason.targetUnavailable)
        }
        guard liveTarget.identityFingerprint == plan.target.identityFingerprint else {
            return .refused(reason: SkillDependencyReason.targetChanged, requirements: [])
        }
        guard liveTarget.isConnected else {
            return .unavailable(reason: SkillDependencyReason.targetDisconnected)
        }
        // Re-read the live reviewed authority immediately before mutation.
        // An update/rollback/disable/edit between the plan and this point
        // fails closed; the migration must re-check before retrying.
        guard let liveAuthority = await authorityProvider(skillID),
              Self.isFormallyValid(liveAuthority),
              liveAuthority.contentDigest == plan.authority.contentDigest,
              liveAuthority.declarationSHA256 == plan.authority.declarationSHA256,
              liveAuthority.packageVersion == plan.authority.packageVersion else {
            return .refused(reason: SkillDependencyReason.planStale, requirements: [])
        }
        let operations = await operationsForTarget(liveTarget)
        let participating = matchingProfiles(plan.declaration, target: liveTarget)
        let needsPackageOperations = participating.contains { profile in
            profile.requirements.contains { $0.kind != .runtimeComponent }
        }
        guard operations != nil || !needsPackageOperations else {
            return .unavailable(reason: SkillDependencyReason.provisioningUnavailable)
        }
        let generationToken = liveTarget.generationToken
            ?? (await launchGenerationProvider(trimmed)).map { String($0) }
        let prepared = await prepareMatchingRequirements(
            skillID: skillID,
            plan: plan,
            authority: liveAuthority,
            target: liveTarget,
            environment: environment,
            operations: operations,
            generationToken: generationToken,
            cancellation: cancellation
        )
        if let refusal = prepared.refusal {
            return .refused(reason: refusal, requirements: prepared.requirements)
        }
        return .verified(
            annotation: Self.verifiedAnnotation(
                authority: liveAuthority,
                verified: prepared.verified,
                optionalNotes: prepared.optionalNotes
            ),
            requirements: prepared.requirements
        )
    }

    private struct PreparedRequirementRun {
        var verified: [SkillDependencyEntry] = []
        var optionalNotes: [String] = []
        var requirements: [SkillDependencyMigrationRequirement] = []
        var refusal: String?
    }

    /// The one verified preparation loop shared by `invoke` (after its
    /// approval-grant gate) and `prepareForMigration` (after the user's
    /// explicit migration consent). It performs the same per-requirement
    /// conflict checks, owned-preparation coalescing, installs, readbacks and
    /// target-bound receipts; it never mints authority.
    private func prepareMatchingRequirements(
        skillID: String,
        plan: Plan,
        authority: SkillDependencyAuthority,
        target: SkillRuntimeTarget,
        environment: ToolEnvironment,
        operations: (any SkillDependencyPackageOperating)?,
        generationToken: String?,
        cancellation: CancellationToken?
    ) async -> PreparedRequirementRun {
        var run = PreparedRequirementRun()
        for profile in matchingProfiles(plan.declaration, target: target) {
            for requirement in profile.requirements {
                if cancellation?.isCancelled == true || Task.isCancelled {
                    run.refusal = SkillDependencyReason.cancelled
                    return run
                }
                func appendState(_ state: SkillDependencyMigrationRequirement.State, reason: String?) {
                    run.requirements.append(SkillDependencyMigrationRequirement(
                        kind: requirement.kind.rawValue, name: requirement.name,
                        version: requirement.version, required: requirement.required,
                        state: state, reason: reason
                    ))
                }
                if let refusal = Self.targetRefusal(
                    requirement: requirement, target: target, authority: authority
                ) {
                    if requirement.required {
                        appendState(.refused, reason: refusal)
                        setState(environmentID: plan.environmentID, skillID: skillID) {
                            $0.deferredReason = refusal
                            $0.readbackVerified = false
                        }
                        run.refusal = refusal
                        return run
                    }
                    appendState(.unavailable, reason: refusal)
                    run.optionalNotes.append(SkillDependencyReason.optionalGap(
                        requirement: requirement.identityKey, reason: refusal
                    ))
                    continue
                }
                let identityKey = "\(skillID)|\(profile.id)|\(requirement.identityKey)"
                let receiptKey = ReceiptKey(
                    environmentID: plan.environmentID,
                    requirementKey: identityKey,
                    targetFingerprint: target.identityFingerprint
                )
                if let existing = receipts[receiptKey],
                   Self.isReusable(
                    existing, authority: authority,
                    generationToken: generationToken,
                    targetFingerprint: target.identityFingerprint
                   ) {
                    run.verified.append(existing.entry)
                    appendState(.verified, reason: nil)
                    continue
                }
                let outcome = await prepareRequirement(
                    requirement,
                    profileID: profile.id,
                    plan: plan,
                    authority: authority,
                    receiptKey: receiptKey,
                    environment: environment,
                    operations: operations,
                    cancellation: cancellation
                )
                switch outcome {
                case .verified(let entry):
                    run.verified.append(entry)
                    receipts[receiptKey] = SkillDependencyRequirementReceipt(
                        skillID: skillID,
                        packageVersion: authority.packageVersion,
                        contentDigest: authority.contentDigest,
                        declarationSHA256: authority.declarationSHA256,
                        generationToken: generationToken,
                        targetFingerprint: target.identityFingerprint,
                        entry: entry,
                        verifiedAt: Date()
                    )
                    appendState(.verified, reason: nil)
                    setState(environmentID: plan.environmentID, skillID: skillID) { $0.deferredReason = nil }
                case .deferred(let reason):
                    if requirement.required {
                        appendState(.refused, reason: reason)
                        setState(environmentID: plan.environmentID, skillID: skillID) {
                            $0.deferredReason = reason
                            $0.readbackVerified = false
                        }
                        run.refusal = reason
                        return run
                    }
                    appendState(.unavailable, reason: reason)
                    run.optionalNotes.append(SkillDependencyReason.optionalGap(
                        requirement: requirement.identityKey, reason: reason
                    ))
                }
            }
        }
        guard !Task.isCancelled, cancellation?.isCancelled != true else {
            run.refusal = SkillDependencyReason.cancelled
            return run
        }
        setState(environmentID: plan.environmentID, skillID: skillID) {
            $0.prepared = true
            $0.readbackVerified = true
            $0.deferredReason = run.optionalNotes.isEmpty ? nil : run.optionalNotes.joined(separator: "; ")
        }
        return run
    }

    private static func verifiedAnnotation(
        authority: SkillDependencyAuthority,
        verified: [SkillDependencyEntry],
        optionalNotes: [String]
    ) -> String {
        var annotation = "skillDependencies=verified package=\(authority.packageVersion) manifest=\(String(authority.declarationSHA256.prefix(12)))"
        annotation += " " + verified.map { entry -> String in
            let version = entry.version.map { "@" + $0 } ?? ""
            return "\(entry.kind.rawValue):\(entry.name)\(version)=\(entry.evidence)"
        }.joined(separator: " ")
        if !optionalNotes.isEmpty {
            annotation += " " + optionalNotes.joined(separator: "; ")
        }
        return annotation
    }

    private static func isReusable(
        _ receipt: SkillDependencyRequirementReceipt,
        authority: SkillDependencyAuthority,
        generationToken: String?,
        targetFingerprint: String
    ) -> Bool {
        guard let generationToken, receipt.generationToken == generationToken,
              receipt.packageVersion == authority.packageVersion,
              receipt.contentDigest == authority.contentDigest,
              receipt.declarationSHA256 == authority.declarationSHA256,
              receipt.targetFingerprint == targetFingerprint else { return false }
        return true
    }

    /// Coalesced per-requirement preparation with live subscriber accounting.
    /// The waiter-side cancellation never cancels shared work; only the last
    /// departing subscriber cancels + joins the owned preparation, and
    /// `releaseEnvironment` does the same for its whole environment. The
    /// global shared download cache is untouched by either.
    private func prepareRequirement(
        _ requirement: SkillDependencyRequirement,
        profileID: String,
        plan: Plan,
        authority: SkillDependencyAuthority,
        receiptKey: ReceiptKey,
        environment: ToolEnvironment,
        operations: (any SkillDependencyPackageOperating)?,
        cancellation: CancellationToken?
    ) async -> SkillDependencyRequirementOutcome {
        let subscriptionID = UUID()
        let mirror = WaiterCancelMirror()
        let demand = SubscriberDemand(token: cancellation, mirror: mirror)
        let entry: Preparation
        if var existing = preparations[receiptKey] {
            existing.subscribers[subscriptionID] = demand
            preparations[receiptKey] = existing
            entry = existing
        } else {
            guard let operations else {
                return .deferred(reason: SkillDependencyReason.provisioningUnavailable)
            }
            let token = CancellationToken()
            let generation = UUID()
            let task = Task { [operations, weak self] () -> SkillDependencyRequirementOutcome in
                let outcome = await Self.performRequirement(
                    requirement,
                    profileID: profileID,
                    authority: authority,
                    environment: environment,
                    operations: operations,
                    token: token,
                    center: self
                )
                if case .deferred(let reason) = outcome {
                    await self?.recordDeferral(environmentID: environment.id, skillID: authority.skillID, reason: reason)
                }
                return outcome
            }
            entry = Preparation(generation: generation, task: task, token: token, subscribers: [subscriptionID: demand])
            preparations[receiptKey] = entry
        }

        let outcome: SkillDependencyRequirementOutcome
        let waiterCancelled: Bool
        do {
            outcome = try await Self.cancellableWait(token: cancellation, onWaiterCancel: { mirror.cancel() }) {
                await entry.task.value
            }
            waiterCancelled = false
        } catch {
            outcome = .deferred(reason: SkillDependencyReason.cancelled)
            waiterCancelled = true
        }

        if waiterCancelled {
            var cancelOwned = false
            if var current = preparations[receiptKey], current.generation == entry.generation {
                current.subscribers[subscriptionID] = nil
                if current.subscribers.isEmpty {
                    preparations[receiptKey] = nil
                    cancelOwned = true
                } else {
                    preparations[receiptKey] = current
                }
            }
            if cancelOwned {
                entry.token.cancel()
                entry.task.cancel()
                _ = await entry.task.value
            }
        } else if var current = preparations[receiptKey], current.generation == entry.generation {
            current.subscribers[subscriptionID] = nil
            if current.subscribers.isEmpty {
                preparations[receiptKey] = nil
            } else {
                preparations[receiptKey] = current
            }
        }
        return outcome
    }

    /// The fixed per-family verb sequence for one requirement: conflict read
    /// back BEFORE any mutation, install through the existing reviewed path,
    /// exact readback after. One bounded retry for transient transport
    /// failures; conflicts never retry and never downgrade.
    private nonisolated static func performRequirement(
        _ requirement: SkillDependencyRequirement,
        profileID: String,
        authority: SkillDependencyAuthority,
        environment: ToolEnvironment,
        operations: (any SkillDependencyPackageOperating)?,
        token: CancellationToken,
        center: SkillDependencyPreparationCenter?
    ) async -> SkillDependencyRequirementOutcome {
        func deferred(_ reason: String) -> SkillDependencyRequirementOutcome {
            .deferred(reason: reason)
        }
        guard !token.isCancelled, !Task.isCancelled else {
            return deferred(SkillDependencyReason.cancelled)
        }
        // Only the observation-only runtimeComponent kind may run without
        // package operations; every mutating kind fails honestly.
        guard operations != nil || requirement.kind == .runtimeComponent else {
            return deferred(SkillDependencyReason.provisioningUnavailable)
        }
        switch requirement.kind {
        case .pip:
            guard let spec = requirement.pipSpec, let pin = requirement.version else {
                return deferred(SkillDependencyReason.declarationRejected)
            }
            // Signed lock at the INSTALL path is a FULL pinned closure, not a
            // root lookup: pip's own --require-hashes mode verifies EVERY
            // processed requirement (transitives included), so the whole
            // closure is decoded strictly, every persisted store wheel is
            // checked against its own lock digests BEFORE pip can see it,
            // and one managed transaction installs all pinned specs.
            var closure: [String: [String]]? = nil
            if let lockPath = requirement.lockfile {
                guard let lockBytes = authority.packageFiles[lockPath] else {
                    // The validated inventory lost the declared lock bytes:
                    // fail closed rather than silently drop to a lock-free
                    // (unverifiable-hash) install.
                    return deferred(SkillDependencyReason.declarationRejected)
                }
                guard let parsed = Self.pipLockClosure(bytes: lockBytes) else {
                    return deferred(SkillDependencyReason.lockSyntaxRejected(name: requirement.name))
                }
                guard Self.pipLockCovers(parsed, name: requirement.name, version: pin) else {
                    return deferred(SkillDependencyReason.lockUnpinned(name: requirement.name))
                }
                closure = parsed
                if let storeURL = await center?.wheelStoreURLValue {
                    for memberSpec in parsed.keys.sorted() {
                        guard let cached = Self.cachedWheelBinding(storeURL: storeURL, spec: memberSpec) else { continue }
                        guard let digests = parsed[memberSpec], digests.contains(cached.binding.sha256) else {
                            Self.removeWheelBinding(storeURL: storeURL, wheelURL: cached.url, binding: cached.binding)
                            return deferred(SkillDependencyReason.lockMismatch(
                                name: Self.specNameVersion(memberSpec).name))
                        }
                    }
                }
            }
            let memberSpecs = closure.map { $0.keys.sorted() } ?? [spec]
            do {
                // Ownership-scoped conflict BEFORE any mutation: only the
                // environment's WRITABLE venv pins can conflict. A different
                // inherited `--system-site-packages` (apt) version never
                // blocks the reviewed venv pin — normal pip shadows it
                // inside the venv, and the APT base is never touched.
                let active = try await operations!.pythonInstalledVersions(environment: environment, cancellation: token)
                let owned = try await operations!.pythonOwnedVenvVersions(environment: environment, cancellation: token) ?? active
                struct ClosureMember { let spec: String; let name: String; let version: String; let key: String }
                var members: [ClosureMember] = []
                for memberSpec in memberSpecs {
                    let parsed = Self.specNameVersion(memberSpec)
                    guard let version = parsed.version else {
                        return deferred(SkillDependencyReason.declarationRejected)
                    }
                    members.append(ClosureMember(spec: memberSpec, name: parsed.name, version: version, key: normalizedPip(parsed.name)))
                }
                for member in members {
                    if let ownedVersion = owned[member.key], ownedVersion != member.version {
                        return deferred(SkillDependencyReason.conflict(
                            name: member.name, installed: ownedVersion, pinned: member.version
                        ))
                    }
                }
                let missing = members.filter { owned[$0.key] != $0.version && active[$0.key] != $0.version }
                if missing.isEmpty {
                    // Every pin is already ACTIVE at the exact version —
                    // owned or inherited-reusable. No mutation; the root
                    // evidence names which half satisfied the requirement.
                    var rootEvidence = ""
                    for member in members where member.spec == spec || normalizedPip(member.name) == normalizedPip(requirement.name) {
                        rootEvidence = owned[member.key] == member.version
                            ? "venv \(member.version) already verified"
                            : "inherited \(member.version) reused (system-site; venv untouched)"
                    }
                    let closureNote = members.count > 1 ? ", closure \(members.count) satisfied" : ""
                    return .verified(SkillDependencyEntry(
                        kind: .pip, name: requirement.name, version: pin,
                        required: requirement.required, evidence: (rootEvidence.isEmpty ? "already verified" : rootEvidence) + closureNote
                    ))
                }
                let pins = members.map { member in
                    (spec: member.spec, hashes: closure?[member.spec] ?? [])
                }
                let locked = closure != nil
                let output = try await retryOnce(
                    operation: {
                        // No-lock roots keep the exact single-spec command;
                        // a signed lock installs its FULL closure in one
                        // managed --require-hashes transaction.
                        if locked {
                            return try await operations!.pythonInstallPins(
                                pins, environment: environment, cancellation: token
                            )
                        }
                        return try await operations!.pythonEnsure(
                            spec: spec, hashes: [], environment: environment, cancellation: token
                        )
                    },
                    token: token
                )
                // Success readback: EVERY closure member's active version,
                // not just the root.
                let postInstall = try await operations!.pythonInstalledVersions(environment: environment, cancellation: token)
                for member in members {
                    guard postInstall[member.key] == member.version else {
                        return deferred(SkillDependencyReason.failed(
                            requirement: member.spec == spec ? requirement.identityKey : "pip:\(member.spec)",
                            reason: "the venv readback did not confirm \(member.spec)"
                        ))
                    }
                }
                _ = output
                let closureNote = members.count > 1 ? " closure \(members.count)" : ""
                return .verified(SkillDependencyEntry(
                    kind: .pip, name: requirement.name, version: pin,
                    required: requirement.required,
                    evidence: closure == nil
                        ? "venv \(pin)"
                        : "venv \(pin), lock sha256-verified\(closureNote)"
                ))
            } catch is CancellationError {
                return deferred(SkillDependencyReason.cancelled)
            } catch {
                return deferred(SkillDependencyReason.failed(requirement: requirement.identityKey, reason: error.localizedDescription))
            }
        case .apt:
            guard let pin = requirement.version else {
                return deferred(SkillDependencyReason.declarationRejected)
            }
            do {
                if let existing = try await operations!.aptInstalledVersion(identity: requirement.name, environment: environment, cancellation: token) {
                    guard existing == pin else {
                        return deferred(SkillDependencyReason.conflict(name: requirement.name, installed: existing, pinned: pin))
                    }
                    return .verified(SkillDependencyEntry(
                        kind: .apt, name: requirement.name, version: pin,
                        required: requirement.required, evidence: "dpkg \(existing) already verified"
                    ))
                }
                let output = try await retryOnce(
                    operation: { try await operations!.aptEnsure(identity: requirement.name, version: pin, environment: environment, cancellation: token) },
                    token: token
                )
                return .verified(SkillDependencyEntry(
                    kind: .apt, name: requirement.name, version: pin,
                    required: requirement.required, evidence: Self.boundedEvidence(output, fallback: "dpkg \(pin)")
                ))
            } catch is CancellationError {
                return deferred(SkillDependencyReason.cancelled)
            } catch {
                return deferred(SkillDependencyReason.failed(requirement: requirement.identityKey, reason: error.localizedDescription))
            }
        case .npm:
            guard let spec = requirement.npmSpec, let pin = requirement.version else {
                return deferred(SkillDependencyReason.declarationRejected)
            }
            do {
                let installed = try await operations!.nodeInstalledVersions(environment: environment, cancellation: token)
                if let existing = installed[requirement.name] {
                    guard existing == pin else {
                        return deferred(SkillDependencyReason.conflict(name: requirement.name, installed: existing, pinned: pin))
                    }
                    return .verified(SkillDependencyEntry(
                        kind: .npm, name: requirement.name, version: pin,
                        required: requirement.required, evidence: "node \(existing) already verified"
                    ))
                }
                let output = try await retryOnce(
                    operation: { try await operations!.npmEnsure(spec: spec, environment: environment, cancellation: token) },
                    token: token
                )
                return .verified(SkillDependencyEntry(
                    kind: .npm, name: requirement.name, version: pin,
                    required: requirement.required, evidence: Self.boundedEvidence(output, fallback: "node \(requirement.name)@\(pin)")
                ))
            } catch is CancellationError {
                return deferred(SkillDependencyReason.cancelled)
            } catch {
                return deferred(SkillDependencyReason.failed(requirement: requirement.identityKey, reason: error.localizedDescription))
            }
        case .font:
            // An exact apt identity+version pin (v1 has no unversioned font
            // exception) plus the fixed CJK availability probe; the readback
            // receipt records the version verbatim.
            guard let pin = requirement.version else {
                return deferred(SkillDependencyReason.declarationRejected)
            }
            do {
                if let existing = try await operations!.aptInstalledVersion(identity: requirement.name, environment: environment, cancellation: token) {
                    guard existing == pin else {
                        return deferred(SkillDependencyReason.conflict(name: requirement.name, installed: existing, pinned: pin))
                    }
                    if try await operations!.cjkProbePasses(environment: environment, cancellation: token) {
                        return .verified(SkillDependencyEntry(
                            kind: .font, name: requirement.name, version: pin,
                            required: requirement.required, evidence: "dpkg \(existing) verified, cjk-probe ok"
                        ))
                    }
                    return deferred(SkillDependencyReason.failed(
                        requirement: requirement.identityKey,
                        reason: "the pinned font is installed but the fixed CJK availability probe did not pass"
                    ))
                }
                let output = try await retryOnce(
                    operation: { try await operations!.fontEnsure(identity: requirement.name, version: pin, environment: environment, cancellation: token) },
                    token: token
                )
                return .verified(SkillDependencyEntry(
                    kind: .font, name: requirement.name, version: pin,
                    required: requirement.required, evidence: Self.boundedEvidence(output, fallback: "dpkg \(pin), cjk-probe ok")
                ))
            } catch is CancellationError {
                return deferred(SkillDependencyReason.cancelled)
            } catch {
                return deferred(SkillDependencyReason.failed(requirement: requirement.identityKey, reason: error.localizedDescription))
            }
        case .runtimeComponent:
            // Observe the existing allowlisted managed deployment only. Never
            // blocks, downloads or executes through this path; the component
            // channel's own nonblocking hook and allowlist stay unchanged.
            guard let center, let probe = await center.runtimeComponentProbeValue else {
                return deferred(SkillDependencyReason.provisioningUnavailable)
            }
            let runID = await center.currentRunID(environmentID: environment.id, skillID: authority.skillID)
            guard let runID else {
                return deferred(SkillDependencyReason.noRun)
            }
            if let reason = await probe(environment.id, runID, token) {
                return deferred(SkillDependencyReason.failed(
                    requirement: "runtimeComponent(" + profileID + ")", reason: reason
                ))
            }
            return .verified(SkillDependencyEntry(
                kind: .runtimeComponent, name: profileID, version: nil,
                required: requirement.required, evidence: "component probed"
            ))
        }
    }

    private nonisolated static func retryOnce(
        operation: @Sendable () async throws -> String,
        token: CancellationToken
    ) async throws -> String {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !token.isCancelled, !Task.isCancelled else { throw CancellationError() }
            // Bounded second attempt for transient failures only. A conflict
            // is refused before this point and never reaches retry.
            return try await operation()
        }
    }

    private nonisolated static func normalizedPip(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
    }

    private nonisolated static func boundedEvidence(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return fallback + " (" + String(trimmed.suffix(160)) + ")"
    }

    func recordDeferral(environmentID: String, skillID: String, reason: String) {
        setState(environmentID, skillID) {
            $0.deferredReason = reason
            $0.readbackVerified = false
        }
    }

    var runtimeComponentProbeValue: RuntimeComponentProbe? { runtimeComponentProbe }
    var wheelStoreURLValue: URL? { wheelStoreURL }

    /// The run identity currently bound to a plan for (environment, skill).
    func currentRunID(environmentID: String, skillID: String) -> UUID? {
        plans.values.first { $0.environmentID == environmentID && $0.skillID == skillID }?.runID
    }

    // MARK: - skill.read invocation info

    /// The model-safe invocation block appended to an exact `skill.read`
    /// footer for a dependency-bearing official skill.
    static func invocationInfo(
        skillID: String,
        declaration: SkillDependencyDeclaration
    ) -> String {
        var lines = ["## Dependency invocation"]
        for profile in declaration.profiles {
            let archs = profile.architectures.joined(separator: ", ")
            lines.append("Profile \"\(profile.id)\" targets \(profile.os) (\(archs)) with \(profile.requirements.count) reviewed requirement(s):")
            for requirement in profile.requirements {
                let pin = requirement.version.map { "@" + $0 } ?? ""
                let flag = requirement.required ? "required" : "optional"
                let identity = requirement.kind == .runtimeComponent
                    ? (requirement.componentDescriptorPath ?? "runtimeComponent")
                    : requirement.name
                lines.append("- \(requirement.kind.rawValue): \(identity)\(pin) (\(flag)) — \(requirement.purpose)")
            }
        }
        lines.append("Invoke with exec.shell \"skillID\": \"\(skillID)\" in this task run: Floe verifies the installed record, the current run binding and the grant, then automatically installs and reads back the declared resources in THIS task's resolved external target (shared download cache; target-scoped install state and receipts). A required resource that is not ready refuses this skill's invocation with the honest reason; optional gaps appear as an annotation. Commands without skillID are unchanged, so ordinary repair work stays available. Exact pins are installed and read back as declared — never ranges, never a silent downgrade.")
        return lines.joined(separator: "\n")
    }

    /// Current diagnostic state for one (environment, skill).
    func state(environmentID: String, skillID: String) -> SkillDependencyState {
        states[StateKey(environmentID: environmentID, skillID: skillID)] ?? SkillDependencyState()
    }

    // MARK: - Lifecycle

    /// Fences and removes everything this environment observed; cancels and
    /// JOINS its in-flight preparations before returning. Skill ownership
    /// records survive (uninstall is explicit).
    func releaseEnvironment(_ environmentID: String) async {
        plans = plans.filter { $0.key.environmentID != environmentID }
        let owned = preparations.filter { $0.key.environmentID == environmentID }
        for (key, entry) in owned {
            if preparations[key]?.generation == entry.generation {
                preparations[key] = nil
            }
        }
        for (_, entry) in owned {
            entry.token.cancel()
            entry.task.cancel()
        }
        for (_, entry) in owned {
            _ = await entry.task.value
        }
        receipts = receipts.filter { $0.key.environmentID != environmentID }
        states = states.filter { $0.key.environmentID != environmentID }
    }

    // MARK: - Waiter-cancellable join (proven component-center discipline)

    private struct WaiterCancelledError: Error, Sendable {}

    private final class WaitOnceBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var pending: Result<T, Error>?
        private var fulfilled = false
        var isFulfilled: Bool {
            lock.lock(); defer { lock.unlock() }; return fulfilled
        }
        func fulfill(with result: Result<T, Error>) {
            lock.lock()
            guard !fulfilled else { lock.unlock(); return }
            fulfilled = true
            let waiting = continuation
            continuation = nil
            if waiting == nil { pending = result }
            lock.unlock()
            waiting?.resume(with: result)
        }
        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    static let cancellationPollNanoseconds: UInt64 = 10_000_000

    private static func cancellableWait<T: Sendable>(
        token: CancellationToken?,
        onWaiterCancel: @escaping @Sendable () -> Void,
        _ operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        let box = WaitOnceBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                box.install(continuation)
                guard !box.isFulfilled else { return }
                Task.detached {
                    box.fulfill(with: .success(await operation()))
                }
                if let token {
                    Task.detached {
                        while !token.isCancelled {
                            if box.isFulfilled { return }
                            do { try await Task.sleep(nanoseconds: cancellationPollNanoseconds) }
                            catch { return }
                        }
                        onWaiterCancel()
                        box.fulfill(with: .failure(WaiterCancelledError()))
                    }
                }
            }
        } onCancel: {
            onWaiterCancel()
            box.fulfill(with: .failure(WaiterCancelledError()))
        }
    }

    // MARK: - Persistence helpers (service-owned; never a ready token)

    struct PersistedDeclarationRecord: Codable {
        let skillID: String
        let packageVersion: String
        let contentDigest: String
        let declarationSHA256: String
        let publicationCommit: String
        let updatedAt: Date
        /// Durable install-time prefetch summary (nil on records written
        /// before this field existed; decoded records are advisory status,
        /// never readiness).
        var prefetch: [SkillDependencyPrefetchEntry]?
    }

    private func loadPersistedRecord(skillID: String) -> PersistedDeclarationRecord? {
        guard let root = persistenceRoot else { return nil }
        let url = Self.recordURL(root: root, skillID: skillID)
        guard let data = try? Data(floeContentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedDeclarationRecord.self, from: data)
    }

    private static func recordURL(root: URL, skillID: String) -> URL {
        root.appendingPathComponent("\(skillID).json")
    }

    private func persistDeclarationRecord(
        for authority: SkillDependencyAuthority,
        prefetch: [SkillDependencyPrefetchEntry]? = nil
    ) {
        guard let root = persistenceRoot else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var record = PersistedDeclarationRecord(
            skillID: authority.skillID,
            packageVersion: authority.packageVersion,
            contentDigest: authority.contentDigest,
            declarationSHA256: authority.declarationSHA256,
            publicationCommit: authority.publicationCommit,
            updatedAt: Date(),
            prefetch: prefetch
        )
        // Status accumulates: an install-time prefetch summary survives later
        // re-validation writes that carry no new prefetch run.
        if record.prefetch == nil {
            record.prefetch = loadPersistedRecord(skillID: authority.skillID)?.prefetch
        }
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: Self.recordURL(root: root, skillID: authority.skillID), options: .atomic)
    }

    /// Boot recovery: stale ownership records are pruned. Serialized records
    /// are never a ready token — plans require a verified read and receipts
    /// require the current launch generation plus live reauthorization.
    func pruneStalePersistedRecords(now: Date = Date()) {
        guard let root = persistenceRoot,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasSuffix(".json") {
            let url = root.appendingPathComponent(name)
            if let data = try? Data(floeContentsOf: url),
               let record = try? JSONDecoder().decode(PersistedDeclarationRecord.self, from: data),
               now.timeIntervalSince(record.updatedAt) < 90 * 24 * 60 * 60 {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Shared validation

    /// Strict decode + inventory cross-validation (locks + descriptor present).
    static func decodeAndValidate(_ authority: SkillDependencyAuthority) throws -> SkillDependencyDeclaration {
        let declaration = try SkillDependency.decode(authority.declarationBytes)
        try SkillDependency.validate(declaration, packageFiles: authority.packageFiles)
        return declaration
    }

    static func isFormallyValid(_ authority: SkillDependencyAuthority) -> Bool {
        guard authority.feedStatus == .production,
              authority.reviewDecision == .approve,
              authority.feedSignatureKeyID == CuratedSkillHub.productionKeyID,
              authority.reviewKeyID == CuratedSkillHub.productionKeyID,
              authority.hubRepository == CuratedSkillHub.hubRepository,
              SkillDependency.isCanonicalHex(authority.publicationCommit, length: 40),
              SkillDependency.isCanonicalHex(authority.contentDigest, length: 64),
              SkillDependency.isCanonicalHex(authority.packageSHA256, length: 64),
              SkillDependency.isCanonicalHex(authority.catalogSHA256, length: 64),
              SkillDependency.isCanonicalHex(authority.reviewSHA256, length: 64),
              SkillDependency.isCanonicalHex(authority.declarationSHA256, length: 64) else { return false }
        return true
    }

    private func setState(
        _ environmentID: String,
        _ skillID: String,
        mutate: (inout SkillDependencyState) -> Void
    ) {
        let key = StateKey(environmentID: environmentID, skillID: skillID)
        var state = states[key] ?? SkillDependencyState()
        mutate(&state)
        states[key] = state
    }
}

extension SkillDependency {
    /// Exact lowercase hex of the given length.
    static func isCanonicalHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }
}

#endif
