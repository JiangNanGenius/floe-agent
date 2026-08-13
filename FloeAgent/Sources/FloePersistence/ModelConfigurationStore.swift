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
        let headersJSON = try ConfigurationCodec.encode(provider.nonSecretHeaders)
        let createdAt = ConfigurationCodec.encode(provider.createdAt)
        let updatedAt = ConfigurationCodec.encode(provider.updatedAt)

        try await database.writer { db in
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
                    provider.id.uuidString,
                    provider.kind.rawValue,
                    provider.wireProtocol.rawValue,
                    provider.baseURL.absoluteString,
                    provider.secretRef?.keychainAccount,
                    provider.secretRef.map { $0.synchronizable },
                    provider.region,
                    headersJSON,
                    provider.isEnabled,
                    provider.allowsPlainHTTP,
                    createdAt,
                    updatedAt,
                    provider.syncRevision
                ]
            )
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
        let pricingJSON = try model.pricing.map(ConfigurationCodec.encode)

        try await database.writer { db in
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
                    model.id.uuidString,
                    model.providerID.uuidString,
                    model.remoteModelID,
                    model.displayName,
                    model.limits.contextTokens,
                    model.limits.maxOutputTokens,
                    pricingJSON,
                    model.capabilities.rawValue,
                    model.isEnabled
                ]
            )
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

    static func validate(_ model: ModelProfile) throws {
        guard !model.remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.invalidConfiguration("Remote model identifier cannot be empty")
        }
        guard !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.invalidConfiguration("Model display name cannot be empty")
        }
        guard model.limits.contextTokens > 0, model.limits.maxOutputTokens > 0 else {
            throw FloeError.invalidConfiguration("Model token limits must be positive")
        }
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
}
