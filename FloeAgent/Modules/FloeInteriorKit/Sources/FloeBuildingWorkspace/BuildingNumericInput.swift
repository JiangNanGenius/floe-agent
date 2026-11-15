// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum BuildingNumericInputError: Error, Equatable, Sendable { case invalidNumber }
public enum BuildingNumericInput {
    /// No grouping separators or partial prefixes. A localized decimal mark
    /// may be used; the stored value remains a finite number with explicit units.
    public static func parse(_ raw: String, decimalSeparator: String = ".") throws -> Double {
        let text=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.utf8.count<=120,decimalSeparator=="." || decimalSeparator=="," else {
            throw BuildingNumericInputError.invalidNumber
        }
        let normalized=decimalSeparator=="," ? text.replacingOccurrences(of:",",with:"."):text
        let pattern="^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"
        guard normalized.range(of:pattern,options:.regularExpression) != nil,
              let value=Double(normalized),value.isFinite else{throw BuildingNumericInputError.invalidNumber}
        return value
    }
}
