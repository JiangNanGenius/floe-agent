// FloeProvidersTests — shared image-generation batch contract.
//
// Offline: pure planning, slot classification and report projection. No
// provider, network, credentials or paid request is involved.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.ImageGenerationBatch")
struct ImageGenerationBatchTests {
    private func contract(
        maximum: Int = 4,
        perRequest: Int,
        strategy: ImageCountStrategy? = nil,
        minimum: Int = 1
    ) -> ImageGenerationPresetResolver.ParameterContract {
        ImageGenerationPresetResolver.ParameterContract(
            verifiedModel: true,
            verificationBasis: .officialAgentPlanVisualModels,
            accountUsability: "notChecked",
            aspectRatio: [],
            resolution: ["2K"],
            quality: [],
            defaultAspectRatio: nil,
            defaultResolution: "2K",
            defaultQuality: nil,
            minimumCount: minimum,
            maximumCount: maximum,
            maximumCountPerRequest: perRequest,
            countStrategy: strategy ?? (perRequest > 1 ? .nativeBatch : .sequentialSingleImageRequests),
            maximumReferenceImages: 0,
            nativeSizeOverride: true,
            unavailableControls: [])
    }

    @Test("A single-image contract fans out one bounded request per candidate")
    func sequentialPlan() throws {
        let plan = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 1), requestedCount: 4)
        #expect(plan.strategy == .sequentialSingleImageRequests)
        #expect(plan.requestCounts == [1, 1, 1, 1])
        #expect(plan.plannedImageCount == 4)
    }

    @Test("A native batch uses the documented per-request maximum")
    func nativePlan() throws {
        let plan = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 2), requestedCount: 4)
        #expect(plan.strategy == .nativeBatch)
        #expect(plan.requestCounts == [2, 2])

        let remainder = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 3), requestedCount: 4)
        #expect(remainder.requestCounts == [3, 1])

        let oneRequest = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 4), requestedCount: 3)
        #expect(oneRequest.requestCounts == [3])
    }

    @Test("Counts outside the reviewed contract fail before any request")
    func countBounds() throws {
        #expect(throws: ImageGenerationBatchError.self) {
            _ = try ImageGenerationBatchPlan(
                contract: contract(perRequest: 1), requestedCount: 5)
        }
        #expect(throws: ImageGenerationBatchError.self) {
            _ = try ImageGenerationBatchPlan(
                contract: contract(perRequest: 1), requestedCount: 0)
        }
        #expect(throws: ImageGenerationBatchError.self) {
            _ = try ImageGenerationBatchPlan(
                contract: contract(
                    maximum: 0, perRequest: 1, strategy: .unsupported),
                requestedCount: 1)
        }
    }

    @Test("Successful sequential requests fill every slot")
    func allSlotsSucceed() async throws {
        let plan = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 1), requestedCount: 3)
        let outcome = try await ImageGenerationBatchRunner.run(plan: plan) { _ in
            ImageGenerationBatchResponse(
                images: [Data([0xAA])], revisedPrompt: "expanded")
        }
        #expect(outcome.completedCount == 3)
        #expect(outcome.failedCount == 0)
        #expect(outcome.partialFailure == false)
        #expect(outcome.cancelled == false)
        #expect(outcome.slots.map(\.state) == [.succeeded, .succeeded, .succeeded])
        #expect(outcome.revisedPrompt == "expanded")
    }

    @Test("A short response keeps earlier images and marks the missing slot")
    func shortResponseIsPartial() async throws {
        let plan = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 1), requestedCount: 3)
        let calls = CallCounter()
        let outcome = try await ImageGenerationBatchRunner.run(plan: plan) { _ in
            let index = await calls.next()
            return ImageGenerationBatchResponse(
                images: index < 2 ? [Data([UInt8(index)])] : [])
        }
        let callCount = await calls.count
        #expect(callCount == 3)
        #expect(outcome.images.count == 2)
        #expect(outcome.failedCount == 1)
        #expect(outcome.partialFailure)
        #expect(outcome.slots.map(\.state) == [.succeeded, .succeeded, .failed])
        #expect(outcome.failure?.contains("fewer") == true)
    }

    @Test("A transport failure retains already returned images and never replays them")
    func errorAfterSuccessIsPartial() async throws {
        let plan = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 1), requestedCount: 3)
        let calls = CallCounter()
        let outcome = try await ImageGenerationBatchRunner.run(plan: plan) { _ in
            let index = await calls.next()
            if index == 0 {
                return ImageGenerationBatchResponse(images: [Data([0x01])])
            }
            throw RemoteImageError.providerRejected(statusCode: 500, message: "upstream")
        }
        let callCount = await calls.count
        #expect(callCount == 2)
        #expect(outcome.images == [Data([0x01])])
        #expect(outcome.slots.map(\.state) == [.succeeded, .failed, .notAttempted])
        #expect(outcome.failedCount == 2)
        #expect(outcome.partialFailure)
    }

    @Test("Cancellation after a produced image keeps that image and marks later slots")
    func cancellationAfterSuccessIsPartial() async throws {
        let plan = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 1), requestedCount: 3)
        let outcome = try await ImageGenerationBatchRunner.run(plan: plan) { _ in
            if await SharedCursor.shared.first() {
                return ImageGenerationBatchResponse(images: [Data([0x02])])
            }
            throw CancellationError()
        }
        #expect(outcome.images == [Data([0x02])])
        #expect(outcome.cancelled)
        #expect(outcome.slots.map(\.state) == [.succeeded, .cancelled, .cancelled])
    }

    @Test("Cancellation before any image rethrows instead of fabricating a batch")
    func cancellationBeforeAnyImageThrows() async throws {
        let plan = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 1), requestedCount: 2)
        await #expect(throws: CancellationError.self) {
            _ = try await ImageGenerationBatchRunner.run(plan: plan) { _ in
                throw CancellationError()
            }
        }
    }

    @Test("Extra provider images are bounded and reported, not silently accepted")
    func extraImagesAreBounded() async throws {
        let plan = try ImageGenerationBatchPlan(
            contract: contract(perRequest: 2), requestedCount: 2)
        let outcome = try await ImageGenerationBatchRunner.run(plan: plan) { _ in
            ImageGenerationBatchResponse(images: [Data([1]), Data([2]), Data([3])])
        }
        #expect(outcome.images == [Data([1]), Data([2])])
        #expect(outcome.slots.map(\.state) == [.succeeded, .succeeded])
        #expect(outcome.failure == nil)
        #expect(outcome.providerExcess)
        #expect(outcome.partialFailure == false)
    }

    @Test("Generated image format keeps the real encoded family")
    func generatedImageFormatHonesty() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let gif = Data(Array("GIF89a".utf8))
        var webp = Data(Array("RIFF".utf8))
        webp.append(contentsOf: [0, 0, 0, 0])
        webp.append(contentsOf: Array("WEBP".utf8))

        #expect(try ImageGenerationImageFormatResolver.resolve(png).mimeType == "image/png")
        #expect(try ImageGenerationImageFormatResolver.resolve(png).fileExtension == "png")
        #expect(try ImageGenerationImageFormatResolver.resolve(jpeg).mimeType == "image/jpeg")
        #expect(try ImageGenerationImageFormatResolver.resolve(jpeg).fileExtension == "jpg")
        #expect(try ImageGenerationImageFormatResolver.resolve(gif).mimeType == "image/gif")
        #expect(try ImageGenerationImageFormatResolver.resolve(gif).fileExtension == "gif")
        #expect(try ImageGenerationImageFormatResolver.resolve(webp).mimeType == "image/webp")
        #expect(try ImageGenerationImageFormatResolver.resolve(webp).fileExtension == "webp")
        #expect(try ImageGenerationImageFormatResolver.resolve(png).uti.isEmpty == false)
        #expect(throws: ImageGenerationBatchError.self) {
            _ = try ImageGenerationImageFormatResolver.resolve(Data())
        }
        #expect(throws: ImageGenerationBatchError.self) {
            _ = try ImageGenerationImageFormatResolver.resolve(Data([0x00, 0x01, 0x02, 0x03]))
        }
    }

    @Test("Report keeps requested and actual model names and slot counts")
    func reportProjection() {
        let report = ImageGenerationBatchReport(metadata: [
            "requestedModel": "doubao-seedream-5-0-pro",
            "actualModel": "doubao-seedream-5.0-flash",
            "requestedProvider": "Volcengine Agent Plan",
            "actualProvider": "Volcengine Agent Plan",
            "fallbackUsed": "true",
            "fallbackReason": "providerRejected:429",
            "requestedCount": "4",
            "completedCount": "2",
            "failedCount": "2",
            "cancelled": "false",
            "partialFailure": "true",
            "slotStatuses": "succeeded,succeeded,failed,notAttempted",
            "countStrategy": "sequentialSingleImageRequests",
            "verificationBasis": "officialAgentPlanVisualModels",
            "accountUsability": "notChecked",
        ])
        #expect(!report.isComplete)
        #expect(report.completedCount == 2)
        #expect(report.failedCount == 2)
        #expect(report.missingSlotNumbers == [3, 4])
        #expect(report.fallbackUsed)
        #expect(report.actualModel == "doubao-seedream-5.0-flash")
        #expect(report.userSummary.isEmpty == false)
        #expect(report.technicalDetails.contains("fallbackReason=providerRejected:429"))
        #expect(report.technicalDetails.contains("requestedProviderID="))
        #expect(report.technicalDetails.contains("slotStatuses=succeeded,succeeded,failed,notAttempted"))
    }
}

/// Serialized counters used by the runner tests. The runner awaits each request
/// before starting the next one, so a simple actor is enough.
private actor CallCounter {
    private(set) var count = 0

    func next() -> Int {
        let value = count
        count += 1
        return value
    }
}

private actor SharedCursor {
    static let shared = SharedCursor()
    private var used = false

    func first() -> Bool {
        if used { return false }
        used = true
        return true
    }
}
