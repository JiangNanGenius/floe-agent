// FloeApp — fixed Impeccable measurement producer loader (A2).
//
// The producer is one reviewed, digest-pinned JavaScript file shipped as an app
// resource (`Resources/Impeccable/impeccable-producer.v1.js`: verbatim pinned
// upstream `browser-bundle/15-snapshot.js` bytes + the fixed Floe adapter).
// Runtime rules implemented here:
//   * the *actual* bytes loaded are hashed and must equal the pinned digests,
//     including the recomputed run-bytes digest of file + the single fixed
//     native dispatch line; any difference fails closed;
//   * every bundled contract artifact is revalidated against the pinned
//     `producer-manifest.v1.json`;
//   * the all-zero synthetic fixture digest is never accepted;
//   * nothing on this surface is ever model- or page-authored: the only dynamic
//     values cross as `callAsyncJavaScript` *arguments* (data, not code).
//
// The engine (riscv64 guest binary, launcher, goldens) is pending in the H3
// lane; this file only produces the fixed native capture script surface.

import Foundation
import FloeCore

enum ImpeccableProducerScript {
    static let resourceDirectory = "Impeccable"
    static let fileName = "impeccable-producer.v1.js"
    static let manifestName = "producer-manifest.v1.json"

    /// sha256 of the shipped producer file bytes (55,565 bytes; the first
    /// 40,591 bytes are the pinned upstream file verbatim — see PROVENANCE.md).
    static let pinnedFileSHA256 = "5bfbcee7edd70d40ee562eeefabe416c62d2f4ab8b9a48de5be7afebceb8a89f"
    /// sha256 of the upstream prefix, recorded for the read-only coherence check.
    static let pinnedUpstreamPrefixSHA256 = "b97e055fa25eaba1186cee5174899be13efcfc82ab6c133e9306ed5791d3aef0"
    static let pinnedUpstreamPrefixBytes = 40_591

    /// The one line native appends when invoking the producer. It is a fixed
    /// constant in this file, never a template for caller-supplied code.
    static let nativeDispatchLine = "return globalThis.__floeImpeccable.dispatch(floeOp, floeArgs);"

    /// sha256(file bytes + "\n" + nativeDispatchLine): exactly the bytes that
    /// execute in the isolated content world. `identity.producer.scriptDigest`
    /// binds this value.
    static let pinnedRunBytesSHA256 = "34b245bc46bb50047dfe3f7a3b420137498a099a7b82b2734fca8e088176e5f9"

    struct Loaded: Sendable {
        /// The verified file bytes.
        let source: String
        /// The fixed invocation script: file bytes + newline + dispatch line.
        let runSource: String
        /// sha256 of `runSource` — the value for `producer.scriptDigest`.
        let runDigest: String
        /// Byte counts for diagnostics (no page content).
        let fileBytes: Int
        let runBytes: Int
    }

    enum LoadError: Error, CustomStringConvertible {
        case missingResource(String)
        case digestMismatch(String)
        case manifestInvalid(String)

        var description: String {
            switch self {
            case .missingResource(let name): return "Impeccable producer resource '\(name)' is not in the app bundle"
            case .digestMismatch(let detail): return "Impeccable producer bytes failed verification: \(detail)"
            case .manifestInvalid(let detail): return "Impeccable producer manifest invalid: \(detail)"
            }
        }
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cached: Loaded?

    /// Load, hash-verify and cache the fixed producer. Throws on any
    /// provenance failure; callers must surface `identity-rejected` and refuse
    /// the capture rather than fall back to any other script.
    static func loadVerified(bundle: Bundle = .main) throws -> Loaded {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }

        guard let fileURL = resourceURL(named: (fileName as NSString).deletingPathExtension, extension: "js", bundle: bundle) else {
            throw LoadError.missingResource(fileName)
        }
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw LoadError.missingResource(fileName)
        }
        let fileDigest = FloeDigest.sha256Hex(fileData)
        guard fileDigest == pinnedFileSHA256 else {
            throw LoadError.digestMismatch("file sha256 \(fileDigest) != pinned \(pinnedFileSHA256)")
        }
        let prefixData = fileData.prefix(pinnedUpstreamPrefixBytes)
        let prefixDigest = FloeDigest.sha256Hex(Data(prefixData))
        guard prefixDigest == pinnedUpstreamPrefixSHA256 else {
            throw LoadError.digestMismatch("upstream prefix \(prefixDigest) != pinned \(pinnedUpstreamPrefixSHA256)")
        }
        guard let source = String(data: fileData, encoding: .utf8) else {
            throw LoadError.digestMismatch("producer file is not valid UTF-8")
        }

        // Revalidate the manifest and every bundled contract artifact it pins.
        if let manifestURL = resourceURL(named: (manifestName as NSString).deletingPathExtension,
                                         extension: (manifestName as NSString).pathExtension,
                                         bundle: bundle),
           let manifestData = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] {
            try validate(manifest: manifest, bundle: bundle)
        } else {
            // The manifest is part of the same reviewed resource set; absence
            // or corruption is a provenance failure, not a warning.
            throw LoadError.manifestInvalid("producer-manifest.v1.json missing or unreadable")
        }

        let runSource = source + "\n" + nativeDispatchLine
        guard let runData = runSource.data(using: .utf8) else {
            throw LoadError.digestMismatch("run script is not valid UTF-8")
        }
        let runDigest = FloeDigest.sha256Hex(runData)
        guard runDigest == pinnedRunBytesSHA256 else {
            throw LoadError.digestMismatch("run sha256 \(runDigest) != pinned \(pinnedRunBytesSHA256)")
        }
        guard runDigest != ImpeccableContract.syntheticScriptDigest,
              fileDigest != ImpeccableContract.syntheticScriptDigest else {
            throw LoadError.digestMismatch("synthetic all-zero digest can never be a real producer")
        }
        let loaded = Loaded(
            source: source,
            runSource: runSource,
            runDigest: runDigest,
            fileBytes: fileData.count,
            runBytes: runData.count
        )
        cached = loaded
        return loaded
    }

    private static func validate(manifest: [String: Any], bundle: Bundle) throws {
        guard (manifest["contract"] as? String) == ImpeccableContract.name,
              (manifest["contractVersion"] as? NSNumber)?.intValue == ImpeccableContract.contractVersion else {
            throw LoadError.manifestInvalid("contract name/version fields")
        }
        guard let script = manifest["producerScript"] as? [String: Any],
              (script["fileSha256"] as? String) == pinnedFileSHA256,
              (script["runBytesSha256"] as? String) == pinnedRunBytesSHA256,
              (script["nativeDispatchLine"] as? String) == nativeDispatchLine else {
            throw LoadError.manifestInvalid("producerScript pinning")
        }
        guard let upstream = manifest["upstream"] as? [String: Any],
              (upstream["commit"] as? String) == ImpeccableContract.upstreamCommit,
              (upstream["tree"] as? String) == ImpeccableContract.upstreamTree,
              (upstream["engineVersion"] as? String) == ImpeccableContract.upstreamEngineVersion else {
            throw LoadError.manifestInvalid("upstream pin mismatch")
        }
        guard let files = manifest["files"] as? [String: Any] else {
            throw LoadError.manifestInvalid("files map absent")
        }
        for (name, digest) in files {
            guard let expected = digest as? String else {
                throw LoadError.manifestInvalid("files entry \(name) is not a string")
            }
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let url = resourceURL(named: base, extension: ext, bundle: bundle),
                  let data = try? Data(contentsOf: url) else {
                // The manifest lists the license text too; every listed file
                // must be present in the same resource directory.
                throw LoadError.manifestInvalid("listed file \(name) not bundled")
            }
            guard FloeDigest.sha256Hex(data) == expected else {
                throw LoadError.manifestInvalid("listed file \(name) bytes differ from the pinned digest")
            }
        }
    }

    private static func resourceURL(named base: String, extension: String, bundle: Bundle) -> URL? {
        // Works both when `Resources/Impeccable` is bundled as a folder
        // (proposed project.yml route) and when its contents were flattened
        // into the bundle root by the default resource phase.
        if let url = bundle.url(forResource: base, withExtension: `extension`, subdirectory: resourceDirectory) {
            return url
        }
        return bundle.url(forResource: base, withExtension: `extension`)
    }
}

/// Builds the two fixed producer invocations. Both pass all dynamic values as
/// `callAsyncJavaScript` arguments (data, never code) and run only the
/// verified script text plus the pinned dispatch line.
enum ImpeccableProducerInvocation {
    struct CaptureArguments: Sendable {
        let captureId: String
        let documentId: String
        let contractVersion: Int
        let maxElements: Int
        let maxBytes: Int
    }

    struct AnswerArguments: Sendable {
        let captureId: String
        let expectedDocumentId: String
        /// The exact IEEE-754 CSS viewport/scroll recorded in the native
        /// frozen identity at capture time (bit-identical to the producer
        /// envelope and snapshot view fields — the capture path refuses any
        /// disagreement). The fixed adapter enforces live-view drift against
        /// its own recorded run view inside `answer` before measuring any
        /// point; these fields bind the call to native's recorded identity
        /// so the invocation itself carries the full fencing expectation,
        /// never placeholders or defaults.
        let expectedViewportWidth: Double
        let expectedViewportHeight: Double
        let expectedScrollX: Double
        let expectedScrollY: Double
        /// Authoritative points: the exact doubles rehydrated from the Needs
        /// `hitTestsBits`, never a re-rounded decimal.
        let points: [[Double]]
    }

    /// Arguments of the fixed read-only probe: the capture whose currency is
    /// being proven. The probe measures no DOM and receives nothing else —
    /// there is no coordinate, threshold or code a caller could supply.
    struct ProbeArguments: Sendable {
        let captureId: String
    }

    static func captureArguments(_ arguments: CaptureArguments, budgets: ImpeccableBudgets) -> [String: Any] {
        [
            "floeOp": "capture",
            "floeArgs": [
                "captureId": arguments.captureId,
                "documentId": arguments.documentId,
                "contractVersion": min(arguments.contractVersion, ImpeccableContract.contractVersion),
                "maxElements": min(max(1, arguments.maxElements), budgets.maxElements),
                "maxBytes": min(max(1, arguments.maxBytes), budgets.maxSnapshotBytes),
            ],
        ]
    }

    static func answerArguments(_ arguments: AnswerArguments, budgets: ImpeccableBudgets) -> [String: Any] {
        let boundedPoints: [[Double]] = arguments.points.prefix(budgets.maxHitTestsPerRound).map { point in
            [point[0], point[1]]
        }
        return [
            "floeOp": "answer",
            "floeArgs": [
                "captureId": arguments.captureId,
                "expect": [
                    "documentId": arguments.expectedDocumentId,
                    // Native's recorded view, exact bits (see AnswerArguments).
                    // The pinned adapter currently enforces viewport/scroll
                    // drift against its own recorded run view inside `answer`
                    // and consumes only `documentId` here; these keys carry
                    // the identical frozen numbers so the fixed call is bound
                    // to the native record and the adapter bytes stay
                    // unchanged (unknown `expect` keys are inert by
                    // construction — `runAnswer` reads named fields only).
                    "viewportWidth": arguments.expectedViewportWidth,
                    "viewportHeight": arguments.expectedViewportHeight,
                    "scrollX": arguments.expectedScrollX,
                    "scrollY": arguments.expectedScrollY,
                ],
                "points": boundedPoints,
            ],
        ]
    }

    /// The fixed read-only probe invocation. It asks the isolated world for
    /// the *current* CSS viewport/scroll and whether that world still holds
    /// the capture run; native compares the answer against the native-issued
    /// identity and refuses late results. Data-only arguments, one fixed op
    /// name; no caller-supplied code path exists.
    static func probeArguments(_ arguments: ProbeArguments) -> [String: Any] {
        [
            "floeOp": "probe",
            "floeArgs": [
                "captureId": arguments.captureId,
            ],
        ]
    }
}
