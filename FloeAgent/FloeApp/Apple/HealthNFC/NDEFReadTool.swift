// FloeApp — `apple.nfc.readNDEF`, one foreground read-only NDEF scan.
//
// The OS permission prompt is not task authorization: the tool is still
// exposed only through the existing task/tool permission layer. The scan is
// user-triggered by the model call, foreground-only and never opens a URL or
// executes payload content.

#if canImport(UIKit) && canImport(CoreNFC)
import Foundation
import FloeCore
import FloeTools

struct AppleNDEFReadTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var timeoutSeconds: Int?

        init(timeoutSeconds: Int? = nil) {
            self.timeoutSeconds = timeoutSeconds
        }
    }

    static let name = "apple.nfc.readNDEF"
    static let toolDescription = """
    Scan ONE NFC tag in the foreground and return its bounded NDEF records (text, URI, MIME and preserved raw metadata). \
    This is read-only: it never writes or locks a tag, sends raw APDUs, emulates payment, or opens/forwards a URL. \
    Requires an iPhone with NFC reading and the app in the foreground; it is unavailable on iPad and in the Simulator. \
    A scan is user-triggered, the system sheet is owned by this task, and a concurrent scan returns busy instead of \
    stealing another task's session. Limits: one tag, at most 32 records/32768 payload bytes, and a 5...55 second \
    Floe session timeout (the system also enforces a 60 second limit). Malformed/unsupported records are reported with \
    bounded raw prefixes and hashes, never silently converted.
    """
    static let parametersJSON = #"{"type":"object","properties":{"timeoutSeconds":{"type":"integer","minimum":5,"maximum":55,"description":"Floe scan deadline in seconds; defaults to 20."}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .sendsDataToProvider]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    private let service: any NDEFReading
    private let isForeground: @Sendable () async -> Bool
    private let alertMessage: String

    init(
        service: any NDEFReading,
        isForeground: @escaping @Sendable () async -> Bool,
        alertMessage: String
    ) {
        self.service = service
        self.isForeground = isForeground
        self.alertMessage = alertMessage
    }

    func validate(_ args: Arguments) throws {
        let timeout = args.timeoutSeconds ?? 20
        guard (5...55).contains(timeout) else {
            throw FloeError.validationFailed("timeoutSeconds must be 5...55")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return AppleToolOutput.make(
                "status=unavailable capability=nfc reason=temporaryChat",
                exitStatus: 75
            )
        }
        let timeout = args.timeoutSeconds ?? 20
        guard (5...55).contains(timeout) else {
            throw FloeError.validationFailed("timeoutSeconds must be 5...55")
        }
        guard await isForeground() else {
            return AppleToolOutput.make(
                "status=foregroundRequired capability=nfc",
                exitStatus: 75
            )
        }
        guard service.isAvailable else {
            return AppleToolOutput.make(
                "status=unavailable capability=nfc hardwareOrRuntime=unsupported retryable=false",
                exitStatus: 77
            )
        }

        let outcome = await service.read(
            owner: NDEFSessionOwner(context: context),
            timeout: TimeInterval(timeout),
            alertMessage: alertMessage,
            cancellation: context.cancellation
        )
        switch outcome {
        case .success(let message):
            return AppleToolOutput.make(
                NDEFOutput.render(
                    message,
                    sessionTimeoutSeconds: timeout
                )
            )
        case .unavailable:
            return AppleToolOutput.make(
                "status=unavailable capability=nfc hardwareOrRuntime=unsupported retryable=false",
                exitStatus: 77
            )
        case .busy:
            return AppleToolOutput.make(
                "status=busy capability=nfc retryable=true note=anotherScanOwnsTheReader",
                exitStatus: 75
            )
        case .cancelled(let source):
            return AppleToolOutput.make(
                "status=cancelled capability=nfc source=\(source.rawValue)",
                exitStatus: 130
            )
        case .timedOut:
            return AppleToolOutput.make(
                "status=timedOut capability=nfc retryable=true",
                exitStatus: 124
            )
        case .interrupted(let reason):
            return AppleToolOutput.make(
                "status=interrupted capability=nfc reason=\(reason.rawValue) retryable=true",
                exitStatus: 75
            )
        case .tagNotNDEF:
            return AppleToolOutput.make(
                "status=tagNotNDEF capability=nfc retryable=true",
                exitStatus: 1
            )
        case .emptyTag:
            return AppleToolOutput.make(
                "status=emptyTag capability=nfc recordCount=0 note=tagContainsNoNDEFMessage",
                exitStatus: 0
            )
        case .multipleTags(let count):
            return AppleToolOutput.make(
                "status=multipleTags capability=nfc tagCount=\(count) retryable=true note=presentOneTag",
                exitStatus: 1
            )
        case .readFailed(let code):
            return AppleToolOutput.make(
                "status=readFailed capability=nfc code=\(code) retryable=true",
                exitStatus: 1
            )
        case .entitlementMissing:
            return AppleToolOutput.make(
                "status=configurationError capability=nfc reason=missingEntitlement retryable=false",
                exitStatus: 78
            )
        case .radioDisabled:
            return AppleToolOutput.make(
                "status=radioDisabled capability=nfc retryable=true",
                exitStatus: 75
            )
        case .ineligible:
            return AppleToolOutput.make(
                "status=ineligible capability=nfc retryable=false",
                exitStatus: 77
            )
        case .accessNotAccepted:
            return AppleToolOutput.make(
                "status=accessNotAccepted capability=nfc reason=systemPermission retryable=false",
                exitStatus: 77
            )
        case .internalFailure(let code):
            return AppleToolOutput.make(
                "status=internalFailure capability=nfc code=\(code) retryable=true",
                exitStatus: 1
            )
        }
    }
}
#endif
