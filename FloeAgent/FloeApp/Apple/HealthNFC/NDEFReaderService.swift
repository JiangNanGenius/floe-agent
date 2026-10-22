// FloeApp — one real foreground NFC NDEF reader session.
//
// Ownership: a process-wide gate admits exactly one session. A second task
// gets an explicit busy result instead of cancelling, replacing or stealing
// the first task's system sheet. The service retains the session and its
// weakly-referenced delegate for the whole read, so view lifetime is not part
// of the contract.
//
// Read-only: the delegate only connects to one tag, queries NDEF status and
// reads the NDEF message. There is no write, lock, raw-APDU, payment or URL
// execution path.

#if canImport(UIKit) && canImport(CoreNFC)
import Foundation
import UIKit
@preconcurrency import CoreNFC
import FloeTools

struct NDEFSessionOwner: Sendable, Equatable {
    var conversationID: UUID?
    var environmentID: String?
    var clientSessionID: String?
    var runID: UUID

    init(context: ToolContext) {
        self.conversationID = context.temporaryReadOnly || context.publicWebOnly
            ? nil
            : context.conversationID
        self.environmentID = context.temporaryReadOnly || context.publicWebOnly
            ? nil
            : context.environmentID
        self.clientSessionID = context.clientSessionID
        self.runID = context.runID
    }

    init(
        conversationID: UUID?,
        environmentID: String?,
        clientSessionID: String?,
        runID: UUID
    ) {
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.clientSessionID = clientSessionID
        self.runID = runID
    }
}

enum NDEFCancelSource: String, Sendable, Equatable {
    case user
    case task
}

enum NDEFInterruptionReason: String, Sendable, Equatable {
    case background
    case locked
    case system
}

enum NDEFSessionOutcome: Sendable, Equatable {
    case success(NDEFDecodedMessage)
    case unavailable
    case busy
    case cancelled(source: NDEFCancelSource)
    case timedOut
    case interrupted(reason: NDEFInterruptionReason)
    case tagNotNDEF
    case emptyTag
    case multipleTags(count: Int)
    case readFailed(code: String)
    case entitlementMissing
    case radioDisabled
    case ineligible
    case accessNotAccepted
    case internalFailure(code: String)
}

protocol NDEFReading: Sendable {
    var isAvailable: Bool { get }
    func read(
        owner: NDEFSessionOwner,
        timeout: TimeInterval,
        alertMessage: String,
        cancellation: CancellationToken
    ) async -> NDEFSessionOutcome
}

/// Testable single-session ownership gate. It never identifies the owner of
/// the active session in a refusal, so a second task cannot learn another
/// task's conversation identity.
final class NDEFSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeToken: UUID?
    private var activeOwner: NDEFSessionOwner?

    func acquire(owner: NDEFSessionOwner) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard activeToken == nil else { return nil }
        let token = UUID()
        activeToken = token
        activeOwner = owner
        return token
    }

    func release(token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard activeToken == token else { return }
        activeToken = nil
        activeOwner = nil
    }

    func isCurrent(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeToken == token
    }

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeToken != nil
    }
}

private final class NDEFOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NDEFSessionOutcome, Never>?
    private var result: NDEFSessionOutcome?

    func attach(_ continuation: CheckedContinuation<NDEFSessionOutcome, Never>) {
        let ready: NDEFSessionOutcome?
        lock.lock()
        if let result {
            ready = result
        } else {
            ready = nil
            self.continuation = continuation
        }
        lock.unlock()
        if let ready { continuation.resume(returning: ready) }
    }

    func finish(_ outcome: NDEFSessionOutcome) {
        let continuation: CheckedContinuation<NDEFSessionOutcome, Never>?
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

private final class NFCNDEFSessionBox: @unchecked Sendable {
    let session: NFCNDEFReaderSession
    init(_ session: NFCNDEFReaderSession) { self.session = session }
}

private final class NFCNDEFTagBox: @unchecked Sendable {
    let tag: any NFCNDEFTag
    init(_ tag: any NFCNDEFTag) { self.tag = tag }
}

private final class NDEFReaderDelegate: NSObject, NFCNDEFReaderSessionDelegate, @unchecked Sendable {
    weak var service: NDEFReaderService?
    let token: UUID

    init(service: NDEFReaderService, token: UUID) {
        self.service = service
        self.token = token
    }

    func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {}

    /// Required by the Objective-C protocol. Implementing `didDetect tags:`
    /// puts this session in read-write/tag mode, so this callback is not the
    /// data path; ignore it rather than double-resolving the session.
    func readerSession(
        _ session: NFCNDEFReaderSession,
        didDetectNDEFs messages: [NFCNDEFMessage]
    ) {}

    func readerSession(
        _ session: NFCNDEFReaderSession,
        didDetect tags: [any NFCNDEFTag]
    ) {
        service?.didDetect(tags: tags, token: token)
    }

    func readerSession(
        _ session: NFCNDEFReaderSession,
        didInvalidateWithError error: Error
    ) {
        service?.didInvalidate(error: error, token: token)
    }
}

final class NDEFReaderService: NSObject, NDEFReading, @unchecked Sendable {
    private final class Active: @unchecked Sendable {
        let token: UUID
        let owner: NDEFSessionOwner
        let gate: NDEFOnceGate
        let delegate: NDEFReaderDelegate
        let sessionBox: NFCNDEFSessionBox
        var timeoutItem: DispatchWorkItem?
        var pollTimer: DispatchSourceTimer?
        var backgroundObserver: NSObjectProtocol?
        var protectedDataObserver: NSObjectProtocol?
        var tagOperationStarted = false
        var finished = false

        init(
            token: UUID,
            owner: NDEFSessionOwner,
            gate: NDEFOnceGate,
            delegate: NDEFReaderDelegate,
            sessionBox: NFCNDEFSessionBox
        ) {
            self.token = token
            self.owner = owner
            self.gate = gate
            self.delegate = delegate
            self.sessionBox = sessionBox
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.floeagent.nfc.ndef")
    private let gate = NDEFSessionGate()
    private var active: Active?

    var isAvailable: Bool {
        NFCNDEFReaderSession.readingAvailable
    }

    func read(
        owner: NDEFSessionOwner,
        timeout: TimeInterval,
        alertMessage: String,
        cancellation: CancellationToken
    ) async -> NDEFSessionOutcome {
        guard isAvailable else { return .unavailable }
        if cancellation.isCancelled { return .cancelled(source: .task) }
        guard let token = gate.acquire(owner: owner) else { return .busy }

        let completion = NDEFOnceGate()
        let delegate = NDEFReaderDelegate(service: self, token: token)
        let session = NFCNDEFReaderSession(
            delegate: delegate,
            queue: queue,
            invalidateAfterFirstRead: false
        )
        session.alertMessage = alertMessage
        let active = Active(
            token: token,
            owner: owner,
            gate: completion,
            delegate: delegate,
            sessionBox: NFCNDEFSessionBox(session)
        )
        lock.withLock { self.active = active }

        scheduleTimeout(active, seconds: min(max(timeout, 5), 55))
        scheduleCancellation(active, cancellation: cancellation)
        scheduleLifecycleObservers(active)

        let sessionBox = active.sessionBox
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canBegin(token: token) else { return }
            sessionBox.session.begin()
        }

        return await withCheckedContinuation { continuation in
            completion.attach(continuation)
        }
    }

    // MARK: - Session callbacks

    func didDetect(tags: [any NFCNDEFTag], token: UUID) {
        guard let session = beginTagOperation(token: token) else { return }
        guard tags.count == 1, let tag = tags.first else {
            resolve(
                token: token,
                outcome: .multipleTags(count: tags.count),
                invalidate: true
            )
            return
        }
        let tagBox = NFCNDEFTagBox(tag)
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                self.resolve(
                    token: token,
                    outcome: .readFailed(code: self.readErrorCode(error)),
                    invalidate: true
                )
                return
            }
            tagBox.tag.queryNDEFStatus { [weak self] status, _, error in
                guard let self else { return }
                if let error {
                    self.resolve(
                        token: token,
                        outcome: .readFailed(code: self.readErrorCode(error)),
                        invalidate: true
                    )
                    return
                }
                switch status {
                case .notSupported:
                    self.resolve(token: token, outcome: .tagNotNDEF, invalidate: true)
                case .readOnly, .readWrite:
                    tagBox.tag.readNDEF { [weak self] message, error in
                        guard let self else { return }
                        if let error {
                            let outcome: NDEFSessionOutcome =
                                self.isZeroLengthMessage(error) ? .emptyTag : .readFailed(code: self.readErrorCode(error))
                            self.resolve(token: token, outcome: outcome, invalidate: true)
                            return
                        }
                        guard let message else {
                            self.resolve(
                                token: token,
                                outcome: .readFailed(code: "emptyNDEFMessage"),
                                invalidate: true
                            )
                            return
                        }
                        let raw = message.records.map { payload in
                            NDEFRawRecord(
                                typeNameFormat: payload.typeNameFormat.rawValue,
                                type: payload.type,
                                identifier: payload.identifier.isEmpty ? nil : payload.identifier,
                                payload: payload.payload
                            )
                        }
                        let decoded = NDEFDecoder.decode(raw)
                        self.resolve(
                            token: token,
                            outcome: .success(decoded),
                            invalidate: true
                        )
                    }
                @unknown default:
                    self.resolve(
                        token: token,
                        outcome: .readFailed(code: "ndefStatusUnknown"),
                        invalidate: true
                    )
                }
            }
        }
    }

    func didInvalidate(error: Error, token: UUID) {
        let alreadyFinished: Bool
        lock.lock()
        if let active, active.token == token {
            alreadyFinished = active.finished
        } else {
            alreadyFinished = true
        }
        lock.unlock()

        if !alreadyFinished {
            resolve(token: token, outcome: outcome(for: error), invalidate: false)
        }
        releaseIfFinished(token: token)
    }

    // MARK: - Session state

    private func canBegin(token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active?.token == token && active?.finished == false
    }

    private func beginTagOperation(token: UUID) -> NFCNDEFReaderSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let active, active.token == token, !active.finished,
              !active.tagOperationStarted else { return nil }
        active.tagOperationStarted = true
        return active.sessionBox.session
    }

    private func scheduleTimeout(_ active: Active, seconds: TimeInterval) {
        let token = active.token
        let item = DispatchWorkItem { [weak self] in
            self?.resolve(token: token, outcome: .timedOut, invalidate: true)
        }
        active.timeoutItem = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func scheduleCancellation(
        _ active: Active,
        cancellation: CancellationToken
    ) {
        let token = active.token
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if cancellation.isCancelled {
                self.resolve(
                    token: token,
                    outcome: .cancelled(source: .task),
                    invalidate: true
                )
            }
        }
        timer.resume()
        active.pollTimer = timer
    }

    private func scheduleLifecycleObservers(_ active: Active) {
        let center = NotificationCenter.default
        let token = active.token
        active.backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resolve(
                token: token,
                outcome: .interrupted(reason: .background),
                invalidate: true
            )
        }
        active.protectedDataObserver = center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resolve(
                token: token,
                outcome: .interrupted(reason: .locked),
                invalidate: true
            )
        }
    }

    private func resolve(
        token: UUID,
        outcome: NDEFSessionOutcome,
        invalidate: Bool
    ) {
        let session: NFCNDEFReaderSession?
        let completion: NDEFOnceGate?
        lock.lock()
        guard let active, active.token == token, !active.finished else {
            lock.unlock()
            return
        }
        active.finished = true
        active.timeoutItem?.cancel()
        active.timeoutItem = nil
        active.pollTimer?.cancel()
        active.pollTimer = nil
        if let observer = active.backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            active.backgroundObserver = nil
        }
        if let observer = active.protectedDataObserver {
            NotificationCenter.default.removeObserver(observer)
            active.protectedDataObserver = nil
        }
        session = invalidate ? active.sessionBox.session : nil
        completion = active.gate
        lock.unlock()

        completion?.finish(outcome)
        if let session {
            // A read-write NDEF session may use the error-message variant; a
            // plain invalidate is enough and avoids inventing user copy here.
            session.invalidate()
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.releaseIfFinished(token: token)
        }
    }

    private func releaseIfFinished(token: UUID) {
        lock.lock()
        guard let active, active.token == token, active.finished else {
            lock.unlock()
            return
        }
        self.active = nil
        lock.unlock()
        gate.release(token: token)
    }

    // MARK: - Error mapping

    private func outcome(for error: Error) -> NDEFSessionOutcome {
        guard let readerError = error as? NFCReaderError else {
            return .readFailed(code: "unknown")
        }
        switch readerError.code {
        case .readerSessionInvalidationErrorUserCanceled:
            return .cancelled(source: .user)
        case .readerSessionInvalidationErrorSessionTimeout:
            return .timedOut
        case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly:
            return .interrupted(reason: interruptionReason())
        case .readerSessionInvalidationErrorSystemIsBusy:
            return .busy
        case .readerSessionInvalidationErrorFirstNDEFTagRead:
            return .readFailed(code: "firstTagRead")
        case .readerErrorUnsupportedFeature:
            return .unavailable
        case .readerErrorSecurityViolation:
            return .entitlementMissing
        case .readerErrorRadioDisabled:
            return .radioDisabled
        case .readerErrorIneligible:
            return .ineligible
        case .readerErrorAccessNotAccepted:
            return .accessNotAccepted
        case .ndefReaderSessionErrorZeroLengthMessage:
            return .emptyTag
        default:
            return .readFailed(code: "nfcError\(readerError.code.rawValue)")
        }
    }

    private func readErrorCode(_ error: Error) -> String {
        guard let readerError = error as? NFCReaderError else { return "unknown" }
        switch readerError.code {
        case .readerTransceiveErrorTagConnectionLost:
            return "tagConnectionLost"
        case .readerTransceiveErrorRetryExceeded:
            return "retryExceeded"
        case .readerTransceiveErrorTagResponseError:
            return "tagResponseError"
        case .readerTransceiveErrorSessionInvalidated:
            return "sessionInvalidated"
        case .readerTransceiveErrorTagNotConnected:
            return "tagNotConnected"
        case .readerTransceiveErrorPacketTooLong:
            return "packetTooLong"
        case .ndefReaderSessionErrorZeroLengthMessage:
            return "zeroLengthMessage"
        default:
            return "nfcError\(readerError.code.rawValue)"
        }
    }

    private func isZeroLengthMessage(_ error: Error) -> Bool {
        guard let readerError = error as? NFCReaderError else { return false }
        return readerError.code == .ndefReaderSessionErrorZeroLengthMessage
    }

    private func interruptionReason() -> NDEFInterruptionReason {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                let app = UIApplication.shared
                if app.applicationState != .active { return .background }
                if !app.isProtectedDataAvailable { return .locked }
                return .system
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let app = UIApplication.shared
                if app.applicationState != .active { return .background }
                if !app.isProtectedDataAvailable { return .locked }
                return .system
            }
        }
    }
}
#endif
