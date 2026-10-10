//
//  Variables.swift
//  openshape3d
//
//  Phase D (task A1): user-defined document variables (spec §6.6). A document
//  owns an ORDERED list of named variables; each variable's expression may
//  reference variables defined EARLIER in the list (creation-order rule), plus
//  the ExpressionEvaluator function library. Forward / cyclic references are
//  errors and resolve to 0.
//
//  nonisolated + Double math to match the kernel.
//

import Foundation

nonisolated struct VariableID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

nonisolated struct Variable: Identifiable, Codable, Hashable, Sendable {
    let id: VariableID
    var name: String
    var expression: String
    var value: Double

    init(id: VariableID = VariableID(), name: String, expression: String, value: Double = 0) {
        self.id = id
        self.name = name
        self.expression = expression
        self.value = value
    }
}

nonisolated enum VariableTable {

    /// Resolve an ORDERED variable list front-to-back. Each variable is
    /// evaluated against a running `[name: value]` map that contains ONLY the
    /// variables defined before it (creation-order rule), so a reference to a
    /// later variable — or to a variable that itself failed — is an error and
    /// resolves to 0 without being added to the running map.
    ///
    /// - Returns: the variables with their `.value` filled in, the final
    ///   `[name: value]` map of successfully-resolved variables, and a
    ///   per-variable error map.
    static func resolve(
        _ vars: [Variable]
    ) -> (resolved: [Variable], values: [String: Double], errors: [VariableID: String]) {
        var values: [String: Double] = [:]
        var errors: [VariableID: String] = [:]
        var resolved: [Variable] = []
        resolved.reserveCapacity(vars.count)

        // Track names seen so far to flag duplicates.
        var seenNames: Set<String> = []

        for var v in vars {
            let trimmedName = v.name.trimmingCharacters(in: .whitespaces)

            // Invalid name -> error, value 0, not added to the map.
            if !isValidName(trimmedName) {
                errors[v.id] = "Invalid name '\(v.name)'"
                v.value = 0
                resolved.append(v)
                continue
            }

            // Duplicate name -> error; last definition would otherwise win, but
            // we flag it and skip adding it so downstream refs use the earlier
            // definition's value.
            if seenNames.contains(trimmedName) {
                errors[v.id] = "Duplicate name '\(trimmedName)'"
                v.value = 0
                resolved.append(v)
                continue
            }

            // Evaluate against ONLY earlier variables.
            if let result = ExpressionEvaluator.evaluate(v.expression, variables: values) {
                v.value = result
                values[trimmedName] = result
                seenNames.insert(trimmedName)
            } else {
                // Give a more specific message when the failure is a reference
                // to a not-yet-defined (later or missing) variable.
                let refs = ExpressionEvaluator.identifiers(in: v.expression)
                let unresolved = refs.filter { values[$0] == nil }
                if let missing = unresolved.sorted().first {
                    errors[v.id] = "Unknown or forward reference '\(missing)'"
                } else {
                    errors[v.id] = "Cannot evaluate '\(v.expression)'"
                }
                v.value = 0
                // Reserve the name so a later duplicate is still flagged, but do
                // NOT publish a value for it.
                seenNames.insert(trimmedName)
            }
            resolved.append(v)
        }

        return (resolved, values, errors)
    }

    /// A valid variable name: alphanumerics + underscore, no leading digit,
    /// no leading "__" (reserved), 1...100 characters.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100 else { return false }
        guard !name.hasPrefix("__") else { return false }

        let chars = Array(name)
        // First char: letter or underscore (no leading digit).
        let first = chars[0]
        guard first.isLetter || first == "_" else { return false }
        // Remaining: alphanumerics or underscore.
        for c in chars {
            guard c.isLetter || c.isNumber || c == "_" else { return false }
        }
        return true
    }
}
