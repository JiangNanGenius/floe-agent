// SPDX-License-Identifier: MPL-2.0
//
// Media-provider save validation regression — AUTHORED ONLY: NOT compiled,
// NOT executed by this package; Main's serialized qualification lane runs
// them against the real toolchain.
//
// Established cause of the observed alpha24-candidate04 refusal (Samsung
// API33, Settings → Add → image purpose, official Volcengine Ark preset on
// the Agent Plan endpoint, one manually added Seedream row): the Android
// producer seeded media-role model rows with `contextTokens = 0`, and the
// closed native validation requires `contextTokens > 0` for EVERY selected
// model (`ProviderConfigurationValidation.issues(for:)` →
// `modelLimitsInvalid`). The host surfaced that as
// `invalidEnvelope`/`providerValidation[model:modelLimitsInvalid:…]` before
// any effect, which the app classified as
// `provider_refused:invalidEnvelope:invalidProviderSettings`.
//
// Synthetic-only, secret-free material: a synthetic API-key string is used
// exactly like the other ingress suites; no real credential, endpoint call
// or paid request is involved.

import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeProviders

final class ProviderMediaSaveValidationTests: XCTestCase {

    private let providerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let modelID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// The EXACT secret-free candidate the observed UI flow emitted, with the
    /// repaired producer limits (128k/8192 — the same generic seed iOS gives
    /// every manually added row).
    private func makeArkPlanImageCandidate(contextTokens: Int,
                                           maxOutputTokens: Int) throws -> [String: Any] {
        let model = ModelProfile(
            id: modelID,
            providerID: providerID,
            remoteModelID: "doubao-seedream-5.0-flash",
            displayName: "SeedreamFlashQA",
            limits: ModelLimits(contextTokens: contextTokens,
                                maxOutputTokens: maxOutputTokens),
            capabilities: [.imageGeneration, .imageEditing],
            reasoningEffort: .automatic,
            isEnabled: true,
            isHiddenFromPrimaryPicker: true
        )
        let modelData = try JSONEncoder().encode(model)
        let modelObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: modelData) as? [String: Any])
        // ModelCapabilities is an OptionSet: ORIGINAL Codable shape is a
        // scalar fragment (24 = imageGeneration|imageEditing).
        let mediaCapabilities: ModelCapabilities = [.imageGeneration, .imageEditing]
        let capsData = try JSONEncoder().encode(mediaCapabilities)
        let capsObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: capsData, options: [.allowFragments]))
        return [
            "id": providerID.uuidString,
            "kind": ProviderKind.volcengineArk.rawValue,
            "wireProtocol": ModelProtocol.openAIChatCompletions.rawValue,
            "baseURL": "https://ark.cn-beijing.volces.com/api/plan/v3",
            "displayName": "ArkPlanImageQA",
            "isEnabled": true,
            "allowsPlainHTTP": false,
            "toolNameCompatibility": false,
            "syncEnabled": false,
            "serviceRoleIsConversation": false,
            "selectedModels": [modelObject],
            "managedCapabilities": capsObject,
            "createIntent": true,
            "presetID": "volcengine-ark",
            "nonSecretHeaders": [:] as [String: String],
        ]
    }

    // MARK: 1. Repaired candidate parses and builds the frozen request

    func testArkPlanImageCandidateWithSeededLimitsParsesAndBuildsRequest() throws {
        let candidate = try makeArkPlanImageCandidate(contextTokens: 128_000,
                                                      maxOutputTokens: 8_192)
        let parsed = try ProviderSaveCandidate.parse(candidate)
        XCTAssertEqual(parsed.kind, .volcengineArk)
        XCTAssertEqual(parsed.wireProtocol, .openAIChatCompletions)
        XCTAssertEqual(parsed.baseURLString,
                       "https://ark.cn-beijing.volces.com/api/plan/v3")
        XCTAssertFalse(parsed.serviceRoleIsConversation)
        XCTAssertEqual(parsed.selectedModels.count, 1)
        XCTAssertEqual(parsed.selectedModels.first?.limits.contextTokens, 128_000)
        XCTAssertEqual(parsed.selectedModels.first?.limits.maxOutputTokens, 8_192)

        let draft = parsed.makeDraft(existingRow: nil,
                                     enteredAPIKey: "sk-synthetic-media-qa")
        switch draft.makeRequest() {
        case .success(let request):
            XCTAssertEqual(request.profile.kind, .volcengineArk)
            XCTAssertEqual(request.selectedModels.count, 1)
            XCTAssertEqual(request.selectedModels.first?.capabilities,
                           [.imageGeneration, .imageEditing])
            XCTAssertEqual(request.managedCapabilities,
                           [.imageGeneration, .imageEditing])
            XCTAssertNotNil(request.apiKey)
        case .failure(let report):
            XCTFail("repaired media candidate must build a request, got \(report.issues)")
        }
    }

    // MARK: 2. Deterministic secret-free reproduction of the original refusal

    func testMediaModelWithZeroContextReproducesModelLimitsInvalidRefusal() throws {
        // The pre-repair producer seed: media rows carried 0/0 limits.
        let candidate = try makeArkPlanImageCandidate(contextTokens: 0,
                                                      maxOutputTokens: 0)
        let parsed = try ProviderSaveCandidate.parse(candidate)
        let draft = parsed.makeDraft(existingRow: nil,
                                     enteredAPIKey: "sk-synthetic-media-qa")
        switch draft.makeRequest() {
        case .success:
            XCTFail("a zero-context media model must stay refused")
        case .failure(let report):
            let problems = report.issues.map(\.problem)
            XCTAssertTrue(problems.contains(.modelLimitsInvalid),
                          "expected modelLimitsInvalid, got \(problems)")
            XCTAssertEqual(report.issues.first?.field, .model)
            // The wire shape the host reports (validationError): closed
            // field:problem:messageKey identifiers only.
            let error = ProviderSaveExecutor.validationError(report)
            XCTAssertEqual(error.code, .invalidEnvelope)
            XCTAssertTrue(error.reason.contains("model:modelLimitsInvalid"),
                          "reason \(error.reason)")
        }
    }

    // MARK: 3. Ordinary conversation candidate stays untouched (no widening)

    func testConversationCandidateWithSeededLimitsStillBuilds() throws {
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: "doubao-seedream-5.0-flash",
            displayName: "SeedreamFlashQA",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools, .approval]
        )
        let modelData = try JSONEncoder().encode(model)
        let modelObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: modelData) as? [String: Any])
        let conversationCapabilities: ModelCapabilities = [.text, .tools]
        let capsData = try JSONEncoder().encode(conversationCapabilities)
        let capsObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: capsData, options: [.allowFragments]))
        let candidate: [String: Any] = [
            "id": providerID.uuidString,
            "kind": ProviderKind.volcengineArk.rawValue,
            "wireProtocol": ModelProtocol.openAIChatCompletions.rawValue,
            "baseURL": "https://ark.cn-beijing.volces.com/api/v3",
            "displayName": "ArkAgentPlanQA",
            "syncEnabled": false,
            "serviceRoleIsConversation": true,
            "selectedModels": [modelObject],
            "managedCapabilities": capsObject,
            "createIntent": true,
        ]
        let parsed = try ProviderSaveCandidate.parse(candidate)
        let draft = parsed.makeDraft(existingRow: nil,
                                     enteredAPIKey: "sk-synthetic-media-qa")
        guard case .success = draft.makeRequest() else {
            return XCTFail("conversation candidate must keep building")
        }
    }

    // MARK: 4. Video adapter factory honors configured billing routes (iOS parity)

    func testVideoAdapterFactoryKeepsConfiguredBillingRoutesUsable() {
        let factory = VideoProviderAdapterFactory()
        let arkPlan = ProviderProfile(
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/plan/v3")!)
        XCTAssertTrue(factory.adapter(for: arkPlan) is VolcengineVideoAdapter,
                      "Agent Plan Ark keeps the native video adapter (iOS parity)")

        let arkPayg = ProviderProfile(
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!)
        XCTAssertTrue(factory.adapter(for: arkPayg) is VolcengineVideoAdapter)

        let tokenPlan = ProviderProfile(
            kind: .alibabaStudio,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")!)
        XCTAssertTrue(factory.adapter(for: tokenPlan) is AlibabaVideoAdapter)

        let customPayg = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!)
        XCTAssertTrue(factory.adapter(for: customPayg) is AlibabaVideoAdapter,
                      "legacy DashScope PAYG custom connection keeps working")

        let customPlan = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/plan/v3")!)
        XCTAssertNil(factory.adapter(for: customPlan),
                     "a non-Ark kind is never promoted to a native video protocol")

        let openAI = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.openai.com/v1")!)
        XCTAssertNil(factory.adapter(for: openAI))
    }
}
