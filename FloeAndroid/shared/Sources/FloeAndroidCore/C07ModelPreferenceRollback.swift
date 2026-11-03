// SPDX-License-Identifier: MPL-2.0
import Foundation
import GRDB
import FloeAndroidDataExchange

/// The inverse of a singleton merge must describe the ACTUAL writer transaction,
/// not the earlier planning snapshot. Stored in the existing settings table in
/// the same transaction; never exported as UI preferences or credential data.
enum C07ModelPreferenceRollback {
    private struct Receipt: Codable {
        let version: Int
        let restoreID: UUID
        let before: C07DBRow?
        let after: C07DBRow?
        let rolledBack: Bool?
    }
    private static func key(_ id: UUID) -> String { "floe.c07.restore.modelPreferences." + id.uuidString }
    static func capture(_ db: Database) throws -> C07DBRow? {
        guard try db.tableExists("model_preferences"),
              let row = try Row.fetchOne(db, sql: "SELECT * FROM model_preferences WHERE id = 'default'") else { return nil }
        return Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, C07DatabaseValueCodec.value(row[$0])) })
    }
    static func record(before: C07DBRow?, restoreID: UUID, db: Database) throws {
        let receipt = Receipt(version: 1, restoreID: restoreID, before: before, after: try capture(db), rolledBack: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= 262144, let value = String(data: data, encoding: .utf8) else {
            throw C07DataExchangeError.storageUnavailable("modelPreferenceReceipt")
        }
        // INSERT deliberately refuses a repeated mutation under the same ID.
        try db.execute(sql: "INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
            arguments: [key(restoreID), value, ISO8601DateFormatter().string(from: Date())])
    }
    private static func receipt(restoreID: UUID, db: Database) throws -> Receipt? {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key(restoreID)]) else { return nil }
        guard value.utf8.count <= 262144, let data = value.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == 1, receipt.restoreID == restoreID else {
            throw C07DataExchangeError.rollbackFailed("modelPreferenceReceiptInvalid")
        }
        return receipt
    }
    static func validate(restoreID: UUID, legacyCount: Int, db: Database) throws {
        guard let receipt = try receipt(restoreID: restoreID, db: db) else {
            // Old journals cannot prove what was merged; never overwrite a
            // newer singleton from their earlier planning snapshot.
            if legacyCount > 0 { throw C07DataExchangeError.rollbackFailed("modelPreferenceOutcomeUnknown") }
            return
        }
        if receipt.rolledBack == true { return }
        guard try capture(db) == receipt.after else {
            throw C07DataExchangeError.rollbackFailed("modelPreferencesChanged")
        }
    }
    static func rollback(restoreID: UUID, legacyCount: Int, db: Database) throws {
        try validate(restoreID: restoreID, legacyCount: legacyCount, db: db)
        guard let receipt = try receipt(restoreID: restoreID, db: db), receipt.rolledBack != true else { return }
        if receipt.before != receipt.after {
            try db.execute(sql: "DELETE FROM model_preferences WHERE id = 'default'")
            if let before = receipt.before {
                let schema = Set(try db.columns(in: "model_preferences").map(\.name))
                guard Set(before.keys).isSubset(of: schema), before["id"]?.stringValue == "default" else {
                    throw C07DataExchangeError.rollbackFailed("modelPreferenceColumns")
                }
                let columns = before.keys.sorted()
                let quoted = columns.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
                let placeholders = columns.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "INSERT INTO model_preferences (" + quoted + ") VALUES (" + placeholders + ")",
                    arguments: StatementArguments(columns.map { C07DatabaseValueCodec.databaseValue(before[$0]!) }))
            }
        }
        let completed = Receipt(version: 1, restoreID: restoreID, before: receipt.before,
            after: receipt.after, rolledBack: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(completed)
        guard let value = String(data: data, encoding: .utf8), data.count <= 262144 else {
            throw C07DataExchangeError.rollbackFailed("modelPreferenceRollbackReceipt")
        }
        try db.execute(sql: "UPDATE settings SET value = ?, updated_at = ? WHERE key = ?",
            arguments: [value, ISO8601DateFormatter().string(from: Date()), key(restoreID)])
    }
}
