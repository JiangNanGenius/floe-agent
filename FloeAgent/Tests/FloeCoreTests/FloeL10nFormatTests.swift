// FloeCoreTests — type-safe catalog format substitution.
//
// Migrated call sites pass arbitrary expression values (Int, Double, String,
// optionals) to `FloeL10n.l`. The formatter must never trap and must mirror
// Swift string-interpolation semantics (`String(describing:)`).

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.FloeL10nFormat")
struct FloeL10nFormatTests {

    @Test("Integer, string and double arguments format via %@")
    func mixedTypes() {
        let out = FloeL10n.substituting(
            format: "pip exit code %@\n%@ took %.1f s",
            arguments: [3, "install", 2.5])
        #expect(out == "pip exit code 3\ninstall took 2.5 s")
    }

    @Test("No arguments leaves the format untouched")
    func noArguments() {
        #expect(FloeL10n.substituting(format: "plain text", arguments: []) == "plain text")
    }

    @Test("Positional placeholders reorder arguments")
    func positional() {
        let out = FloeL10n.substituting(
            format: "Schedule %2$@ in %1$@, %3$@",
            arguments: ["tomorrow", "report", "daily"])
        #expect(out == "Schedule report in tomorrow, daily")
    }

    @Test("Positional numeric specifiers format the selected argument")
    func positionalNumeric() {
        // `%2$lld` / `%3$lld` select an argument and must not keep the `n$`
        // prefix when handed a single value to String(format:).
        let out = FloeL10n.substituting(
            format: "%1$@ · %2$lld tokens · %3$lld ms",
            arguments: ["m", 42, 1500])
        #expect(out == "m · 42 tokens · 1500 ms")
    }

    @Test("Mixed positional string and numeric specifiers reorder correctly")
    func mixedPositionalReordered() {
        let out = FloeL10n.substituting(
            format: "%2$lld/%1$lld (%3$@)",
            arguments: [10, 3, "done"])
        #expect(out == "3/10 (done)")
    }

    @Test("Positional numeric with flags keeps flags without the index")
    func positionalNumericFlags() {
        let out = FloeL10n.substituting(
            format: "%2$+06.1f|%1$@",
            arguments: ["v", 2.5])
        #expect(out == "+002.5|v")
    }

    @Test("Literal percent is preserved")
    func literalPercent() {
        #expect(FloeL10n.substituting(format: "confidence %@%%",
                                      arguments: [87]) == "confidence 87%")
    }

    @Test("Extra arguments are ignored; missing arguments keep the placeholder")
    func arityMismatch() {
        #expect(FloeL10n.substituting(format: "%@ and %@", arguments: [1])
                == "1 and %@")
        #expect(FloeL10n.substituting(format: "%@", arguments: [1, 2]) == "1")
    }

    @Test("Optional and custom values never trap")
    func optionalsAndCustomValues() {
        struct Row: CustomStringConvertible { var description: String { "row" } }
        let optional: String? = nil
        let out = FloeL10n.substituting(
            format: "%@ | %@ | %@",
            arguments: [optional as Any, Row(), 42 as Any])
        #expect(out == "nil | row | 42")
    }

    @Test("Legacy non-%@ specifiers degrade to the literal text")
    func legacySpecifiers() {
        #expect(FloeL10n.substituting(format: "conflict %lld", arguments: [])
                == "conflict %lld")
    }

    @Test("Real newlines/tabs round-trip")
    func controlCharacters() {
        #expect(FloeL10n.substituting(format: "a\nb\tc", arguments: [])
                == "a\nb\tc")
    }
}
