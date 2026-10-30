// FloeProviders — shared, typed image-generation batch planning and execution.
//
// SPDX-License-Identifier: MPL-2.0
//
// Provider image services document different native batch sizes. One product
// request is still a single bounded candidate count. This helper turns that
// count into the provider's documented request chunks, accumulates partial
// successes without replaying any successful request, and reports every slot
// honestly. It never performs network work itself; callers supply the concrete
// adapter request closure.

import Foundation
import UniformTypeIdentifiers
import FloeCore

public enum ImageGenerationBatchError: Error, Sendable, Equatable, LocalizedError {
    /// The reviewed contract says this route cannot generate images.
    case unsupportedModel
    /// The requested candidate count is outside the reviewed contract.
    case countOutsideContract(minimum: Int, maximum: Int, requested: Int)
    /// A provider returned no images and did not throw a richer error.
    case incomplete(String)
    /// A generated payload is empty or not a supported encoded image.
    case unsupportedImagePayload

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            return "This image model is not available on the selected billing channel."
        case .countOutsideContract(let minimum, let maximum, let requested):
            return "This image model accepts \(minimum)...\(maximum) images per request, not \(requested)."
        case .incomplete(let reason):
            return reason.isEmpty ? "The image service returned no images." : reason
        case .unsupportedImagePayload:
            return "The generated image payload is empty or its format is unsupported."
        }
    }
}

/// The exact per-request shape for one product-level candidate count.
public struct ImageGenerationBatchPlan: Sendable, Equatable {
    public let requestedCount: Int
    public let minimumCount: Int
    public let maximumCount: Int
    public let maximumCountPerRequest: Int
    public let strategy: ImageCountStrategy
    /// One entry per provider HTTP request. Their sum is `requestedCount`.
    public let requestCounts: [Int]

    public init(
        contract: ImageGenerationPresetResolver.ParameterContract,
        requestedCount: Int
    ) throws {
        guard contract.countStrategy != .unsupported,
              contract.maximumCount > 0,
              contract.maximumCountPerRequest > 0 else {
            throw ImageGenerationBatchError.unsupportedModel
        }
        let minimum = max(1, contract.minimumCount)
        guard requestedCount >= minimum,
              requestedCount <= contract.maximumCount else {
            throw ImageGenerationBatchError.countOutsideContract(
                minimum: minimum, maximum: contract.maximumCount,
                requested: requestedCount)
        }
        // A native batch uses the provider's documented per-request maximum.
        // A single-image strategy keeps every request at exactly one image.
        let perRequest = contract.countStrategy == .nativeBatch
            ? contract.maximumCountPerRequest : 1
        var remaining = requestedCount
        var requestCounts: [Int] = []
        while remaining > 0 {
            let count = min(perRequest, remaining)
            requestCounts.append(count)
            remaining -= count
        }
        self.requestedCount = requestedCount
        self.minimumCount = minimum
        self.maximumCount = contract.maximumCount
        self.maximumCountPerRequest = contract.maximumCountPerRequest
        self.strategy = contract.countStrategy
        self.requestCounts = requestCounts
    }

    public var plannedImageCount: Int {
        requestCounts.reduce(0, +)
    }
}

/// One generated payload's real encoded family. Consumers must keep this
/// MIME/extension instead of relabelling every non-PNG payload as JPEG.
public struct ImageGenerationImageFormat: Sendable, Equatable {
    public var mimeType: String
    public var fileExtension: String
    public var uti: String

    public init(mimeType: String, fileExtension: String, uti: String) {
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.uti = uti
    }
}

public enum ImageGenerationImageFormatResolver {
    /// Sniffs the bytes with the same wire authority the provider adapters use.
    /// Empty and unrecognized payloads fail closed; PNG/JPEG/GIF/WebP keep their
    /// actual extension and UTI.
    public static func resolve(_ data: Data) throws -> ImageGenerationImageFormat {
        guard !data.isEmpty,
              let mime = ImageWireFormat.sniffMimeType(data) else {
            throw ImageGenerationBatchError.unsupportedImagePayload
        }
        let fileExtension: String
        switch mime {
        case "image/png": fileExtension = "png"
        case "image/jpeg": fileExtension = "jpg"
        case "image/gif": fileExtension = "gif"
        case "image/webp": fileExtension = "webp"
        default:
            throw ImageGenerationBatchError.unsupportedImagePayload
        }
        let uti = UTType(mimeType: mime)?.identifier
            ?? UTType(filenameExtension: fileExtension)?.identifier
            ?? mime
        return ImageGenerationImageFormat(
            mimeType: mime, fileExtension: fileExtension, uti: uti)
    }
}

/// One provider request's result, including prompt/metadata passthrough.
public struct ImageGenerationBatchResponse: Sendable, Equatable {
    public var images: [Data]
    public var revisedPrompt: String?
    public var metadata: [String: String]

    public init(
        images: [Data],
        revisedPrompt: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.images = images
        self.revisedPrompt = revisedPrompt
        self.metadata = metadata
    }
}

public enum ImageGenerationBatchSlotState: String, Sendable, Equatable, CaseIterable {
    case succeeded
    case failed
    case cancelled
    case notAttempted
}

/// One requested candidate slot. `notAttempted` is deliberately distinct from
/// `failed`: it records that a later slot was not sent after an earlier failure
/// instead of claiming the provider rejected it.
public struct ImageGenerationBatchSlot: Sendable, Equatable {
    public var index: Int
    public var state: ImageGenerationBatchSlotState
    public var failure: String?

    public init(index: Int, state: ImageGenerationBatchSlotState, failure: String? = nil) {
        self.index = index
        self.state = state
        self.failure = failure
    }
}

public struct ImageGenerationBatchOutcome: Sendable, Equatable {
    public let plan: ImageGenerationBatchPlan
    public var images: [Data]
    public var slots: [ImageGenerationBatchSlot]
    public var failure: String?
    public var cancelled: Bool
    public var providerExcess: Bool
    public var revisedPrompt: String?
    public var providerMetadata: [String: String]

    public var completedCount: Int { images.count }
    public var failedCount: Int { max(0, plan.requestedCount - images.count) }
    public var partialFailure: Bool {
        cancelled || failure != nil || completedCount != plan.requestedCount
    }

    public var succeededSlotIndices: [Int] {
        slots.filter { $0.state == .succeeded }.map(\.index)
    }

    public var failedSlotIndices: [Int] {
        slots.filter { $0.state == .failed }.map(\.index)
    }

    public var cancelledSlotIndices: [Int] {
        slots.filter { $0.state == .cancelled }.map(\.index)
    }

    public var notAttemptedSlotIndices: [Int] {
        slots.filter { $0.state == .notAttempted }.map(\.index)
    }

    public var missingSlotIndices: [Int] {
        slots.filter { $0.state != .succeeded }.map(\.index)
    }

    /// Stable, compact metadatum for product-layer reports and logs.
    public var slotStatusesDescription: String {
        slots.map(\.state.rawValue).joined(separator: ",")
    }
}

public enum ImageGenerationBatchRunner {
    /// Runs one bounded batch. A successful response is never replayed after a
    /// later failure or cancellation; already returned bytes are retained and
    /// every remaining slot is classified. When no image succeeds the original
    /// error (or cancellation) is rethrown so callers do not need to inspect an
    /// empty outcome.
    public static func run(
        plan: ImageGenerationBatchPlan,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        request: @escaping @Sendable (Int) async throws -> ImageGenerationBatchResponse
    ) async throws -> ImageGenerationBatchOutcome {
        var slots = (0..<plan.requestedCount).map {
            ImageGenerationBatchSlot(index: $0, state: .notAttempted)
        }
        var images: [Data] = []
        var failure: String?
        var cancelled = false
        var providerExcess = false
        var revisedPrompt: String?
        var providerMetadata: [String: String] = [:]
        var nextIndex = 0
        var remainingSlots = plan.requestedCount
        var lastError: Error?

        func markSucceeded(_ count: Int) {
            guard count > 0 else { return }
            for _ in 0..<count where nextIndex < slots.count {
                slots[nextIndex].state = .succeeded
                nextIndex += 1
            }
        }

        func markRemaining(_ state: ImageGenerationBatchSlotState, reason: String) {
            guard nextIndex < slots.count else { return }
            for index in nextIndex..<slots.count {
                slots[index].state = state
                slots[index].failure = reason
            }
        }

        requestLoop: for plannedCount in plan.requestCounts {
            guard remainingSlots > 0 else { break }
            if isCancelled() {
                cancelled = true
                markRemaining(.cancelled, reason: "Cancelled before this image was requested.")
                break
            }
            let requestCount = min(plannedCount, remainingSlots)
            let response: ImageGenerationBatchResponse
            do {
                response = try await request(requestCount)
            } catch is CancellationError {
                cancelled = true
                markRemaining(.cancelled, reason: "Cancelled before this image was requested.")
                break
            } catch let error as FloeError where error == .cancelled {
                cancelled = true
                markRemaining(.cancelled, reason: "Cancelled before this image was requested.")
                break
            } catch {
                lastError = error
                failure = error.localizedDescription
                if nextIndex < slots.count {
                    slots[nextIndex].state = .failed
                    slots[nextIndex].failure = failure
                    if nextIndex + 1 < slots.count {
                        for index in (nextIndex + 1)..<slots.count {
                            slots[index].state = .notAttempted
                            slots[index].failure = "Not requested after an earlier failure."
                        }
                    }
                }
                break requestLoop
            }

            if revisedPrompt == nil { revisedPrompt = response.revisedPrompt }
            for (key, value) in response.metadata where providerMetadata[key] == nil {
                providerMetadata[key] = value
            }

            if response.images.count > requestCount {
                providerExcess = true
            }
            // Preserve every returned byte up to the product's total requested
            // count. Extra images from one chunk fill later reserved slots
            // instead of being discarded only because they exceeded this
            // provider chunk.
            let accepted = Array(response.images.prefix(remainingSlots))
            if !accepted.isEmpty {
                images.append(contentsOf: accepted)
                markSucceeded(accepted.count)
                remainingSlots -= accepted.count
            }
            if response.images.count > accepted.count {
                // The product count is fixed; bytes beyond every reserved slot
                // are never published as if they were requested.
                providerExcess = true
            }
            if remainingSlots == 0 {
                markRemaining(.notAttempted, reason: "Not requested after all requested images were returned.")
                break
            }
            if response.images.count < requestCount {
                failure = "The image provider returned fewer images than requested."
                if nextIndex < slots.count {
                    slots[nextIndex].state = .failed
                    slots[nextIndex].failure = failure
                    if nextIndex + 1 < slots.count {
                        for index in (nextIndex + 1)..<slots.count {
                            slots[index].state = .notAttempted
                            slots[index].failure = "Not requested after an earlier failure."
                        }
                    }
                }
                break
            }
        }

        if images.isEmpty {
            if cancelled { throw CancellationError() }
            if let lastError { throw lastError }
            throw ImageGenerationBatchError.incomplete(
                failure ?? "The image service returned no images.")
        }

        return ImageGenerationBatchOutcome(
            plan: plan,
            images: images,
            slots: slots,
            failure: failure,
            cancelled: cancelled,
            providerExcess: providerExcess,
            revisedPrompt: revisedPrompt,
            providerMetadata: providerMetadata)
    }
}

/// Product-layer projection of `performAgentImage` metadata. User-facing copy
/// names the requested/actual model and counts only; IDs, statuses, strategy and
/// failure details stay in `technicalDetails`.
public struct ImageGenerationBatchReport: Sendable, Equatable {
    public var requestedCount: Int
    public var completedCount: Int
    public var failedCount: Int
    public var cancelled: Bool
    public var partialFailure: Bool
    public var providerExcess: Bool
    public var failure: String?
    public var requestedModel: String
    public var actualModel: String
    public var requestedProvider: String
    public var actualProvider: String
    public var fallbackUsed: Bool
    public var fallbackReason: String
    public var selectionMode: String
    public var slotStates: [ImageGenerationBatchSlotState]
    public var metadata: [String: String]

    public init(metadata: [String: String]) {
        self.metadata = metadata
        let requested = Int(metadata["requestedCount"] ?? "") ?? 0
        let completed = Int(metadata["completedCount"] ?? "") ?? 0
        self.requestedCount = requested
        self.completedCount = completed
        self.failedCount = Int(metadata["failedCount"] ?? "")
            ?? max(0, requested - completed)
        self.cancelled = metadata["cancelled"] == "true"
        self.partialFailure = metadata["partialFailure"] == "true"
        self.providerExcess = metadata["providerExcess"] == "true"
        self.failure = metadata["failure"]
        self.requestedModel = metadata["requestedModel"]
            ?? metadata["model"] ?? ""
        self.actualModel = metadata["actualModel"]
            ?? metadata["model"] ?? ""
        self.requestedProvider = metadata["requestedProvider"] ?? ""
        self.actualProvider = metadata["actualProvider"] ?? ""
        self.fallbackUsed = metadata["fallbackUsed"] == "true"
        self.fallbackReason = metadata["fallbackReason"] ?? ""
        self.selectionMode = metadata["selectionMode"] ?? ""
        let parsed = (metadata["slotStatuses"] ?? "")
            .split(separator: ",")
            .compactMap { ImageGenerationBatchSlotState(rawValue: String($0)) }
        if parsed.count == requested {
            self.slotStates = parsed
        } else {
            let completedSlots = Array(
                repeating: ImageGenerationBatchSlotState.succeeded,
                count: min(completed, requested))
            let remainingState: ImageGenerationBatchSlotState = cancelled ? .cancelled : .failed
            self.slotStates = completedSlots + Array(
                repeating: remainingState,
                count: max(0, requested - completedSlots.count))
        }
    }

    public var isComplete: Bool {
        requestedCount > 0
            && completedCount == requestedCount
            && !cancelled
            && failure == nil
    }

    /// 1-based slot numbers, suitable for user copy.
    public var missingSlotNumbers: [Int] {
        slotStates.enumerated().compactMap { index, state in
            state == .succeeded ? nil : index + 1
        }
    }

    public var userSummary: String {
        guard requestedCount > 0 else {
            return FloeL10n.l("providers.image_generation_batch.no_image_was_returned")
        }
        let displayModel = displayName(
            provider: actualProvider.isEmpty ? requestedProvider : actualProvider,
            model: actualModel.isEmpty ? requestedModel : actualModel)
        let base: String
        if cancelled {
            base = FloeL10n.l(
                "providers.image_generation_batch.cancelled_images",
                completedCount, requestedCount, displayModel)
        } else if isComplete {
            if completedCount == 1 {
                base = FloeL10n.l(
                    "providers.image_generation_batch.created_one_image", displayModel)
            } else {
                base = FloeL10n.l(
                    "providers.image_generation_batch.created_images",
                    completedCount, displayModel)
            }
        } else {
            base = FloeL10n.l(
                "providers.image_generation_batch.partial_images",
                completedCount, requestedCount, displayModel, failedCount)
        }
        var parts = [base]
        if fallbackUsed, !requestedModel.isEmpty, requestedModel != actualModel {
            parts.append(FloeL10n.l(
                "providers.image_generation_batch.fallback_note",
                requestedModel, fallbackReasonText, actualModel))
        }
        if isComplete, providerExcess {
            parts.append(FloeL10n.l(
                "providers.image_generation_batch.extra_images_ignored"))
        }
        return parts.joined(separator: " ")
    }

    public var technicalDetails: String {
        var lines: [String] = [
            "requestedProviderID=\(metadata["requestedProviderID"] ?? "")",
            "actualProviderID=\(metadata["actualProviderID"] ?? "")",
            "requestedProvider=\(requestedProvider)",
            "actualProvider=\(actualProvider)",
            "requestedModel=\(requestedModel)",
            "actualModel=\(actualModel)",
            "requestedModelID=\(metadata["requestedModelID"] ?? "")",
            "actualModelID=\(metadata["actualModelID"] ?? "")",
            "selectionMode=\(selectionMode)",
            "fallbackUsed=\(fallbackUsed)",
            "fallbackReason=\(fallbackReason)",
            "requestedCount=\(requestedCount)",
            "completedCount=\(completedCount)",
            "failedCount=\(failedCount)",
            "cancelled=\(cancelled)",
            "partialFailure=\(partialFailure)",
            "providerExcess=\(providerExcess)",
            "countStrategy=\(metadata["countStrategy"] ?? "")",
            "verificationBasis=\(metadata["verificationBasis"] ?? "")",
            "accountUsability=\(metadata["accountUsability"] ?? "")",
            "slotStatuses=\(slotStates.map(\.rawValue).joined(separator: ","))",
        ]
        if let failure, !failure.isEmpty {
            lines.append("failure=\(String(failure.prefix(400)))")
        }
        return lines.joined(separator: " ")
    }

    private var fallbackReasonText: String {
        if fallbackReason.hasPrefix("providerRejected:") {
            let status = fallbackReason.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            return FloeL10n.l(
                "providers.image_generation_batch.provider_rejected_reason", status)
        }
        if fallbackReason == "routeRefused" {
            return FloeL10n.l("providers.image_generation_batch.route_refused_reason")
        }
        return fallbackReason.isEmpty
            ? FloeL10n.l("providers.image_generation_batch.unavailable_reason")
            : fallbackReason
    }

    private func displayName(provider: String, model: String) -> String {
        if provider.isEmpty { return model }
        if model.isEmpty { return provider }
        return "\(model) (\(provider))"
    }
}
