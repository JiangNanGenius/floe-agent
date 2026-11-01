// FloeSkills — curated Skill Hub review-record binding (lane A1).
//
// Decodes the signed review record (`reviews/{id}/{version}.review.json`)
// with the same strict shape the hub validator enforces, and performs the
// three-way join required before staging: signed catalog entry ⇄ signed
// review record ⇄ the actual unpacked manifest bytes. A valid signature over
// stale bytes, a subset of tools, a superset grant or any dependency drift
// fails closed here. This module computes the verified permission delta for
// the existing combined-approval flow; it never installs, grants or enables
// anything itself, and it never reads or writes a permission database.

import Foundation

// MARK: - Review enums

public enum CuratedSkillReviewDecision: String, Codable, Sendable, CaseIterable, Hashable {
    case approve
    case reject
}

public enum CuratedSkillReviewStage: String, Codable, Sendable, CaseIterable, Hashable {
    case staticContentReviewed = "static-content-reviewed"
    case guestExecutionQualified = "guest-execution-qualified"
}

// MARK: - Review record

/// schemaVersion-1 signed publisher review record. The record binds
/// id/version to the exact content it vouched for; a package or digest
/// change invalidates it. Records are evidence under the compiled trust,
/// never a second permission database and never self-issuable.
public struct CuratedSkillReviewRecord: Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let contentDigest: String
    public let packageSha256: String
    public let reviewedCapabilities: [String]
    public let reviewedTools: [String]
    public let reviewedPythonPackages: [SkillPythonPackageRequirement]
    public let execution: CuratedSkillExecution
    public let reviewStage: CuratedSkillReviewStage
    public let reviewedAt: String
    public let reviewer: String
    public let decision: CuratedSkillReviewDecision
    public let notes: CuratedSkillLocalizedText

    public static let schemaVersionValue = 1

    /// Strict decode from the exact review-record bytes (the same bytes the
    /// binding `sha256` and signature cover).
    public static func decode(bytes: Data) throws -> CuratedSkillReviewRecord {
        let path = "review"
        let root = try CuratedSkillStrictJSON.object(bytes)
        try CuratedSkillStrictJSON.exactKeys(root, required: [
            "schemaVersion", "id", "version", "contentDigest", "packageSha256",
            "reviewedCapabilities", "reviewedTools", "reviewedPythonPackages",
            "execution", "reviewStage", "reviewedAt", "reviewer", "decision", "notes",
        ], path: path)
        let schemaVersion = try CuratedSkillStrictJSON.integer(root["schemaVersion"], path: "\(path).schemaVersion")
        guard schemaVersion == schemaVersionValue else {
            throw CuratedSkillHubFailure.review("review schemaVersion must be \(schemaVersionValue)")
        }
        let id = try CuratedSkillStrictJSON.string(root["id"], path: "\(path).id")
        guard CuratedSkillStrictJSON.isIdentifier(id) else {
            throw CuratedSkillHubFailure.review("review id is not a SkillIdentifier-grammar identifier")
        }
        let version = try CuratedSkillStrictJSON.string(root["version"], path: "\(path).version")
        guard CuratedSkillStrictJSON.isVersion(version) else {
            throw CuratedSkillHubFailure.review("review version must be strict X.Y.Z")
        }
        let contentDigest = try CuratedSkillStrictJSON.string(root["contentDigest"], path: "\(path).contentDigest")
        guard CuratedSkillStrictJSON.isSHA256(contentDigest) else {
            throw CuratedSkillHubFailure.review("review contentDigest must be 64 lowercase hex")
        }
        let packageSha256 = try CuratedSkillStrictJSON.string(root["packageSha256"], path: "\(path).packageSha256")
        guard CuratedSkillStrictJSON.isSHA256(packageSha256) else {
            throw CuratedSkillHubFailure.review("review packageSha256 must be 64 lowercase hex")
        }
        let capabilities = try CuratedSkillStrictJSON.stringArray(root["reviewedCapabilities"], path: "\(path).reviewedCapabilities")
        guard Set(capabilities).count == capabilities.count else {
            throw CuratedSkillHubFailure.review("reviewedCapabilities must be unique")
        }
        for capability in capabilities where SkillCapability(rawValue: capability) == nil {
            throw CuratedSkillHubFailure.review("reviewedCapabilities contains a value outside the native enum: \(capability)")
        }
        let tools = try CuratedSkillStrictJSON.stringArray(root["reviewedTools"], path: "\(path).reviewedTools")
        guard Set(tools).count == tools.count, tools.allSatisfy(CuratedSkillStrictJSON.isToolName) else {
            throw CuratedSkillHubFailure.review("reviewedTools must be unique dotted names")
        }
        let packageValues = try CuratedSkillStrictJSON.array(root["reviewedPythonPackages"], path: "\(path).reviewedPythonPackages")
        guard packageValues.count <= 16 else {
            throw CuratedSkillHubFailure.review("reviewedPythonPackages accepts at most 16 entries")
        }
        var requirements: [SkillPythonPackageRequirement] = []
        var seenSpecs: Set<String> = []
        for (index, element) in packageValues.enumerated() {
            let entryPath = "\(path).reviewedPythonPackages[\(index)]"
            let object = try CuratedSkillStrictJSON.object(from: element, path: entryPath)
            try CuratedSkillStrictJSON.exactKeys(object, required: ["spec", "purpose", "capabilities"], path: entryPath)
            let spec = try CuratedSkillStrictJSON.string(object["spec"], path: "\(entryPath).spec")
            guard CuratedSkillStrictJSON.isExactPythonSpec(spec) else {
                throw CuratedSkillHubFailure.review("reviewed packages must be exact name==version specs: \(spec)")
            }
            let purpose = try CuratedSkillStrictJSON.string(object["purpose"], path: "\(entryPath).purpose")
            let trimmedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPurpose.isEmpty, trimmedPurpose.utf8.count <= 1_024 else {
                throw CuratedSkillHubFailure.review("reviewed package purpose must be 1-1024 bytes")
            }
            let packageCapabilities = try CuratedSkillStrictJSON.stringArray(
                object["capabilities"], path: "\(entryPath).capabilities")
            guard (1...16).contains(packageCapabilities.count),
                  Set(packageCapabilities).count == packageCapabilities.count else {
                throw CuratedSkillHubFailure.review("reviewed package capabilities must be 1-16 unique values")
            }
            guard seenSpecs.insert(spec.lowercased()).inserted else {
                throw CuratedSkillHubFailure.review("duplicate reviewed package spec: \(spec)")
            }
            requirements.append(SkillPythonPackageRequirement(
                spec: spec, purpose: trimmedPurpose, capabilities: packageCapabilities))
        }
        let execution = try CuratedSkillEntryDecoder.decodeExecution(root["execution"], path: "\(path).execution")
        let stageValue = try CuratedSkillStrictJSON.string(root["reviewStage"], path: "\(path).reviewStage")
        guard let reviewStage = CuratedSkillReviewStage(rawValue: stageValue) else {
            throw CuratedSkillHubFailure.review("reviewStage unknown")
        }
        let reviewedAt = try CuratedSkillStrictJSON.string(root["reviewedAt"], path: "\(path).reviewedAt")
        guard CuratedSkillStrictJSON.isDate(reviewedAt) else {
            throw CuratedSkillHubFailure.review("reviewedAt must be YYYY-MM-DD")
        }
        let reviewer = try CuratedSkillStrictJSON.string(root["reviewer"], path: "\(path).reviewer")
        guard !reviewer.isEmpty, reviewer.count <= 64 else {
            throw CuratedSkillHubFailure.review("reviewer must be 1-64 characters")
        }
        let decisionValue = try CuratedSkillStrictJSON.string(root["decision"], path: "\(path).decision")
        guard let decision = CuratedSkillReviewDecision(rawValue: decisionValue) else {
            throw CuratedSkillHubFailure.review("review decision unknown")
        }
        let notes = try CuratedSkillStrictJSON.localizedText(root["notes"], path: "\(path).notes", nonEmpty: true)
        if reviewStage == .guestExecutionQualified && execution.evidence != .guestVerified {
            throw CuratedSkillHubFailure.review("guest-execution-qualified requires guest-verified execution evidence")
        }
        return CuratedSkillReviewRecord(
            schemaVersion: schemaVersion, id: id, version: version, contentDigest: contentDigest,
            packageSha256: packageSha256, reviewedCapabilities: capabilities, reviewedTools: tools,
            reviewedPythonPackages: requirements, execution: execution, reviewStage: reviewStage,
            reviewedAt: reviewedAt, reviewer: reviewer, decision: decision, notes: notes
        )
    }
}

// MARK: - Three-way join

/// The exact-bytes join a qualified install requires. The native client
/// repeats every join independently: never a subset (an omitted new tool is
/// unreviewed), never a superset (a grant outside the manifest), never a
/// stale valid signature over old bytes.
public enum CuratedSkillReviewJoin {
    /// Verifies the signed review record against the signed catalog entry
    /// AND the actual unpacked package. `archiveSHA256` is the digest of the
    /// exact downloaded archive bytes; `actual` is the freshly validated
    /// staged package. Throws `.review` on any binding drift and
    /// `.immutableVersion` on a same-version digest conflict.
    public static func verify(
        record: CuratedSkillReviewRecord,
        against entry: CuratedSkillEntry,
        actual actualPackage: ValidatedSkillPackage,
        archiveSHA256: String,
        feedChannel: CuratedSkillChannel
    ) throws {
        guard record.id == entry.id, record.version == entry.version else {
            throw CuratedSkillHubFailure.review("review identity does not match the catalog entry")
        }
        guard actualPackage.manifest.id == entry.id, actualPackage.manifest.version == entry.version else {
            throw CuratedSkillHubFailure.review("packaged manifest identity does not match the catalog entry")
        }
        guard let binding = entry.package else {
            throw CuratedSkillHubFailure.review("a review join requires a signed package binding")
        }
        guard record.contentDigest == binding.contentDigest,
              actualPackage.canonicalSHA256 == binding.contentDigest else {
            throw CuratedSkillHubFailure.review("review contentDigest does not match the actual package bytes")
        }
        guard record.packageSha256 == binding.sha256, archiveSHA256 == binding.sha256 else {
            throw CuratedSkillHubFailure.review("review packageSha256 does not match the actual archive")
        }
        guard record.decision == .approve else {
            throw CuratedSkillHubFailure.review("only an approve decision can bind a qualified entry")
        }
        // The review must cover exactly the manifest's real facts — the
        // actual normalized manifest, never the claimed registry plan.
        guard Set(record.reviewedCapabilities) == Set(actualPackage.manifest.capabilities) else {
            throw CuratedSkillHubFailure.review("review must cover exactly the manifest's declared capabilities")
        }
        guard Set(record.reviewedTools) == Set(actualPackage.manifest.tools) else {
            throw CuratedSkillHubFailure.review("review must cover exactly the manifest's declared tools")
        }
        let reviewedSpecs = Set(record.reviewedPythonPackages.map { $0.spec.lowercased() })
        let manifestSpecs = Set(actualPackage.manifest.pythonPackages.map { $0.spec.lowercased() })
        guard reviewedSpecs == manifestSpecs else {
            throw CuratedSkillHubFailure.review("review must cover exactly the manifest's declared dependencies")
        }
        // The entry's runtime block must carry the actual reviewed manifest
        // facts, not a placeholder plan.
        guard Set(entry.runtime.capabilities) == Set(actualPackage.manifest.capabilities) else {
            throw CuratedSkillHubFailure.review("entry capabilities drift from the actual manifest")
        }
        guard Set(entry.runtime.tools) == Set(actualPackage.manifest.tools) else {
            throw CuratedSkillHubFailure.review("entry tools drift from the actual manifest")
        }
        guard entry.runtime.scriptRuntime == actualPackage.manifest.scriptRuntime else {
            throw CuratedSkillHubFailure.review("entry scriptRuntime drifts from the actual manifest")
        }
        let planSpecs = Set(entry.runtime.pythonPackagesPlan.map { $0.lowercased() })
        guard planSpecs == manifestSpecs else {
            throw CuratedSkillHubFailure.review("entry pythonPackagesPlan drifts from the actual manifest dependencies")
        }
        guard binding.containsScripts == actualPackage.containsScripts else {
            throw CuratedSkillHubFailure.review("entry containsScripts drifts from the actual package")
        }
        // Review scope may never exceed what the entry declared.
        let declared = Set(entry.runtime.capabilities).union(entry.runtime.tools)
        let requested = Set(record.reviewedCapabilities).union(record.reviewedTools)
        guard requested.isSubset(of: declared) else {
            throw CuratedSkillHubFailure.review("review must bind the tools/capabilities the entry declared, not exceed them")
        }
        // Execution plane stays distinct from the store channel: no inference
        // from the channel to execution and back.
        if actualPackage.manifest.scriptRuntime == .none {
            guard record.execution == .guideOnly, entry.runtime.execution == .guideOnly else {
                throw CuratedSkillHubFailure.review("a guide-only package review must carry no execution claim")
            }
        } else {
            guard record.execution.os == "linux" else {
                throw CuratedSkillHubFailure.review("script packages execute only in the task Linux environment")
            }
            guard entry.runtime.execution.os == "linux", entry.runtime.execution.arch == record.execution.arch else {
                throw CuratedSkillHubFailure.review("entry execution drifts from the review execution facts")
            }
            if record.execution.evidence == .guestVerified {
                guard record.reviewStage == .guestExecutionQualified else {
                    throw CuratedSkillHubFailure.review("guest-verified evidence requires the qualified review stage")
                }
            }
            guard (record.execution.evidence == .guestVerified) == entry.status.executionVerified else {
                throw CuratedSkillHubFailure.review("execution evidence and status.executionVerified disagree")
            }
        }
        // The store channel may install this package (install channel list),
        // while the manifest's native platforms block is a separate plane and
        // is never rewritten here.
        guard entry.runtime.installPlatforms.contains(feedChannel) else {
            throw CuratedSkillHubFailure.review("entry installPlatforms do not cover the feed channel")
        }
    }
}

// MARK: - Permission delta

/// The verified delta from the ACTUAL manifest to the user's existing
/// effective grants. Feed this into the existing combined permission flow:
/// covered rights need no repeated per-item confirmation; only the missing
/// delta enters approval once. User disabled/uninstalled/edited choices and
/// the temporary-task ceiling stay authoritative and are enforced outside
/// this module. No second permission database is created.
public struct CuratedSkillPermissionDelta: Codable, Sendable, Equatable {
    public let requiredCapabilities: [String]
    public let requiredTools: [String]
    public let requiredPythonPackageSpecs: [String]
    public let missingCapabilities: [String]
    public let missingTools: [String]
    public let missingPythonPackageSpecs: [String]

    public var isEmptyDelta: Bool {
        missingCapabilities.isEmpty && missingTools.isEmpty && missingPythonPackageSpecs.isEmpty
    }

    /// True when every actual-manifest right is already covered by the
    /// existing effective grants; under the fixed policy (§4) the commit may
    /// then proceed without redundant confirmation — after the existing
    /// native grants are rechecked at commit time by the caller.
    public var isCoveredByEffectiveGrants: Bool { isEmptyDelta }

    /// The machine-readable reason list for the UI when a delta exists.
    public var requiresCombinedApproval: Bool { !isEmptyDelta }

    /// Honesty gate: automatic proceed requires the feed to carry the exact
    /// fixed contract policy AND full coverage. Any drift needs the normal
    /// combined approval path.
    public func mayProceedWithoutRedundantConfirmation(under policy: CuratedSkillPermissionPolicy) -> Bool {
        policy == CuratedSkillPermissionPolicy.contract && isEmptyDelta
    }

    /// Computes the delta strictly from the actual validated manifest (the
    /// join guarantees the review covers exactly these facts).
    public static func from(
        actualManifest: SkillManifest,
        effectiveCapabilities: Set<String>,
        effectiveTools: Set<String>,
        effectivePythonPackageSpecs: Set<String>
    ) -> CuratedSkillPermissionDelta {
        let requiredCapabilities = Set(actualManifest.capabilities).sorted()
        let requiredTools = Set(actualManifest.tools).sorted()
        let requiredSpecs = Set(actualManifest.pythonPackages.map { $0.spec.lowercased() }).sorted()
        let effectiveSpecs = Set(effectivePythonPackageSpecs.map { $0.lowercased() })
        return CuratedSkillPermissionDelta(
            requiredCapabilities: requiredCapabilities,
            requiredTools: requiredTools,
            requiredPythonPackageSpecs: requiredSpecs,
            missingCapabilities: requiredCapabilities.filter { !effectiveCapabilities.contains($0) },
            missingTools: requiredTools.filter { !effectiveTools.contains($0) },
            missingPythonPackageSpecs: requiredSpecs.filter { !effectiveSpecs.contains($0) }
        )
    }
}
