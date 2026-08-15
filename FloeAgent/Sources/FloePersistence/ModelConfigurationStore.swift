// FloePersistence — durable, secret-free provider and model configuration.

import Foundation
import GRDB
import FloeCore

/// Persists provider and model metadata in the local database.
///
/// API-key bodies never enter this store. `ProviderProfile.secretRef` contains
/// only the Keychain account identifier and its iCloud Keychain preference.
public actor ModelConfigurationStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func saveProvider(_ provider: ProviderProfile) async throws {
        try provider.validate()
        try await database.writer { db in
            try ConfigurationCodec.write(provider, to: db)
        }
    }

    public func provider(id: UUID) async throws -> ProviderProfile? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM providers WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try ConfigurationCodec.provider(from: row)
        }
    }

    public func providers() async throws -> [ProviderProfile] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM providers ORDER BY created_at, id"
            ).map(ConfigurationCodec.provider(from:))
        }
    }

    public func saveModel(_ model: ModelProfile) async throws {
        try ConfigurationCodec.validate(model)
        try await database.writer { db in
            _ = try ConfigurationCodec.write(model, to: db)
        }
    }

    /// Saves a provider and a user-selected set of models in one SQLite
    /// transaction. Existing rows are merged by provider + remote model ID,
    /// preserving their stable local UUIDs and user preferences.
    @discardableResult
    public func saveProviderBundle(
        provider: ProviderProfile,
        models: [ModelProfile]
    ) async throws -> [ModelProfile] {
        try provider.validate()
        for model in models { try ConfigurationCodec.validate(model) }
        return try await database.writer { db in
            try ConfigurationCodec.write(provider, to: db)
            let saved = try models.map { try ConfigurationCodec.write($0, to: db) }
            // The bundle is the user's complete selected chat-model set for
            // this provider. Remove deselected chat rows while preserving
            // auxiliary image-only rows managed by their dedicated page.
            let keptIDs = Set(saved.map { $0.id.uuidString })
            let existingChatIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM models WHERE provider_id = ? AND (capabilities & ?) != 0",
                arguments: [provider.id.uuidString, ModelCapabilities.text.rawValue]
            )
            for staleID in existingChatIDs where !keptIDs.contains(staleID) {
                try db.execute(
                    sql: "DELETE FROM models WHERE id = ?",
                    arguments: [staleID]
                )
            }
            return saved
        }
    }

    public func model(id: UUID) async throws -> ModelProfile? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM models WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try ConfigurationCodec.model(from: row)
        }
    }

    public func models(providerID: UUID? = nil) async throws -> [ModelProfile] {
        try await database.reader { db in
            let rows: [Row]
            if let providerID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM models WHERE provider_id = ? ORDER BY display_name, id",
                    arguments: [providerID.uuidString]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM models ORDER BY display_name, id")
            }
            return try rows.map(ConfigurationCodec.model(from:))
        }
    }

    public func deleteModel(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM models WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Deletes a provider and its models through the schema's foreign-key cascade.
    public func deleteProvider(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM providers WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func preferences() async throws -> ModelSelectionPreferences {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM model_preferences WHERE id = 'default'"
            ) else { return ModelSelectionPreferences() }
            return try ConfigurationCodec.preferences(from: row)
        }
    }

    public func savePreferences(_ preferences: ModelSelectionPreferences) async throws {
        try await database.writer { db in
            try ConfigurationCodec.validate(preferences, in: db)
            try db.execute(
                sql: """
                    INSERT INTO model_preferences (
                        id, onboarding_status, default_agent_model_id,
                        auxiliary_image_mode, shared_image_model_id,
                        image_generation_model_id, image_editing_model_id,
                        updated_at, sync_revision
                    ) VALUES ('default', ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        onboarding_status = excluded.onboarding_status,
                        default_agent_model_id = excluded.default_agent_model_id,
                        auxiliary_image_mode = excluded.auxiliary_image_mode,
                        shared_image_model_id = excluded.shared_image_model_id,
                        image_generation_model_id = excluded.image_generation_model_id,
                        image_editing_model_id = excluded.image_editing_model_id,
                        updated_at = excluded.updated_at,
                        sync_revision = excluded.sync_revision
                    """,
                arguments: [
                    preferences.onboardingStatus.rawValue,
                    preferences.defaultAgentModelID?.uuidString,
                    preferences.auxiliaryImageMode.rawValue,
                    preferences.sharedImageModelID?.uuidString,
                    preferences.imageGenerationModelID?.uuidString,
                    preferences.imageEditingModelID?.uuidString,
                    ConfigurationCodec.encode(preferences.updatedAt),
                    preferences.syncRevision
                ]
            )
        }
    }
}

private enum ConfigurationCodec {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw FloeError.internalError("Could not encode model configuration as UTF-8")
        }
        return string
    }

    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decodeDate(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: value) else {
            throw FloeError.storageCorrupted("Invalid ISO-8601 date in model configuration")
        }
        return date
    }

    static func provider(from row: Row) throws -> ProviderProfile {
        guard
            let id = UUID(uuidString: row["id"]),
            let kind = ProviderKind(rawValue: row["kind"]),
            let wireProtocol = ModelProtocol(rawValue: row["wire_protocol"]),
            let baseURL = URL(string: row["base_url"])
        else {
            throw FloeError.storageCorrupted("Invalid provider identity or protocol")
        }

        let account: String? = row["secret_ref_account"]
        let synchronizable: Bool? = row["secret_ref_synchronizable"]
        let secretRef = account.map {
            SecretReference(keychainAccount: $0, synchronizable: synchronizable ?? false)
        }
        let headersData = Data((row["non_secret_headers_json"] as String).utf8)
        let headers = try JSONDecoder().decode([String: String].self, from: headersData)

        return ProviderProfile(
            id: id,
            kind: kind,
            wireProtocol: wireProtocol,
            baseURL: baseURL,
            secretRef: secretRef,
            region: row["region"],
            nonSecretHeaders: headers,
            isEnabled: row["is_enabled"],
            allowsPlainHTTP: row["allows_plain_http"],
            createdAt: try decodeDate(row["created_at"]),
            updatedAt: try decodeDate(row["updated_at"]),
            syncRevision: row["sync_revision"]
        )
    }

    static func write(_ provider: ProviderProfile, to db: Database) throws {
        let headersJSON = try encode(provider.nonSecretHeaders)
        try db.execute(
            sql: """
                INSERT INTO providers (
                    id, kind, wire_protocol, base_url, secret_ref_account,
                    secret_ref_synchronizable, region, non_secret_headers_json,
                    is_enabled, allows_plain_http, created_at, updated_at,
                    sync_revision
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind,
                    wire_protocol = excluded.wire_protocol,
                    base_url = excluded.base_url,
                    secret_ref_account = excluded.secret_ref_account,
                    secret_ref_synchronizable = excluded.secret_ref_synchronizable,
                    region = excluded.region,
                    non_secret_headers_json = excluded.non_secret_headers_json,
                    is_enabled = excluded.is_enabled,
                    allows_plain_http = excluded.allows_plain_http,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    sync_revision = excluded.sync_revision
                """,
            arguments: [
                provider.id.uuidString, provider.kind.rawValue,
                provider.wireProtocol.rawValue, provider.baseURL.absoluteString,
                provider.secretRef?.keychainAccount,
                provider.secretRef.map { $0.synchronizable }, provider.region,
                headersJSON, provider.isEnabled, provider.allowsPlainHTTP,
                encode(provider.createdAt), encode(provider.updatedAt),
                provider.syncRevision
            ]
        )
    }

    static func validate(_ model: ModelProfile) throws {
        guard !model.remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.invalidConfiguration("Remote model identifier cannot be empty")
        }
        guard !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.invalidConfiguration("Model display name cannot be empty")
        }
        guard model.limits.contextTokens > 0, model.limits.maxOutputTokens >= 0 else {
            throw FloeError.invalidConfiguration(
                "Model context must be positive and maximum output cannot be negative"
            )
        }
        guard model.limits.maxOutputTokens == 0
                || model.limits.maxOutputTokens <= model.limits.contextTokens else {
            throw FloeError.invalidConfiguration("Maximum output cannot exceed model context")
        }
    }

    static func write(_ model: ModelProfile, to db: Database) throws -> ModelProfile {
        let existingID = try String.fetchOne(
            db,
            sql: "SELECT id FROM models WHERE provider_id = ? AND remote_model_id = ?",
            arguments: [model.providerID.uuidString, model.remoteModelID]
        )
        var canonical = model
        if let existingID, let id = UUID(uuidString: existingID), id != model.id {
            canonical.id = id
            try db.execute(sql: "DELETE FROM models WHERE id = ?", arguments: [model.id.uuidString])
        }
        let pricingJSON = try canonical.pricing.map(encode)
        try db.execute(
            sql: """
                INSERT INTO models (
                    id, provider_id, remote_model_id, display_name,
                    context_tokens, max_output_tokens, pricing_json,
                    capabilities, is_enabled
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    provider_id = excluded.provider_id,
                    remote_model_id = excluded.remote_model_id,
                    display_name = excluded.display_name,
                    context_tokens = excluded.context_tokens,
                    max_output_tokens = excluded.max_output_tokens,
                    pricing_json = excluded.pricing_json,
                    capabilities = excluded.capabilities,
                    is_enabled = excluded.is_enabled
                """,
            arguments: [
                canonical.id.uuidString, canonical.providerID.uuidString,
                canonical.remoteModelID, canonical.displayName,
                canonical.limits.contextTokens, canonical.limits.maxOutputTokens,
                pricingJSON, canonical.capabilities.rawValue, canonical.isEnabled
            ]
        )
        return canonical
    }

    static func model(from row: Row) throws -> ModelProfile {
        guard
            let id = UUID(uuidString: row["id"]),
            let providerID = UUID(uuidString: row["provider_id"])
        else {
            throw FloeError.storageCorrupted("Invalid model or provider identifier")
        }

        let pricing: PricingMetadata?
        if let pricingJSON: String = row["pricing_json"] {
            pricing = try JSONDecoder().decode(PricingMetadata.self, from: Data(pricingJSON.utf8))
        } else {
            pricing = nil
        }

        return ModelProfile(
            id: id,
            providerID: providerID,
            remoteModelID: row["remote_model_id"],
            displayName: row["display_name"],
            limits: ModelLimits(
                contextTokens: row["context_tokens"],
                maxOutputTokens: row["max_output_tokens"]
            ),
            pricing: pricing,
            capabilities: ModelCapabilities(rawValue: row["capabilities"]),
            isEnabled: row["is_enabled"]
        )
    }

    static func preferences(from row: Row) throws -> ModelSelectionPreferences {
        guard
            let onboardingStatus = OnboardingStatus(rawValue: row["onboarding_status"]),
            let imageMode = AuxiliaryImageMode(rawValue: row["auxiliary_image_mode"])
        else {
            throw FloeError.storageCorrupted("Invalid model preference state")
        }
        func uuid(_ column: String) -> UUID? {
            let value: String? = row[column]
            return value.flatMap(UUID.init(uuidString:))
        }
        return ModelSelectionPreferences(
            onboardingStatus: onboardingStatus,
            defaultAgentModelID: uuid("default_agent_model_id"),
            auxiliaryImageMode: imageMode,
            sharedImageModelID: uuid("shared_image_model_id"),
            imageGenerationModelID: uuid("image_generation_model_id"),
            imageEditingModelID: uuid("image_editing_model_id"),
            updatedAt: try decodeDate(row["updated_at"]),
            syncRevision: row["sync_revision"]
        )
    }

    static func validate(_ preferences: ModelSelectionPreferences, in db: Database) throws {
        func capabilities(for id: UUID?) throws -> ModelCapabilities? {
            guard let id else { return nil }
            guard let raw = try Int.fetchOne(
                db,
                sql: "SELECT capabilities FROM models WHERE id = ? AND is_enabled = 1",
                arguments: [id.uuidString]
            ) else { throw FloeError.invalidConfiguration("Selected model is unavailable") }
            return ModelCapabilities(rawValue: raw)
        }
        if let capabilities = try capabilities(for: preferences.defaultAgentModelID),
           !capabilities.contains(.text) {
            throw FloeError.invalidConfiguration("Default agent model must support text")
        }
        if let capabilities = try capabilities(for: preferences.sharedImageModelID),
           !(capabilities.contains(.imageGeneration) && capabilities.contains(.imageEditing)) {
            throw FloeError.invalidConfiguration("Shared image model must support generation and editing")
        }
        if let capabilities = try capabilities(for: preferences.imageGenerationModelID),
           !capabilities.contains(.imageGeneration) {
            throw FloeError.invalidConfiguration("Image generation model lacks generation capability")
        }
        if let capabilities = try capabilities(for: preferences.imageEditingModelID),
           !capabilities.contains(.imageEditing) {
            throw FloeError.invalidConfiguration("Image editing model lacks editing capability")
        }
    }
}
