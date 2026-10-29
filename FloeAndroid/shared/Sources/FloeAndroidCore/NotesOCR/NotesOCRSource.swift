// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes cloud OCR — the accepted-generation source and vision route.
//
// Both dependencies are the ORIGINAL services of the accepted generation:
// * `floe.notes/4` on `NotesDomainService.shared` for the current page
//   identity/revision and the source-key cache receipt;
// * `RunModelAssembly.auxiliaryVisionModel` + `ModelConfigurationStore` +
//   `RunCredentialResolver` + the original `ProviderAdapter` for the one
//   tool-free vision request.
//
// Nothing here selects a provider by position, computes a Kotlin/native hash,
// stores credentials, or modifies provider/model configuration.
import Foundation
import FloeCore
import FloeModels
import FloeNotes
import FloePersistence
import FloeProviders

// MARK: - The existing Notes authority (read current key, write cache only)

struct NotesOCRServiceSource: NotesOCRSourceReading {
    let epoch: UInt64

    func pageSnapshot(documentID: UUID, pageID: UUID) async throws
        -> NotesOCRPageSnapshot {
        let data = try await callData("document.get",
                                      ["documentID": documentID.uuidString])
        let reply: DocumentReply
        do {
            reply = try NotesWire.decode(DocumentReply.self, from: data)
        } catch {
            throw NotesOCRRefusal.sourceUnavailable("documentDecode")
        }
        guard reply.document.deletedAt == nil else {
            throw NotesOCRRefusal.sourceUnavailable("documentUnavailable")
        }
        guard let page = reply.document.pages.first(where: { $0.id == pageID }) else {
            throw NotesOCRRefusal.sourceUnavailable("pageNotFound")
        }
        let text = page.indexedVisualText
        return NotesOCRPageSnapshot(
            documentID: reply.document.id,
            pageID: page.id,
            revision: reply.document.revision,
            visualIndexKey: page.visualIndexKey,
            current: text != nil,
            cachedText: text,
            indexed: text != nil,
            needsVisualIndex: page.needsVisualIndex)
    }

    func cachePageOCR(documentID: UUID, pageID: UUID, sourceKey: String,
                      text: String?, error: String?, expectedRevision: Int?,
                      conversationID: UUID?) async throws -> NoteIndexCacheReceipt {
        var payload: [String: Any] = [
            "documentID": documentID.uuidString,
            "pageID": pageID.uuidString,
            "sourceKey": sourceKey,
            "text": text ?? NSNull(),
            "error": error ?? NSNull(),
        ]
        if let expectedRevision { payload["expectedRevision"] = expectedRevision }
        if let conversationID { payload["conversationID"] = conversationID.uuidString }
        let data = try await callData("document.cachePageOCR", payload)
        do {
            return try NotesWire.decode(CacheReply.self, from: data).cache
        } catch {
            throw NotesOCRRefusal.sourceUnavailable("cacheDecode")
        }
    }

    private struct DocumentReply: Decodable {
        let document: NoteDocument
    }

    private struct CacheReply: Decodable {
        let cache: NoteIndexCacheReceipt
    }

    private func callData(_ action: String, _ payload: [String: Any]) async throws -> Data {
        let requestData: Data
        do {
            requestData = try JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys])
        } catch {
            throw NotesOCRRefusal.invalidPayload("payloadEncode")
        }
        guard requestData.count <= NotesWire.maximumRequestBytes else {
            throw NotesOCRRefusal.invalidPayload("payloadTooLarge")
        }
        let value: NotesJSONValue
        do {
            value = try JSONDecoder().decode(NotesJSONValue.self, from: requestData)
        } catch {
            throw NotesOCRRefusal.invalidPayload("payloadDecode")
        }
        do {
            let response = try await NotesDomainService.shared.handle(
                epoch: epoch,
                requestID: "notes-ocr-" + UUID().uuidString,
                action: action,
                payload: value)
            guard response.count <= NotesWire.maximumResponseBytes else {
                throw NotesOCRRefusal.sourceUnavailable("responseTooLarge")
            }
            return response
        } catch {
            throw Self.mapAuthorityError(error)
        }
    }

    private static func mapAuthorityError(_ error: Error) -> NotesOCRRefusal {
        if let error = error as? NotesDomainError {
            switch error {
            case .notBound:
                return .notBound
            case .staleGeneration:
                return .notBound
            case .unsupportedAction(let action):
                return .unsupported("unsupportedAction:" + action)
            case .invalidPayload(let reason):
                return .invalidPayload(reason)
            case .requestTooLarge:
                return .invalidPayload("requestTooLarge")
            case .responseTooLarge:
                return .sourceUnavailable("responseTooLarge")
            case .stageNotFound:
                return .stageNotFound
            case .stageExpired:
                return .stageExpired
            case .storageUnavailable:
                return .storageUnavailable
            case .busy:
                return .busy("authority")
            }
        }
        if let error = error as? NoteError {
            switch error {
            case .notFound:
                return .sourceUnavailable("documentUnavailable")
            case .conflict:
                return .stale("revisionOrSourceChanged")
            case .invalidDocument(let reason):
                return .sourceUnavailable("invalidDocument:" + reason)
            case .invalidOperation(let reason):
                return .sourceUnavailable("invalidOperation:" + reason)
            case .resourceUnavailable:
                return .sourceUnavailable("resourceUnavailable")
            case .storageUnavailable(_):
                return .storageUnavailable
            }
        }
        return .sourceUnavailable("authorityFailure")
    }
}

// MARK: - The accepted-generation vision route

/// Reads ONLY the saved configuration through the ORIGINAL model assembly,
/// resolves the secret through the ORIGINAL credential resolver, and returns
/// the ORIGINAL wire adapter. Missing/disabled/unsupported/credential/transport
/// states are typed BEFORE any provider request; there is no anonymous or
/// first-provider fallback.
struct NotesOCRRunModelRouting: NotesOCRVisionRouting {
    let assembly: RunModelAssembly
    let store: ModelConfigurationStore
    let credentials: RunCredentialResolver
    let transportAdmitted: @Sendable () -> Bool
    let adapterFactory: @Sendable (ProviderProfile) -> any ProviderAdapter

    func route() async -> NotesOCRVisionRouteOutcome {
        guard transportAdmitted() else { return .transportUnavailable }
        do {
            guard let model = try await assembly.auxiliaryVisionModel() else {
                return .notConfigured("visionModelMissing")
            }
            let capabilities = await assembly.effectiveCapabilities(of: model)
            guard capabilities.contains(.vision), capabilities.contains(.text) else {
                return .unsupported("visionCapabilityMissing")
            }
            guard let provider = try await store.provider(id: model.providerID) else {
                return .notConfigured("providerMissing")
            }
            guard provider.isEnabled else {
                return .notConfigured("providerDisabled")
            }
            switch provider.kind {
            case .local:
                return .unsupported("localProviderUnsupported")
            default:
                break
            }
            switch await credentials.resolve(provider: provider) {
            case .resolved:
                break
            case .explicitNoAuth:
                return .unsupported("credentialsUnsupported")
            case .gatewayUnregistered:
                return .credentialUnavailable("gatewayUnregistered")
            case .secretMissing:
                return .credentialUnavailable("secretMissing")
            case .secretInvalidated:
                return .credentialUnavailable("secretInvalidated")
            }
            let credentialValue: ProviderCredentials
            do {
                credentialValue = try await credentials.credentials(for: provider)
            } catch {
                return .credentialUnavailable("credentialReadFailed")
            }
            let providerName = provider.displayName ?? provider.kind.rawValue
            return .resolved(NotesOCRVisionRoute(
                provider: provider,
                model: model,
                credentials: credentialValue,
                adapter: adapterFactory(provider),
                providerLabel: providerName + " · " + model.displayName))
        } catch {
            return .notConfigured("configurationUnreadable")
        }
    }
}
