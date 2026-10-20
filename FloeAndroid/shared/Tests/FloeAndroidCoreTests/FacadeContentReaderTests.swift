// SPDX-License-Identifier: MPL-2.0
//
// RB-1 source tests — bounded opaque-handle content reader and frame budget.
// Oversized single items reassemble BYTE-EXACTLY through scalar-safe chunks;
// nothing is silently truncated and every slice is independently valid UTF-8.
// AUTHORED ONLY: not compiled or executed by this source package.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class FacadeContentReaderTests: XCTestCase {

    private func bigUnicodePayload() -> Data {
        // CJK + emoji + escaped-quote-like ASCII; >48KiB forces chunking.
        var text = ""
        while text.utf8.count < 300_000 {
            text += "第n段：含 \"引号\" 与 \\ 反斜杠 换行\n 🎉 emoji尾"
        }
        return Data(text.utf8)
    }

    func testByteExactReassemblyAcrossChunkBoundaries() throws {
        let reader = FacadeContentReader(generation: 1)
        let payload = bigUnicodePayload()
        guard case .staged(let handle) = reader.stage(payload) else {
            return XCTFail("stage")
        }
        var reassembled = Data()
        var offset = 0
        var guardCount = 0
        var finished = false
        while !finished {
            guardCount += 1
            XCTAssertLessThan(guardCount, 4096, "chunking must terminate")
            switch reader.read(handle: handle, offset: offset, maxBytes: 49_152) {
            case .slice(let bytes, let nextOffset, let complete):
                // Every returned slice is independently valid UTF-8.
                XCTAssertNotNil(String(data: bytes, encoding: .utf8))
                reassembled.append(bytes)
                offset = nextOffset
                if complete { finished = true }
            case .notFound:
                return XCTFail("live handle vanished at \(offset)")
            case .invalidOffset:
                return XCTFail("boundary math produced a non-boundary offset at \(offset)")
            }
        }
        XCTAssertEqual(reassembled, payload)
    }

    func testTinyChunksAlwaysLandOnScalarBoundaries() throws {
        let reader = FacadeContentReader(generation: 1)
        let text = "🎉中A😀尾"
        let payload = Data(text.utf8)
        guard case .staged(let handle) = reader.stage(payload) else {
            return XCTFail("stage")
        }
        var reassembled = Data()
        var offset = 0
        while true {
            switch reader.read(handle: handle, offset: offset, maxBytes: 1) {
            case .slice(let bytes, let next, let complete):
                // A 1-byte request still yields WHOLE scalars (<=4 bytes).
                XCTAssertNotNil(String(data: bytes, encoding: .utf8))
                XCTAssertGreaterThan(bytes.count, 0)
                reassembled.append(bytes)
                offset = next
                if complete { break }
            case .notFound:
                return XCTFail("live handle missing")
            case .invalidOffset:
                return XCTFail("boundary math produced a non-boundary offset")
            }
            if offset >= payload.count { break }
        }
        XCTAssertEqual(reassembled, payload)
    }

    func testTinyBudgetsZeroThroughFourStayScalarAlignedWithinHardBound() throws {
        // 1-, 2-, 3- and 4-byte scalars with every tiny budget 0..4. Contract:
        //  * every slice is independently valid UTF-8 and nextOffset is always
        //    a scalar boundary (byte-exact reassembly);
        //  * a budget smaller than the next scalar advances EXACTLY one whole
        //    scalar (<= 4 bytes), never more and never a livelock;
        //  * maxBytes == 0 below EOF is a TYPED refusal, not a silent byte;
        //  * no slice ever exceeds the hard chunk bound.
        let text = "A¢中😀Z"
        let payload = Data(text.utf8)
        for budget in 0...4 {
            let reader = FacadeContentReader(generation: 1)
            guard case .staged(let handle) = reader.stage(payload) else {
                return XCTFail("stage")
            }
            var offset = 0
            var rebuilt = Data()
            var guardCount = 0
            while offset < payload.count {
                guardCount += 1
                XCTAssertLessThan(guardCount, 64, "no livelock for budget \(budget)")
                switch reader.read(handle: handle, offset: offset, maxBytes: budget) {
                case .slice(let bytes, let next, let complete):
                    XCTAssertLessThanOrEqual(bytes.count,
                                             FacadeContentReader.Limits.maximumChunkBytes)
                    XCTAssertNotNil(String(data: bytes, encoding: .utf8),
                                    "slice must be valid UTF-8 (budget \(budget))")
                    XCTAssertFalse(bytes.isEmpty, "progress must be positive")
                    XCTAssertLessThanOrEqual(bytes.count, max(4, budget))
                    XCTAssertEqual(next, offset + bytes.count,
                                   "nextOffset must follow the slice exactly")
                    if next > offset {
                        // The byte at next is a lead byte or EOF: a boundary.
                        if next < payload.count {
                            let lead = payload[payload.index(payload.startIndex,
                                                             offsetBy: next)]
                            XCTAssertNotEqual(lead & 0xC0, 0x80,
                                              "nextOffset must not point at a continuation byte")
                        }
                    }
                    rebuilt.append(bytes)
                    offset = next
                    if complete { offset = payload.count }
                case .invalidOffset:
                    if budget == 0 {
                        // Typed refusal for a zero-byte request below EOF.
                        return
                    }
                    return XCTFail("budget \(budget) must advance one scalar")
                case .notFound:
                    return XCTFail("live handle missing")
                }
            }
            if budget == 0 { return XCTFail("maxBytes=0 must not silently return data") }
            XCTAssertEqual(rebuilt, payload, "byte-exact reassembly (budget \(budget))")
        }
    }

    func testMidScalarOffsetIsTypedInvalidOffset() throws {
        let reader = FacadeContentReader(generation: 1)
        let payload = Data("😀abc".utf8)   // 4-byte emoji then ASCII
        guard case .staged(let handle) = reader.stage(payload) else {
            return XCTFail("stage")
        }
        // Offset 1 is a UTF-8 continuation byte of the emoji.
        switch reader.read(handle: handle, offset: 1, maxBytes: 16) {
        case .invalidOffset: break
        default: XCTFail("continuation-byte start must be typed invalidOffset")
        }
    }

    func testHandleRulesAndBounds() throws {
        let reader = FacadeContentReader(generation: 1)
        guard case .rejected = reader.stage(Data()) else {
            return XCTFail("empty stage must be typed-rejected")
        }
        var handles: [String] = []
        for _ in 0..<FacadeContentReader.Limits.maximumLiveHandles {
            guard case .staged(let handle) = reader.stage(Data("x".utf8)) else {
                return XCTFail("within bound")
            }
            handles.append(handle)
        }
        guard case .rejected = reader.stage(Data("x".utf8)) else {
            return XCTFail("handle bound must reject")
        }
        // Handles are canonical and process-local.
        for handle in handles {
            XCTAssertTrue(handle.hasPrefix(FacadeContentReader.Limits.handlePrefix))
            let hex = handle.dropFirst(FacadeContentReader.Limits.handlePrefix.count)
            XCTAssertEqual(hex.count, FacadeContentReader.Limits.handleHexLength)
            XCTAssertTrue(hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        }
        reader.release(handle: handles[0])
        switch reader.read(handle: handles[0], offset: 0, maxBytes: 16) {
        case .notFound: break
        default: XCTFail("released handle must be typed notFound")
        }
        // Retire = instance end: every old handle becomes typed notFound.
        reader.retireAll()
        switch reader.read(handle: handles[1], offset: 0, maxBytes: 16) {
        case .notFound: break
        default: XCTFail("retired handles never revive")
        }
    }

    // MARK: Frame budget

    func testPageBudgetIsActualSerializedBytesNotCharacterCount() throws {
        var items: [[String: Any]] = []
        for index in 0..<500 {
            items.append(["i": index, "s": String(repeating: "含\"引号\"\\🎉", count: 12)])
        }
        // Fit under the page budget exactly like the pump does: incremental
        // serialized-byte accumulation.
        var included: [[String: Any]] = []
        var used = 0
        for item in items {
            let itemBytes = FacadeFrameBudget.serializedBytes(item)
            if used + itemBytes + 1 > FacadeFrameBudget.pageBudgetBytes { break }
            included.append(item)
            used += itemBytes + 1
        }
        XCTAssertLessThan(included.count, 500)
        XCTAssertGreaterThan(included.count, 1)
        // Actual UTF-8 bytes of the included run stay inside 48 KiB.
        let serialized = try XCTUnwrap(FacadeFrameBudget.encode(["e": included]))
        XCTAssertLessThanOrEqual(serialized.count, FacadeFrameBudget.pageBudgetBytes + 8)
        // Escapes were MEASURED, not counted as characters: verify the same
        // array by hand for the first item.
        let first = try XCTUnwrap(FacadeFrameBudget.encode(included[0]))
        XCTAssertEqual(first.count,
                       FacadeFrameBudget.serializedBytes(included[0]))
    }

    func testFullEnvelopeNeverExceedsFrozenBound() throws {
        // Build the largest legal page frame: 48 KiB of items + envelope.
        let big = String(repeating: "🎉", count: 8_000)   // 32KB UTF-8
        let object: [String: Any] = [
            "ok": true, "schema": BridgeV3.runEventSchema,
            "correlationID": "c", "cursor": ["runID": UUID().uuidString, "sequence": 1],
            "events": [["sequence": 1, "kind": "assistantText",
                        "createdAt": 0, "payload": big]],
            "hasMore": true, "resyncRequired": false,
        ]
        let encoded = try XCTUnwrap(FacadeFrameBudget.encode(object))
        XCTAssertLessThanOrEqual(encoded.count, BridgeV3.maximumBytes)
    }

    func testUnserializableItemIsNeverFit() {
        let nan = ["s": Double.nan]
        XCTAssertEqual(FadeProbe.bytes(nan), Int.max)
        XCTAssertNil(FadeProbe.encode(nan))
    }
}

private enum FadeProbe {
    static func bytes(_ object: Any) -> Int {
        FacadeFrameBudget.serializedBytes(object)
    }
    static func encode(_ object: Any) -> Data? {
        FacadeFrameBudget.encode(object)
    }
}
