//
//  NumericParsing.swift
//  FloeCADKit
//
//  Pure numeric-text helpers extracted from upstream OpenShape3D's
//  `UI/NumericKeypad.swift` (MIT). The on-screen keypad itself is Floe app
//  UI and is not vendored; only the unit-token parsing used by the kernel
//  and editor is kept here.
//

import Foundation

nonisolated enum NumericParsing {
    nonisolated static let units = ["mm", "cm", "m", "deg"]

    /// The trailing unit token, if the text ends in one of `units`.
    /// Returns the matched token including nothing else, so callers can both
    /// strip it and map it to a `DisplayUnit`.
    static func trailingUnit(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Longest first so "mm" is never mistaken for a trailing "m".
        // Recognition includes both families, regardless of the visible unit row.
        return (units + ["in", "ft"]).sorted { $0.count > $1.count }
            .first { token in
                guard trimmed.hasSuffix(token) else { return false }
                let body = trimmed.dropLast(token.count)
                // Do not mistake a variable such as `pin` for an inch suffix.
                return body.last.map { !$0.isLetter && $0 != "_" } ?? false
            }
    }
}
