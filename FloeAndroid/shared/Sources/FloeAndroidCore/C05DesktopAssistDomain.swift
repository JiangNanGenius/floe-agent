// SPDX-License-Identifier: MPL-2.0
//
// C05 desktop-assist domain: the two REAL backends that were previously nil
// in `C05RemoteDesktopToolEnvironment`.
//
//   1. Text anchors for `vnc.clickElement` / `rdp.clickElement`.
//      Android has no on-device vision recognizer. The adapter therefore
//      routes the trusted screenshot PNG through the task's EXISTING Linux
//      environment (`LocalShellService` behind `exec.shell`) and runs the
//      real Tesseract OCR engine there. Tesseract is a free Debian package,
//      not an App-downloaded model and not a hidden paid cloud call. The PNG
//      is staged inside the task workspace (the only host/guest shared
//      surface), the command is bounded and journaled by the same service as
//      ordinary shell work, and the staged file is removed immediately.
//      Anchors carry task/session/profile/endpoint/frame/revision/digest
//      ownership and are re-validated after the asynchronous OCR pass.
//
//   2. Approved secure credential cards for `typeCredential`.
//      The resolver reuses the ORIGINAL `FloePersistence.CredentialStore`
//      metadata and the ORIGINAL `AndroidCredentialVault` secret gateway
//      (AndroidKeystore). It accepts only card kinds that make sense for
//      typing into a remote desktop (website password / generic token), only
//      the task/workspace/vault owners that produced the card, and only a
//      host-scoped card for the exact `RemoteHostProfile` it names. The
//      secret bytes are resolved only after the tool's approval/runtime-
//      authority gate, the live session/target is re-validated after every
//      await, revocation (record deletion or replacement) is re-read, and
//      the bytes are zeroed by the caller after the protocol injection.
//
// This file owns no store, no schema, no bridge and no UI. It is a domain
// adapter over existing authorities; the App settings screen and the channel
// helper live in `C05DesktopAssistBindings`/`feature/desktopassist`.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools

// MARK: - Errors

public enum C05DesktopAssistError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured(String)
    case invalidRequest(String)
    case workspaceUnavailable
    case workspaceScopeDenied(String)
    case stagingUnavailable(String)
    case engineUnavailable(String)
    case enginePreparationFailed(String)
    case recognitionFailed(String)
    case staleEvidence(String)
    case liveSessionChanged
    case credentialUnavailable(String)
    case credentialScopeDenied(String)
    case credentialKindDenied(String)
    case credentialHostMismatch
    case credentialRevoked
    case credentialTooLarge
    case cardNotFound
    case cardLabelInvalid
    case cardKindInvalid

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let value): return value
        case .invalidRequest(let value): return value
        case .workspaceUnavailable:
            return "The task has no workspace root; Linux text recognition is unavailable"
        case .workspaceScopeDenied(let value): return value
        case .stagingUnavailable(let value): return value
        case .engineUnavailable(let value): return value
        case .enginePreparationFailed(let value): return value
        case .recognitionFailed(let value): return value
        case .staleEvidence(let value): return value
        case .liveSessionChanged:
            return "The remote desktop session or target changed during the operation; nothing was typed or sent"
        case .credentialUnavailable(let value): return value
        case .credentialScopeDenied(let value): return value
        case .credentialKindDenied(let value): return value
        case .credentialHostMismatch:
            return "The saved credential card belongs to a different remote host"
        case .credentialRevoked:
            return "The saved credential card was removed or changed during this operation"
        case .credentialTooLarge:
            return "The saved credential is empty or exceeds the 4 KiB typing limit"
        case .cardNotFound:
            return "The selected secure credential card no longer exists"
        case .cardLabelInvalid:
            return "A credential card needs a non-empty label of at most 200 characters"
        case .cardKindInvalid:
            return "Only password or generic-token cards can be typed into a remote desktop"
        }
    }

    /// Stable machine code for tool/bridge output. Never prose from a
    /// remote service and never secret material.
    public var code: String {
        switch self {
        case .notConfigured: return "desktopAssistNotConfigured"
        case .invalidRequest: return "desktopAssistInvalidRequest"
        case .workspaceUnavailable: return "desktopAssistNoWorkspace"
        case .workspaceScopeDenied: return "desktopAssistWorkspaceScopeDenied"
        case .stagingUnavailable: return "desktopAssistStagingUnavailable"
        case .engineUnavailable: return "desktopAssistEngineUnavailable"
        case .enginePreparationFailed: return "desktopAssistEnginePrepareFailed"
        case .recognitionFailed: return "desktopAssistRecognitionFailed"
        case .staleEvidence: return "desktopAssistStaleEvidence"
        case .liveSessionChanged: return "desktopAssistSessionChanged"
        case .credentialUnavailable: return "desktopAssistCredentialUnavailable"
        case .credentialScopeDenied: return "desktopAssistCardScopeDenied"
        case .credentialKindDenied: return "desktopAssistCardKindDenied"
        case .credentialHostMismatch: return "desktopAssistCardHostMismatch"
        case .credentialRevoked: return "desktopAssistCardRevoked"
        case .credentialTooLarge: return "desktopAssistCredentialTooLarge"
        case .cardNotFound: return "desktopAssistCardNotFound"
        case .cardLabelInvalid: return "desktopAssistCardLabelInvalid"
        case .cardKindInvalid: return "desktopAssistCardKindInvalid"
        }
    }
}

// MARK: - Frame ownership

/// The exact live frame the recognizer is allowed to describe. Every field is
/// derived from the real tool-managed session, never from model text, and
/// `isCurrent` re-reads the SAME fences after the OCR await.
public struct C05DesktopFrameOwnership: Sendable {
    public let taskID: UUID
    public let sessionID: UUID
    public let protocolName: String
    public let profileID: UUID
    public let endpointID: UUID
    public let target: String
    public let frameRevision: UInt64
    public let capturedAt: Date
    public let screenshotSHA256: String
    /// `true` only while the handle still belongs to the same owner/epoch,
    /// the same session is connected, and `frameRevision` is still current.
    public let isCurrent: @Sendable () -> Bool

    public init(
        taskID: UUID,
        sessionID: UUID,
        protocolName: String,
        profileID: UUID,
        endpointID: UUID,
        target: String,
        frameRevision: UInt64,
        capturedAt: Date,
        screenshotSHA256: String,
        isCurrent: @escaping @Sendable () -> Bool
    ) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.protocolName = protocolName
        self.profileID = profileID
        self.endpointID = endpointID
        self.target = target
        self.frameRevision = frameRevision
        self.capturedAt = capturedAt
        self.screenshotSHA256 = screenshotSHA256
        self.isCurrent = isCurrent
    }
}

public struct C05DesktopTextRecognitionRequest: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public let ownership: C05DesktopFrameOwnership
    public let context: ToolContext

    public init(
        png: Data,
        width: Int,
        height: Int,
        ownership: C05DesktopFrameOwnership,
        context: ToolContext
    ) {
        self.png = png
        self.width = width
        self.height = height
        self.ownership = ownership
        self.context = context
    }
}

/// Contextual recognizer seam. Keeping the `ToolContext` in the request is
/// what lets the Linux adapter run under the SAME approved task/environment/
/// journal as `exec.shell` instead of inventing a second execution route.
public protocol C05RemoteDesktopContextualTextRecognizing: Sendable {
    func recognize(_ request: C05DesktopTextRecognitionRequest) async throws
        -> [C05RemoteToolTextElement]
}

public struct C05TextRecognitionReadiness: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case ready, preparing, unavailable
    }

    public let state: State
    public let engine: String
    public let version: String?
    public let languages: [String]
    public let reason: String?
    public let preparationCommand: String?

    public init(
        state: State,
        engine: String = "tesseract",
        version: String? = nil,
        languages: [String] = [],
        reason: String? = nil,
        preparationCommand: String? = nil
    ) {
        self.state = state
        self.engine = engine
        self.version = version
        self.languages = languages
        self.reason = reason
        self.preparationCommand = preparationCommand
    }

    public static let unavailableWithoutHint = C05TextRecognitionReadiness(
        state: .unavailable,
        reason: "The Linux text-recognition engine is not available"
    )
}

public protocol C05RemoteDesktopTextRecognitionPreparing: Sendable {
    /// Best-effort, bounded preparation invoked from an explicitly
    /// side-effecting connect/reconnect (never from the read-only observe).
    func prepare(context: ToolContext) async -> C05TextRecognitionReadiness
}

// MARK: - Linux command seam

public struct C05LinuxOCRCommand: Sendable {
    public let command: String
    public let cwd: String
    public let timeout: TimeInterval
    public let maxOutputBytes: Int
    public let context: ToolContext

    public init(
        command: String,
        cwd: String = ".",
        timeout: TimeInterval,
        maxOutputBytes: Int,
        context: ToolContext
    ) {
        self.command = command
        self.cwd = cwd
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.context = context
    }
}

public enum C05LinuxOCRCommandOutcome: Sendable, Equatable {
    case exited(code: Int32, output: String, truncated: Bool)
    case timedOut(output: String)
    case cancelled
    case notStarted(String)
    case failed(String)
    case blocked(String)
}

public protocol C05LinuxOCRCommandRunning: Sendable {
    func run(_ command: C05LinuxOCRCommand) async -> C05LinuxOCRCommandOutcome
}

// MARK: - Tesseract configuration

public struct C05LinuxTesseractConfiguration: Sendable, Equatable {
    public var stagingDirectory: String = ".floe"
    public var stagingSubdirectory: String = "desktopassist/ocr"
    public var probeTimeout: TimeInterval = 20
    public var installTimeout: TimeInterval = 90
    public var recognitionTimeout: TimeInterval = 60
    public var maximumOutputBytes: Int = 256 * 1_024
    public var maximumLanguages: Int = 4
    public var maximumElements: Int = 400
    public var maximumElementTextBytes: Int = 500
    public var minimumConfidence: Double = 0.30
    public var staleStagingAge: TimeInterval = 60 * 60
    public var readinessTTL: TimeInterval = 300

    public init() {}

    public static let preparationCommand =
        "DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y --no-install-recommends "
        + "tesseract-ocr tesseract-ocr-eng tesseract-ocr-chi-sim"
}

// MARK: - Tesseract TSV parser

/// Pure parser for `tesseract … tsv` output. It never invents a word: every
/// element is the union of real level-5 word rows from the recognizer, and
/// rows that violate the image bounds or the closed column grammar are
/// discarded instead of guessed.
public enum C05TesseractTSVParser {
    struct Word: Sendable, Equatable {
        let page: Int
        let block: Int
        let paragraph: Int
        let line: Int
        let word: Int
        let text: String
        let confidence: Double
        let left: Int
        let top: Int
        let width: Int
        let height: Int
    }

    struct Line: Sendable, Equatable {
        let page: Int
        let block: Int
        let paragraph: Int
        let line: Int
        var text: String
        var confidenceSum: Double
        var count: Int
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int
    }

    public static func parse(
        _ output: String,
        width: Int,
        height: Int,
        configuration: C05LinuxTesseractConfiguration = C05LinuxTesseractConfiguration()
    ) throws -> [C05RemoteToolTextElement] {
        guard width > 0, height > 0 else {
            throw C05DesktopAssistError.invalidRequest("Screenshot dimensions are invalid")
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: { $0.hasPrefix("level\t") || $0.hasPrefix("level ") }) else {
            throw C05DesktopAssistError.recognitionFailed("Tesseract did not return its TSV contract")
        }
        var grouped: [String: Line] = [:]
        var order: [String] = []
        for rawLine in lines {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 12,
                  let level = Int(columns[0]), level == 5,
                  let page = Int(columns[1]),
                  let block = Int(columns[2]),
                  let paragraph = Int(columns[3]),
                  let lineNumber = Int(columns[4]),
                  let wordNumber = Int(columns[5]),
                  let left = Int(columns[6]),
                  let top = Int(columns[7]),
                  let wordWidth = Int(columns[8]),
                  let wordHeight = Int(columns[9]),
                  let rawConfidence = Double(columns[10]) else { continue }
            let text = columns[11...].joined(separator: "\t")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  wordWidth > 0, wordHeight > 0,
                  left >= 0, top >= 0,
                  left + wordWidth <= width,
                  top + wordHeight <= height,
                  rawConfidence.isFinite else { continue }
            let confidence = min(1, max(0, rawConfidence / 100))
            guard confidence >= configuration.minimumConfidence else { continue }
            let key = "\(page)-\(block)-\(paragraph)-\(lineNumber)"
            if var existing = grouped[key] {
                existing.text += existing.text.isEmpty ? text : " " + text
                existing.confidenceSum += confidence
                existing.count += 1
                existing.left = min(existing.left, left)
                existing.top = min(existing.top, top)
                existing.right = max(existing.right, left + wordWidth)
                existing.bottom = max(existing.bottom, top + wordHeight)
                grouped[key] = existing
            } else {
                grouped[key] = Line(
                    page: page, block: block, paragraph: paragraph, line: lineNumber,
                    text: text, confidenceSum: confidence, count: 1,
                    left: left, top: top,
                    right: left + wordWidth, bottom: top + wordHeight
                )
                order.append(key)
            }
            _ = wordNumber
        }
        let values = order.compactMap { grouped[$0] }
            .sorted {
                if $0.top != $1.top { return $0.top < $1.top }
                if $0.left != $1.left { return $0.left < $1.left }
                if $0.page != $1.page { return $0.page < $1.page }
                if $0.block != $1.block { return $0.block < $1.block }
                if $0.paragraph != $1.paragraph { return $0.paragraph < $1.paragraph }
                return $0.line < $1.line
            }
        var elements: [C05RemoteToolTextElement] = []
        elements.reserveCapacity(min(values.count, configuration.maximumElements))
        for value in values.prefix(configuration.maximumElements) {
            guard !value.text.isEmpty else { continue }
            let text = String(value.text.prefix(configuration.maximumElementTextBytes))
            guard text.utf8.count <= configuration.maximumElementTextBytes else { continue }
            let elementWidth = max(1, value.right - value.left)
            let elementHeight = max(1, value.bottom - value.top)
            guard value.left >= 0, value.top >= 0,
                  value.left + elementWidth <= width,
                  value.top + elementHeight <= height else { continue }
            elements.append(C05RemoteToolTextElement(
                reference: "text-\(elements.count + 1)",
                text: text,
                confidence: min(1, max(0, value.confidenceSum / Double(max(1, value.count)))),
                x: value.left,
                y: value.top,
                width: elementWidth,
                height: elementHeight
            ))
        }
        return elements
    }
}

// MARK: - Linux Tesseract recognizer

/// Actor-serialized real OCR adapter. The actor also owns the bounded
/// readiness cache so concurrent observes do not run the same probe twice.
public actor C05LinuxTesseractRecognizer:
    C05RemoteDesktopContextualTextRecognizing,
    C05RemoteDesktopTextRecognitionPreparing {

    private struct CachedReadiness {
        let readiness: C05TextRecognitionReadiness
        let checkedAt: Date
    }

    private let runner: any C05LinuxOCRCommandRunning
    private let configuration: C05LinuxTesseractConfiguration
    private let now: @Sendable () -> Date
    private var readinessCache: [String: CachedReadiness] = [:]
    private var preparingKeys: Set<String> = []

    public init(
        runner: any C05LinuxOCRCommandRunning,
        configuration: C05LinuxTesseractConfiguration = C05LinuxTesseractConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.configuration = configuration
        self.now = now
    }

    // MARK: Readiness

    private func cacheKey(_ context: ToolContext) -> String {
        let workspace = context.workspaceRootURL?
            .standardizedFileURL.resolvingSymlinksInPath().path ?? "-"
        let workspaceHash = String(FloeDigest.sha256Hex(Data(workspace.utf8)).prefix(16))
        return [
            context.conversationID?.uuidString ?? context.runID.uuidString,
            context.environmentID ?? "-",
            workspaceHash,
        ].joined(separator: "|")
    }

    public func readiness(context: ToolContext) async -> C05TextRecognitionReadiness {
        let key = cacheKey(context)
        if let cached = readinessCache[key],
           now().timeIntervalSince(cached.checkedAt) < configuration.readinessTTL {
            return cached.readiness
        }
        let readiness = await probe(context: context)
        if readiness.state != .preparing {
            store(readiness, key: key)
        }
        return readiness
    }

    public func prepare(context: ToolContext) async -> C05TextRecognitionReadiness {
        let key = cacheKey(context)
        if let cached = readinessCache[key],
           now().timeIntervalSince(cached.checkedAt) < configuration.readinessTTL {
            if cached.readiness.state == .ready { return cached.readiness }
            // Do not retry a failed package install on every connect; a
            // short backoff keeps an unavailable engine honest and cheap.
            if cached.readiness.state == .unavailable,
               now().timeIntervalSince(cached.checkedAt) < 60 {
                return cached.readiness
            }
        }
        // A second connect/observe for the same task never starts a parallel
        // package install; it waits for the one preparation actor pass.
        if preparingKeys.contains(key) {
            return C05TextRecognitionReadiness(
                state: .preparing,
                reason: "The Linux text-recognition engine is being prepared",
                preparationCommand: C05LinuxTesseractConfiguration.preparationCommand
            )
        }
        preparingKeys.insert(key)
        defer { preparingKeys.remove(key) }

        var readiness = await probe(context: context)
        if readiness.state == .ready {
            store(readiness, key: key)
            return readiness
        }
        // Real distro-package preparation through the SAME shell service.
        // Bounded to two attempts: with optional CJK data first, then the
        // core English package. Any failure is reported, never hidden.
        var lastFailure: String?
        for command in Self.preparationCommands {
            let outcome = await runner.run(C05LinuxOCRCommand(
                command: command,
                timeout: configuration.installTimeout,
                maxOutputBytes: configuration.maximumOutputBytes,
                context: context
            ))
            switch outcome {
            case .exited(let code, let output, _):
                if code != 0 {
                    lastFailure = Self.boundedReason(output, exit: code)
                }
            case .timedOut:
                lastFailure = "Tesseract preparation timed out"
            case .cancelled:
                return C05TextRecognitionReadiness(
                    state: .unavailable,
                    reason: "Tesseract preparation was cancelled",
                    preparationCommand: C05LinuxTesseractConfiguration.preparationCommand
                )
            case .notStarted(let reason):
                lastFailure = reason
            case .failed(let reason):
                lastFailure = Self.sanitize(reason)
            case .blocked(let reason):
                lastFailure = reason
            }
            readiness = await probe(context: context)
            if readiness.state == .ready {
                store(readiness, key: key)
                return readiness
            }
        }
        let result = C05TextRecognitionReadiness(
            state: .unavailable,
            reason: lastFailure ?? readiness.reason
                ?? "The Linux text-recognition engine could not be prepared",
            preparationCommand: C05LinuxTesseractConfiguration.preparationCommand
        )
        store(result, key: key)
        return result
    }

    private func store(_ readiness: C05TextRecognitionReadiness, key: String) {
        // Bounded cache: 16 live task keys is more than the bounded task
        // concurrency and keeps a long-lived process from growing forever.
        if readinessCache.count >= 16, readinessCache[key] == nil {
            let oldest = readinessCache.min { $0.value.checkedAt < $1.value.checkedAt }?.key
            if let oldest { readinessCache.removeValue(forKey: oldest) }
        }
        readinessCache[key] = CachedReadiness(readiness: readiness, checkedAt: now())
    }

    private func probe(context: ToolContext) async -> C05TextRecognitionReadiness {
        let outcome = await runner.run(C05LinuxOCRCommand(
            command: Self.probeCommand,
            timeout: configuration.probeTimeout,
            maxOutputBytes: 16 * 1_024,
            context: context
        ))
        switch outcome {
        case .exited(let code, let output, _):
            guard code == 0 else {
                return C05TextRecognitionReadiness(
                    state: .unavailable,
                    reason: Self.boundedReason(output, exit: code),
                    preparationCommand: C05LinuxTesseractConfiguration.preparationCommand
                )
            }
            if output.contains(Self.missingMarker) {
                return C05TextRecognitionReadiness(
                    state: .unavailable,
                    reason: "Tesseract is not installed in the task Linux environment",
                    preparationCommand: C05LinuxTesseractConfiguration.preparationCommand
                )
            }
            guard let split = output.range(of: Self.languageMarker) else {
                return C05TextRecognitionReadiness(
                    state: .unavailable,
                    reason: "Tesseract did not report its language set",
                    preparationCommand: C05LinuxTesseractConfiguration.preparationCommand
                )
            }
            let versionText = String(output[output.startIndex..<split.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let version = versionText.split(separator: "\n").first.map(String.init)
            let languages = String(output[split.upperBound...])
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { token in
                    token.range(of: #"^[a-z0-9_]{2,32}$"#, options: .regularExpression) != nil
                }
            guard !languages.isEmpty else {
                return C05TextRecognitionReadiness(
                    state: .unavailable,
                    reason: "Tesseract has no trained language data",
                    preparationCommand: C05LinuxTesseractConfiguration.preparationCommand
                )
            }
            return C05TextRecognitionReadiness(
                state: .ready,
                version: version,
                languages: Array(languages.prefix(configuration.maximumLanguages))
            )
        case .timedOut:
            return C05TextRecognitionReadiness(
                state: .unavailable,
                reason: "The Linux text-recognition probe timed out",
                preparationCommand: C05LinuxTesseractConfiguration.preparationCommand
            )
        case .cancelled:
            return C05TextRecognitionReadiness(state: .unavailable, reason: "The probe was cancelled")
        case .notStarted(let reason):
            return C05TextRecognitionReadiness(state: .unavailable, reason: reason)
        case .failed(let reason):
            return C05TextRecognitionReadiness(state: .unavailable, reason: Self.sanitize(reason))
        case .blocked(let reason):
            return C05TextRecognitionReadiness(state: .unavailable, reason: reason)
        }
    }

    // MARK: Recognize

    public func recognize(
        _ request: C05DesktopTextRecognitionRequest
    ) async throws -> [C05RemoteToolTextElement] {
        guard request.png.count <= C05RemoteDesktopToolLimits.maximumScreenshotBytes else {
            throw C05DesktopAssistError.invalidRequest("Screenshot exceeds the artifact limit")
        }
        guard Array(request.png.prefix(8)) == Self.pngSignature,
              let dimensions = Self.pngDimensions(request.png),
              dimensions.width == request.width,
              dimensions.height == request.height else {
            throw C05DesktopAssistError.invalidRequest(
                "Screenshot is not a PNG artifact with the observed dimensions"
            )
        }
        guard FloeDigest.sha256Hex(request.png)
            .caseInsensitiveCompare(request.ownership.screenshotSHA256) == .orderedSame else {
            throw C05DesktopAssistError.staleEvidence(
                "The screenshot does not match the observed frame digest"
            )
        }
        guard !request.context.temporaryReadOnly, !request.context.publicWebOnly else {
            throw C05DesktopAssistError.notConfigured(
                "Text recognition is unavailable in temporary chat"
            )
        }
        guard request.ownership.taskID == request.context.conversationID else {
            throw C05DesktopAssistError.invalidRequest(
                "The frame ownership does not belong to this task"
            )
        }
        guard request.ownership.isCurrent() else {
            throw C05DesktopAssistError.staleEvidence(
                "The remote screen changed before text recognition started"
            )
        }
        let readiness = await readiness(context: request.context)
        guard readiness.state == .ready else {
            throw C05DesktopAssistError.engineUnavailable(
                readiness.reason ?? "The Linux text-recognition engine is not available"
            )
        }
        let staged = try stage(png: request.png, context: request.context)
        defer { try? FileManager.default.removeItem(at: staged.url) }
        let languages = Self.languages(from: readiness.languages)
        let command = Self.recognitionCommand(
            imagePath: staged.relativePath,
            temporaryName: staged.identifier,
            languages: languages
        )
        let outcome = await runner.run(C05LinuxOCRCommand(
            command: command,
            timeout: configuration.recognitionTimeout,
            maxOutputBytes: configuration.maximumOutputBytes,
            context: request.context
        ))
        let output: String
        switch outcome {
        case .exited(let code, let text, let truncated):
            guard code == 0 else {
                throw C05DesktopAssistError.recognitionFailed(
                    Self.recognitionFailure(text, exit: code)
                )
            }
            guard !truncated else {
                throw C05DesktopAssistError.recognitionFailed(
                    "Tesseract output exceeded the bounded result window"
                )
            }
            output = text
        case .timedOut:
            throw C05DesktopAssistError.recognitionFailed("Text recognition timed out")
        case .cancelled:
            throw CancellationError()
        case .notStarted(let reason):
            throw C05DesktopAssistError.engineUnavailable(reason)
        case .failed(let reason):
            throw C05DesktopAssistError.recognitionFailed(Self.sanitize(reason))
        case .blocked(let reason):
            throw C05DesktopAssistError.recognitionFailed(reason)
        }
        let elements = try C05TesseractTSVParser.parse(
            output,
            width: request.width,
            height: request.height,
            configuration: configuration
        )
        // Post-await fence: an OCR pass can take seconds; anchors from a
        // frame that is no longer current must never be returned.
        guard request.ownership.isCurrent() else {
            throw C05DesktopAssistError.staleEvidence(
                "The remote screen changed during text recognition; the anchors were discarded"
            )
        }
        return elements
    }

    // MARK: Staging

    private struct StagedImage {
        let identifier: String
        let url: URL
        let relativePath: String
    }

    private func stage(png: Data, context: ToolContext) throws -> StagedImage {
        guard let root = context.workspaceRootURL, root.isFileURL else {
            throw C05DesktopAssistError.workspaceUnavailable
        }
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let identifier = UUID().uuidString.lowercased()
        let relativeDirectory = [
            configuration.stagingDirectory,
            configuration.stagingSubdirectory,
        ].joined(separator: "/")
        let relativePath = "\(relativeDirectory)/\(identifier).png"
        guard Self.isAuthorized(relativePath: relativePath, allowed: context.allowedWorkspacePaths) else {
            throw C05DesktopAssistError.workspaceScopeDenied(
                "This run's workspace scope does not permit desktop-assist staging"
            )
        }
        let directory = rootURL.appendingPathComponent(relativeDirectory, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try png.write(to: fileURL, options: [.atomic])
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw C05DesktopAssistError.stagingUnavailable(
                "The screenshot could not be staged in the task workspace"
            )
        }
        pruneStaging(directory: directory)
        return StagedImage(identifier: identifier, url: fileURL, relativePath: relativePath)
    }

    private func pruneStaging(directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now().addingTimeInterval(-configuration.staleStagingAge)
        for file in files.prefix(64) {
            let modified = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? manager.removeItem(at: file)
            }
        }
    }

    // MARK: Constants / helpers

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24,
              Array(data.prefix(8)) == pngSignature,
              data[12] == 0x49, data[13] == 0x48, data[14] == 0x44, data[15] == 0x52
        else { return nil }
        func integer(_ offset: Int) -> Int {
            (Int(data[offset]) << 24)
                | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8)
                | Int(data[offset + 3])
        }
        let width = integer(16)
        let height = integer(20)
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        return (width, height)
    }
    private static let missingMarker = "---FLOE-TESSERACT-MISSING---"
    private static let languageMarker = "---FLOE-TESSERACT-LANGS---"

    private static let probeCommand = """
    if command -v tesseract >/dev/null 2>&1; then \
    tesseract --version 2>&1 | head -n 1; \
    printf '%s\\n' '---FLOE-TESSERACT-LANGS---'; \
    tesseract --list-langs 2>/dev/null; \
    else printf '%s\\n' '---FLOE-TESSERACT-MISSING---'; fi
    """

    private static let preparationCommands: [String] = [
        C05LinuxTesseractConfiguration.preparationCommand,
        "DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y --no-install-recommends "
            + "tesseract-ocr tesseract-ocr-eng",
    ]

    static func languages(from available: [String]) -> String {
        var selected: [String] = []
        if available.contains("eng") { selected.append("eng") }
        for candidate in ["chi_sim", "chi_tra"] where available.contains(candidate) {
            selected.append(candidate)
        }
        if selected.isEmpty {
            selected = Array(available.prefix(2))
        }
        if selected.isEmpty { selected = ["eng"] }
        return selected.prefix(4).joined(separator: "+")
    }

    static func recognitionCommand(
        imagePath: String,
        temporaryName: String,
        languages: String
    ) -> String {
        let image = shellQuoted(imagePath)
        let guestImage = shellQuoted("/tmp/floe-ocr-\(temporaryName).png")
        let guestError = shellQuoted("/tmp/floe-ocr-\(temporaryName).err")
        let language = shellQuoted(languages)
        // Copy out of the exported workspace, then remove the workspace copy
        // immediately so a later guest→host export cannot re-create the
        // screenshot. Both temporary files live only in the guest /tmp and
        // are removed on every outcome of the chained command.
        return "cp \(image) \(guestImage) && rm -f \(image) && "
            + "OMP_THREAD_LIMIT=1 tesseract \(guestImage) stdout --psm 11 -l \(language) tsv "
            + "2> \(guestError); __floe_status=$?; "
            + "if [ $__floe_status -ne 0 ]; then printf '\\n---FLOE-OCR-ERROR---\\n'; "
            + "head -c 2048 \(guestError) 2>/dev/null; fi; "
            + "rm -f \(guestImage) \(guestError) \(image); exit $__floe_status"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isAuthorized(relativePath: String, allowed: [String]) -> Bool {
        guard !allowed.isEmpty else { return true }
        for raw in allowed {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if entry.isEmpty || entry == "." { return true }
            guard !entry.hasPrefix("/"),
                  !entry.split(separator: "/").contains("..") else { continue }
            if relativePath == entry || relativePath.hasPrefix(entry + "/") {
                return true
            }
        }
        return false
    }

    static func boundedReason(_ output: String, exit: Int32) -> String {
        let text = sanitize(output)
        let first = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if first.isEmpty { return "Linux command failed with exit \(exit)" }
        return "Linux command failed with exit \(exit): \(String(first.prefix(200)))"
    }

    static func recognitionFailure(_ output: String, exit: Int32) -> String {
        if let range = output.range(of: "---FLOE-OCR-ERROR---") {
            let detail = sanitize(String(output[range.upperBound...]))
            let first = detail.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            if !first.isEmpty {
                return "Tesseract failed: \(String(first.prefix(200)))"
            }
        }
        return "Tesseract failed with exit \(exit)"
    }

    /// Guest output can contain paths but never a credential; still bound and
    /// flatten it so a diagnostic cannot dump an unbounded log into the model
    /// context or the text-recognition result.
    static func sanitize(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\u{0}", with: "")
        return String(collapsed.prefix(2_048))
    }
}

/// Shared screenshot bound used by the tool and the Linux adapter.
public enum C05RemoteDesktopToolLimits {
    public static let maximumScreenshotBytes = 64 * 1_024 * 1_024
    public static let maximumTextElements = 400
}

// MARK: - Credential card store seam

/// Narrow seam over the ORIGINAL credential metadata store and vault. The
/// production conformance is a thin extension over `AndroidCredentialVault`
/// (see `C05DesktopAssistIntegration`); tests use a deterministic double.
public protocol C05DesktopCredentialCardStoring: Sendable {
    func credentialRecord(id: UUID) async throws -> CredentialRecord?
    func listCredentialRecords() async throws -> [CredentialRecord]
    func captureCredential(
        _ secret: Data,
        kind: CredentialKind,
        owner: CredentialOwner,
        label: String,
        hostID: UUID?,
        origin: String
    ) async throws -> CredentialHandle
    func resolveCredentialSecret(_ handle: CredentialHandle) async throws -> Data
    func replaceCredentialSecret(_ handle: CredentialHandle, secret: Data) async throws
    func updateCredentialLabel(_ handle: CredentialHandle, label: String) async throws
    func deleteCredential(_ handle: CredentialHandle) async throws
}

// MARK: - Credential card request / resolution

public struct C05DesktopCredentialCardRequest: Sendable {
    public let credentialID: UUID
    public let taskID: UUID
    public let runID: UUID
    public let protocolName: String
    public let profileID: UUID
    public let endpointID: UUID
    public let sessionID: UUID
    public let target: String
    public let owner: C05RemoteOwner
    public let approvalGrantID: UUID
    public let runtimeAuthorityID: UUID?
    /// Re-reads the SAME live owner/session/endpoint/target fence after every
    /// await. `false` aborts before any protocol input.
    public let isCurrent: @Sendable () -> Bool

    public init(
        credentialID: UUID,
        taskID: UUID,
        runID: UUID,
        protocolName: String,
        profileID: UUID,
        endpointID: UUID,
        sessionID: UUID,
        target: String,
        owner: C05RemoteOwner,
        approvalGrantID: UUID,
        runtimeAuthorityID: UUID?,
        isCurrent: @escaping @Sendable () -> Bool
    ) {
        self.credentialID = credentialID
        self.taskID = taskID
        self.runID = runID
        self.protocolName = protocolName
        self.profileID = profileID
        self.endpointID = endpointID
        self.sessionID = sessionID
        self.target = target
        self.owner = owner
        self.approvalGrantID = approvalGrantID
        self.runtimeAuthorityID = runtimeAuthorityID
        self.isCurrent = isCurrent
    }
}

public struct C05DesktopCredentialCardResolution: Sendable {
    public let credentialID: UUID
    public let kind: CredentialKind
    public let label: String
    public let ownerKind: String
    public let secret: Data

    public init(
        credentialID: UUID,
        kind: CredentialKind,
        label: String,
        ownerKind: String,
        secret: Data
    ) {
        self.credentialID = credentialID
        self.kind = kind
        self.label = label
        self.ownerKind = ownerKind
        self.secret = secret
    }
}

public protocol C05RemoteDesktopCredentialCardResolving: Sendable {
    func resolveCredentialCard(
        _ request: C05DesktopCredentialCardRequest
    ) async throws -> C05DesktopCredentialCardResolution
}

// MARK: - Settings card management values

public struct C05DesktopAssistCardMetadata: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let reference: String
    public let label: String
    public let kind: CredentialKind
    public let ownerKind: String
    public let hostID: UUID?
    public let updatedAt: Date
    public let typingAllowed: Bool

    public init(
        id: UUID,
        reference: String,
        label: String,
        kind: CredentialKind,
        ownerKind: String,
        hostID: UUID?,
        updatedAt: Date,
        typingAllowed: Bool
    ) {
        self.id = id
        self.reference = reference
        self.label = label
        self.kind = kind
        self.ownerKind = ownerKind
        self.hostID = hostID
        self.updatedAt = updatedAt
        self.typingAllowed = typingAllowed
    }
}

public protocol C05DesktopCredentialCardManaging: Sendable {
    func listCards() async throws -> [C05DesktopAssistCardMetadata]
    func createCard(
        label: String,
        kind: CredentialKind,
        secret: Data,
        hostID: UUID?
    ) async throws -> C05DesktopAssistCardMetadata
    func updateCard(
        id: UUID,
        label: String?,
        secret: Data?
    ) async throws -> C05DesktopAssistCardMetadata
    func deleteCard(id: UUID) async throws
}

// MARK: - Secure card resolver

/// Resolves one approved card only after the real scope checks. The actor is
/// deliberately small: metadata truth comes from the original
/// `CredentialStore`, secret bytes from the original
/// `AndroidCredentialVault.resolveForApprovedUse`.
public actor C05SecureCredentialCardResolver:
    C05RemoteDesktopCredentialCardResolving,
    C05DesktopCredentialCardManaging {

    /// Cards that may be typed into a remote-desktop focus. SSH passwords/
    /// private keys, provider API keys and VNC connection passwords are
    /// deliberately excluded: none of them is a desktop login secret, and
    /// typing one into an arbitrary remote window would leak it to the
    /// wrong target.
    public static let typingKinds: Set<CredentialKind> = [.websitePassword, .genericToken]

    public static let maximumSecretBytes = 4_096
    public static let maximumLabelCharacters = 200

    private let store: any C05DesktopCredentialCardStoring
    private let workspaceID: @Sendable (UUID) async -> UUID?
    private let now: @Sendable () -> Date

    public init(
        store: any C05DesktopCredentialCardStoring,
        workspaceID: @escaping @Sendable (UUID) async -> UUID? = { _ in nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.workspaceID = workspaceID
        self.now = now
    }

    // MARK: Typing resolution

    public func resolveCredentialCard(
        _ request: C05DesktopCredentialCardRequest
    ) async throws -> C05DesktopCredentialCardResolution {
        guard !request.owner.temporary else {
            throw C05DesktopAssistError.credentialScopeDenied(
                "Saved credentials are unavailable in temporary chat"
            )
        }
        guard request.owner.taskID == request.taskID,
              request.owner.nativeEpoch > 0 else {
            throw C05DesktopAssistError.invalidRequest(
                "The credential request is not bound to this task and runtime generation"
            )
        }
        guard request.protocolName == "vnc" || request.protocolName == "rdp" else {
            throw C05DesktopAssistError.invalidRequest(
                "Credential typing is only available for a VNC or RDP session"
            )
        }
        guard !request.target.isEmpty else {
            throw C05DesktopAssistError.invalidRequest("The credential request has no target")
        }
        guard request.isCurrent() else {
            throw C05DesktopAssistError.liveSessionChanged
        }
        guard let record = try await store.credentialRecord(id: request.credentialID) else {
            throw C05DesktopAssistError.credentialUnavailable(
                "The selected secure credential card does not exist"
            )
        }
        let taskWorkspaceID = await workspaceID(request.taskID)
        guard Self.isOwnerAuthorized(
            record.owner,
            taskID: request.taskID,
            workspaceID: taskWorkspaceID
        ) else {
            throw C05DesktopAssistError.credentialScopeDenied(
                "The selected credential card belongs to a different task or workspace"
            )
        }
        guard Self.typingKinds.contains(record.kind) else {
            throw C05DesktopAssistError.credentialKindDenied(
                "Only password or generic-token cards can be typed into a remote desktop"
            )
        }
        if let hostID = record.hostID, hostID != request.profileID {
            throw C05DesktopAssistError.credentialHostMismatch
        }
        guard request.isCurrent() else {
            throw C05DesktopAssistError.liveSessionChanged
        }
        let reference = CredentialHandle(id: request.credentialID)
        var secret: Data
        do {
            secret = try await store.resolveCredentialSecret(reference)
        } catch {
            throw C05DesktopAssistError.credentialUnavailable(
                "The saved credential could not be read from the device keystore"
            )
        }
        guard !secret.isEmpty, secret.count <= Self.maximumSecretBytes else {
            secret.resetBytes(in: secret.indices)
            throw C05DesktopAssistError.credentialTooLarge
        }
        // Revocation / replacement fence: the user may delete or replace the
        // card while the gateway read is awaiting. A stale read must never be
        // typed after that change.
        guard let current = try await store.credentialRecord(id: request.credentialID),
              Self.sameCard(record, current) else {
            secret.resetBytes(in: secret.indices)
            throw C05DesktopAssistError.credentialRevoked
        }
        guard request.isCurrent() else {
            secret.resetBytes(in: secret.indices)
            throw C05DesktopAssistError.liveSessionChanged
        }
        return C05DesktopCredentialCardResolution(
            credentialID: record.id,
            kind: record.kind,
            label: record.label,
            ownerKind: record.owner.kindName,
            secret: secret
        )
    }

    static func isOwnerAuthorized(
        _ owner: CredentialOwner,
        taskID: UUID,
        workspaceID: UUID?
    ) -> Bool {
        switch owner {
        case .vault:
            return true
        case .conversation(let id):
            return id == taskID
        case .workspace(let id):
            return workspaceID != nil && id == workspaceID
        }
    }

    static func sameCard(_ lhs: CredentialRecord, _ rhs: CredentialRecord) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.owner == rhs.owner
            && lhs.hostID == rhs.hostID
            && lhs.updatedAt == rhs.updatedAt
            && lhs.keychainAccount == rhs.keychainAccount
    }

    // MARK: Settings management (trusted host channel only)

    public func listCards() async throws -> [C05DesktopAssistCardMetadata] {
        let records = try await store.listCredentialRecords()
        return records
            .filter { Self.typingKinds.contains($0.kind) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(Self.metadata)
    }

    public func createCard(
        label: String,
        kind: CredentialKind,
        secret: Data,
        hostID: UUID?
    ) async throws -> C05DesktopAssistCardMetadata {
        guard Self.typingKinds.contains(kind) else {
            throw C05DesktopAssistError.cardKindInvalid
        }
        let trimmed = try Self.validatedLabel(label)
        guard !secret.isEmpty, secret.count <= Self.maximumSecretBytes else {
            throw C05DesktopAssistError.credentialTooLarge
        }
        var copy = secret
        defer { copy.resetBytes(in: copy.indices) }
        let handle = try await store.captureCredential(
            copy,
            kind: kind,
            owner: .vault,
            label: trimmed,
            hostID: hostID,
            origin: "desktopassist.settings"
        )
        guard let record = try await store.credentialRecord(id: handle.id) else {
            throw C05DesktopAssistError.credentialUnavailable(
                "The saved credential metadata could not be read back"
            )
        }
        return Self.metadata(record)
    }

    public func updateCard(
        id: UUID,
        label: String?,
        secret: Data?
    ) async throws -> C05DesktopAssistCardMetadata {
        guard let existing = try await store.credentialRecord(id: id) else {
            throw C05DesktopAssistError.cardNotFound
        }
        guard Self.typingKinds.contains(existing.kind) else {
            throw C05DesktopAssistError.cardKindInvalid
        }
        let handle = CredentialHandle(id: id)
        var changed = false
        if let label {
            let trimmed = try Self.validatedLabel(label)
            try await store.updateCredentialLabel(handle, label: trimmed)
            changed = true
        }
        if let secret {
            guard !secret.isEmpty, secret.count <= Self.maximumSecretBytes else {
                throw C05DesktopAssistError.credentialTooLarge
            }
            var copy = secret
            defer { copy.resetBytes(in: copy.indices) }
            try await store.replaceCredentialSecret(handle, secret: copy)
            changed = true
        }
        guard changed else {
            return Self.metadata(existing)
        }
        guard let record = try await store.credentialRecord(id: id) else {
            throw C05DesktopAssistError.cardNotFound
        }
        return Self.metadata(record)
    }

    public func deleteCard(id: UUID) async throws {
        guard try await store.credentialRecord(id: id) != nil else {
            throw C05DesktopAssistError.cardNotFound
        }
        try await store.deleteCredential(CredentialHandle(id: id))
    }

    static func validatedLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLabelCharacters else {
            throw C05DesktopAssistError.cardLabelInvalid
        }
        return trimmed
    }

    static func metadata(_ record: CredentialRecord) -> C05DesktopAssistCardMetadata {
        C05DesktopAssistCardMetadata(
            id: record.id,
            reference: "⟨credential:\(record.id.uuidString)⟩",
            label: record.label,
            kind: record.kind,
            ownerKind: record.owner.kindName,
            hostID: record.hostID,
            updatedAt: record.updatedAt,
            typingAllowed: typingKinds.contains(record.kind)
        )
    }
}
