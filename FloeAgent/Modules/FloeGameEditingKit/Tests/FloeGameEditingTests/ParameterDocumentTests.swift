// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGameEditingCore

@Suite("Parameter documents")
struct ParameterDocumentTests {
    let schema = TestSupport.sampleSchema()

    func sampleBytes() throws -> Data {
        try TestSupport.jsonBytes([
            "characters": [["id": 1, "name": "Mira", "level": 3, "class": "mage",
                            "portrait": "assets/hero.png",
                            "equipment": ["weapon": "wand"], "customField": ["note": "keep"]]]
        ])
    }

    @Test("Field edits apply structurally and unknown data survives")
    @MainActor
    func structuralEdit() async throws {
        var document = try ParameterDocument(bytes: sampleBytes(), schema: schema)
        try document.set(.string("Aster"), for: schema.fields[0])
        try document.set(.number(42), for: schema.fields[1])
        let bytes = try document.serialized()
        let root = try JSONValue.parse(bytes)
        #expect(root["characters"]?[0]?["name"] == .string("Aster"))
        #expect(root["characters"]?[0]?["level"] == .number(42))
        #expect(root["characters"]?[0]?["customField"]?["note"] == .string("keep"))
        #expect(root["characters"]?[0]?["portrait"] == .string("assets/hero.png"))
        #expect(root["characters"]?[0]?["equipment"]?["weapon"] == .string("wand"))
    }

    @Test("Kind validation rejects out-of-range and wrong-type values")
    @MainActor
    func validation() async throws {
        var document = try ParameterDocument(bytes: sampleBytes(), schema: schema)
        do {
            try document.set(.number(1000), for: schema.fields[1])
            Issue.record("Out-of-range integer must fail")
        } catch {}
        do {
            try document.set(.string("cleric"), for: schema.fields[2])
            Issue.record("Choice outside options must fail")
        } catch {}
        do {
            try document.set(.bool(true), for: schema.fields[0])
            Issue.record("Wrong type must fail")
        } catch {}
        // Null clears a value without breaking the document.
        try document.set(.null, for: schema.fields[0])
        #expect(document.value(for: schema.fields[0]) == .null)
    }
}
