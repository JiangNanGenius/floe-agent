// FloeProviders — cloud ASR adapter factory.
//
// SPDX-License-Identifier: MPL-2.0
//
// The App selects one profile (provider + explicit billing route) and asks for
// a file and/or live adapter. The factory only validates protocol/route/model
// configuration; it deliberately does not require a credential, Keychain
// value, membership or developer-run account test. A profile with supplied
// configuration is callable by default.
//
// `liveAdapter` returns nil when a profile has no live route. In particular
// Alibaba Token Plan defaults to the file route (per-utterance batching).
// A user may explicitly configure a streaming model and a live endpoint for
// Token Plan; the adapter then validates that protocol combination without a
// membership precheck.
//
// OpenAI-compatible branches consume the shared adapters owned by the
// openai-core lane. This file never edits them.

import Foundation
import FloeCore

public enum ASRAdapterFactory {
    /// File transcription adapter for the profile's provider/route.
    public static func fileAdapter(
        for profile: ASRProfile
    ) throws -> any ASRTranscribing {
        try validateRoute(profile)
        if let problem = profile.validationProblem() {
            throw ASRTranscriptionError.invalidConfiguration(problem)
        }
        guard !profile.fileModelID
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration(
                "file transcription model is required")
        }
        let capabilities = profile.fileCapabilities
        guard capabilities.supportsFileTranscription else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this model does not support file transcription")
        }
        switch profile.provider {
        case .openaiCompatible:
            #if canImport(FoundationNetworking)
            throw ASRTranscriptionError.invalidConfiguration(
                "OpenAI-compatible adapters require Apple networking")
            #else
            return OpenAITranscriptionAdapter()
            #endif
        case .volcengine:
            #if canImport(FoundationNetworking)
            throw ASRTranscriptionError.invalidConfiguration(
                "Volcengine adapters require Apple networking")
            #else
            return VolcengineASRAdapter()
            #endif
        case .alibaba:
            #if canImport(FoundationNetworking)
            throw ASRTranscriptionError.invalidConfiguration(
                "Alibaba adapters require Apple networking")
            #else
            return AlibabaASRAdapter()
            #endif
        }
    }

    /// Live adapter for the profile, or nil when it has no live route.
    public static func liveAdapter(
        for profile: ASRProfile
    ) throws -> (any ASRLiveTranscribing)? {
        try validateRoute(profile)
        if let problem = profile.validationProblem() {
            throw ASRTranscriptionError.invalidConfiguration(problem)
        }
        guard let liveModel = profile.liveModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !liveModel.isEmpty else {
            return nil
        }
        guard let capabilities = profile.liveCapabilities,
              capabilities.supportsLiveTranscription else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this model does not support live transcription")
        }
        // Token Plan has no documented default live route. With both a
        // streaming model and an explicit endpoint the adapter judges the
        // protocol capability; otherwise the App batches the file route.
        if profile.provider == .alibaba,
           profile.billingRoute == .tokenPlan,
           profile.resolvedLiveEndpoint == nil {
            return nil
        }
        switch profile.provider {
        case .openaiCompatible:
            #if canImport(FoundationNetworking)
            throw ASRTranscriptionError.invalidConfiguration(
                "OpenAI-compatible adapters require Apple networking")
            #else
            return OpenAIRealtimeTranscriptionAdapter()
            #endif
        case .volcengine:
            #if canImport(FoundationNetworking)
            throw ASRTranscriptionError.invalidConfiguration(
                "Volcengine adapters require Apple networking")
            #else
            return VolcengineASRAdapter()
            #endif
        case .alibaba:
            #if canImport(FoundationNetworking)
            throw ASRTranscriptionError.invalidConfiguration(
                "Alibaba adapters require Apple networking")
            #else
            return AlibabaASRAdapter()
            #endif
        }
    }

    private static func validateRoute(_ profile: ASRProfile) throws {
        guard profile.provider.supports(profile.billingRoute) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "billing route is not available for this provider")
        }
    }
}
