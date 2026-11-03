// SPDX-License-Identifier: MPL-2.0
import Foundation
import GRDB
import FloeAndroidDataExchange

/// One SQL/value conversion shared by capture, adapters and rollback receipts.
enum C07DatabaseValueCodec {
    static func value(_ value: DatabaseValue) -> C07DBValue {
        switch value.storage {
        case .null: return .null
        case .int64(let x): return .int(x)
        case .double(let x): return .double(x)
        case .string(let x): return .string(x)
        case .blob(let x): return .data(x)
        }
    }
    static func databaseValue(_ value: C07DBValue) -> DatabaseValue {
        switch value.kind {
        case .null: return .null
        case .integer: return (value.integer ?? 0).databaseValue
        case .real: return (value.real ?? 0).databaseValue
        case .text: return (value.text ?? "").databaseValue
        case .blob: return (value.blob ?? Data()).databaseValue
        }
    }
}
