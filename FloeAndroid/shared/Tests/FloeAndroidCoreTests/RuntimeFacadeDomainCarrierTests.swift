// SPDX-License-Identifier: MPL-2.0
//
// Host regressions for the typed domain -> RB1 result-carrier composition
// (integration delta 2026-10-20). These use the REAL P0 Codable DTOs and the
// REAL accepted carrier types (`RuntimeCommandResult`/`RuntimeEffectItem`) —
// no fake dictionary, no JSON-in-detail, no second encoder.
import XCTest
import Foundation
import FloeCore
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeDomainCarrierTests: XCTestCase {
    private struct RichDocument: Encodable, Equatable {
        var text: String
        var enabled: Bool
        var disabled: Bool
        var count: Int64
        var big: UInt64
        var none: String?
        var list: [String]
    }

    private func foundationTree(_ value: DesignJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .integer(let number): return number
        case .unsigned(let number): return number
        case .decimal(let number): return number
        case .number(let number): return number
        case .string(let text): return text
        case .array(let items): return items.map(foundationTree)
        case .object(let pairs):
            var object: [String: Any] = [:]
            for (key, item) in pairs { object[key] = foundationTree(item) }
            return object
        }
    }

    func testContentChunkCarriesExactCJKEscapedText() throws {
        let text = "记忆😀 \"quoted\" \\slash\\ 控制-\t-换行\n与收尾"
        let chunk = SettingsDomainV1.ContentChunk(chunk: text,
                                                  nextOffset: 4096,
                                                  totalBytes: 9000,
                                                  done: false)
        let document = try FacadeDomainCarrier.encode(chunk)
        guard case .object(let root) = document else {
            return XCTFail("chunk must be an OBJECT carrier document")
        }
        XCTAssertEqual(root["chunk"], .string(text),
                       "CJK/emoji/escapes survive byte-exact")
        XCTAssertEqual(root["nextOffset"], .integer(4096))
        XCTAssertEqual(root["totalBytes"], .integer(9000))
        XCTAssertEqual(root["done"], .bool(false))
        // Re-encoding through the same Foundation projection must be
        // byte-stable and must not grow/lose fields.
        let foundation = foundationTree(document)
        let encoded = try JSONSerialization.data(withJSONObject: foundation,
                                                 options: [.sortedKeys])
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        let original = try JSONEncoder().encode(chunk)
        let originalObject = try JSONSerialization.jsonObject(with: original)
        XCTAssertEqual(NSDictionary(dictionary: decoded as! [String: Any]),
                       NSDictionary(dictionary: originalObject as! [String: Any]))
    }

    func testScalarKindsStayExactThroughTheCarrier() throws {
        let doc = RichDocument(text: "π≈3.14 😀", enabled: true,
                               disabled: false, count: 7, big: 42,
                               none: nil, list: ["a", "β"])
        let encoded = try FacadeDomainCarrier.encode(doc)
        guard case .object(let root) = encoded else {
            return XCTFail("object expected")
        }
        XCTAssertEqual(root["enabled"], .bool(true),
                       "JSON true must stay a boolean (never 1)")
        XCTAssertEqual(root["disabled"], .bool(false))
        XCTAssertEqual(root["count"], .integer(7))
        XCTAssertEqual(root["big"], .integer(42))
        // The synthesized Encodable for an optional OMITS a nil, so the
        // carrier omits the key too (it never invents 0/""/null). An
        // EXPLICIT null document still round-trips as .null below.
        XCTAssertNil(root["none"],
                     "synthesized optionals omit nil, never coerce to 0 or empty")
        XCTAssertEqual(root["list"], .array([.string("a"), .string("β")]))
    }

    func testExplicitNullDocumentStaysNull() throws {
        let document = try FacadeDomainCarrier.encode(
            DesignJSONValue.object(["a": .null, "b": .bool(true), "c": .integer(0)]))
        guard case .object(let root) = document else {
            return XCTFail("object expected")
        }
        XCTAssertEqual(root["a"], .null)
        XCTAssertEqual(root["b"], .bool(true))
        XCTAssertEqual(root["c"], .integer(0),
                       "0 stays an integer and never bridges to false")
    }

    func testNonObjectDocumentIsRefusedTyped() {
        do {
            _ = try FacadeDomainCarrier.encode([1, 2, 3])
            XCTFail("a top-level array is not a legal RB1 carrier document")
        } catch let error as FacadeDomainCarrier.CarrierError {
            XCTAssertEqual(error, .notAnObjectDocument)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAcceptedResultAttachesValueNotStringDetail() throws {
        let chunk = SettingsDomainV1.ContentChunk(chunk: "page-内容",
                                                  nextOffset: nil,
                                                  totalBytes: 9,
                                                  done: true)
        let result = try FacadeDomainCarrier.accepted(chunk,
                                                      detail: ["kind": "content"])
        XCTAssertEqual(result.kind, .accepted)
        XCTAssertEqual(result.detail?["kind"], "content",
                       "detail stays identifier-only")
        guard case .object = result.value else {
            return XCTFail("typed value document expected")
        }
        // The accepted effect item carries the document + its declared
        // canonical size, and never stringifies the page into detail.
        let item = RuntimeEffectItem(sequence: 0, kind: result.kind,
                                     code: result.code, detail: result.detail,
                                     value: result.value)
        let object = item.jsonObject
        XCTAssertNotNil(object["value"])
        XCTAssertNotNil(object["valueBytes"])
        XCTAssertGreaterThan(item.encodedBytes, 0)
        XCTAssertEqual(object["valueBytes"] as? Int, item.valueBytes)
        XCTAssertNil(object["page"])
        let detail = object["detail"] as? [[String: String]]
        XCTAssertEqual(detail?.count, 1)
        XCTAssertEqual(detail?.first?["value"], "content")
    }

    func testLargeNearPageContentChunkIsMeasuredNotDropped() throws {
        // ~30 KiB of CJK keeps the encoded response inside the 48 KiB normal
        // page while exercising multi-byte escaping through the carrier.
        let text = String(repeating: "记忆", count: 5_000)
        let chunk = SettingsDomainV1.ContentChunk(chunk: text,
                                                  nextOffset: nil,
                                                  totalBytes: text.utf8.count,
                                                  done: true)
        XCTAssertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(chunk))
        let document = try FacadeDomainCarrier.encode(chunk)
        let item = RuntimeEffectItem(sequence: 1, kind: .accepted,
                                     code: nil, detail: nil, value: document)
        XCTAssertNotEqual(item.encodedBytes, Int.max)
        XCTAssertEqual(item.valueBytes,
                       FacadeFrameBudget.canonicalSerializedBytes(
                           RuntimeEffectDocumentProjection.foundationObject(document)))
        XCTAssertLessThanOrEqual(item.encodedBytes,
                                 SettingsDomainV1.pageBudgetBytes + 8 * 1024,
                                 "carrier size is measured, not guessed")
    }
}
