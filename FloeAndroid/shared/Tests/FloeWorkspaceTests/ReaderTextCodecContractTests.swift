// FloeAndroidWorkspaceTests — Android-authored encoding/decoding contracts.
// Authored (job-b6c74b42a49d4f45, G04-R1 files-domain), NOT executed in this
// source lane. Host-runnable; platform-codec differences (Android has no
// CoreFoundation, hence no GB18030 codec) are asserted as HONEST degradation
// branches, never as unconditional success.

import XCTest
import Foundation
@testable import FloeWorkspace

final class ReaderTextCodecContractTests: XCTestCase {

    // MARK: Probe

    func testBOMsDeclareEncodingAndSkipBytes() throws {
        XCTAssertEqual(ReaderTextCodec.probe(Data([0xEF, 0xBB, 0xBF] + "hi".utf8)),
                       ReaderEncodingProbe(encoding: .utf8, bomLength: 3, fromBOM: true))
        XCTAssertEqual(ReaderTextCodec.probe(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])),
                       ReaderEncodingProbe(encoding: .utf16LittleEndian, bomLength: 2, fromBOM: true))
        var be = [UInt8]([0xFE, 0xFF]); be += [UInt8](("hi".data(using: .utf16BigEndian)!))
        XCTAssertEqual(ReaderTextCodec.probe(Data(be)),
                       ReaderEncodingProbe(encoding: .utf16BigEndian, bomLength: 2, fromBOM: true))
        // UTF-32 marks are refused by policy, never guessed as UTF-16.
        XCTAssertNil(ReaderTextCodec.probe(Data([0xFF, 0xFE, 0x00, 0x00, 0x68, 0x00])))
        XCTAssertNil(ReaderTextCodec.probe(Data([0x00, 0x00, 0xFE, 0xFF])))
    }

    func testBOMLessUTF16DetectedByNULParityAndFailsOtherwise() throws {
        let text = String(repeating: "ASCII filler line of moderate length.\n", count: 6)
        let le = text.data(using: .utf16LittleEndian)!
        XCTAssertEqual(ReaderTextCodec.probe(le)?.encoding, .utf16LittleEndian)
        XCTAssertEqual(ReaderTextCodec.probe(le)?.bomLength, 0)
        XCTAssertEqual(ReaderTextCodec.probe(le)?.fromBOM, false)
        var be = Data()
        for unit in text.utf16 { be.append(UInt8(unit >> 8)); be.append(UInt8(unit & 0xFF)) }
        XCTAssertEqual(ReaderTextCodec.probe(be)?.encoding, .utf16BigEndian)
        // A binary blob with a stray NUL pattern must NOT be called UTF-16:
        // neither endianness's 8:1 NUL-parity ratio holds and the decoded
        // sample would also fail the textiness gate.
        var hostile = Data(repeating: 0, count: 40)
        hostile[1] = 0x41
        XCTAssertNil(ReaderTextCodec.probe(hostile))
    }

    func testPlainASCIIAndUTF8Probe() throws {
        XCTAssertEqual(ReaderTextCodec.probe(Data("just text ✓".utf8)),
                       ReaderEncodingProbe(encoding: .utf8, bomLength: 0, fromBOM: false))
        XCTAssertNil(ReaderTextCodec.probe(Data([0x41, 0x00, 0x42]))) // NUL without UTF-16 parity
    }

    /// GB18030 is offered ONLY when the platform codec really decodes the
    /// known Chinese probe sequence. Android (corelibs, no CoreFoundation)
    /// must refuse instead of mislabeling; hosts with the codec must pass.
    /// The probe payload is deliberately NOT valid UTF-8 (0xD6 0xD1 fails
    /// strict UTF-8), so the UTF-8 branch cannot shadow the codec branch.
    func testGB18030IsHonestAboutThePlatformCodec() throws {
        let knownPair = Data([0xD6, 0xD0, 0xCE, 0xC4]) // 中文 in GB18030/GBK
        let probeBytes = Data([0xD6, 0xD1, 0xCE, 0xC4]) // invalid UTF-8, valid GB2312 pair
        XCTAssertEqual(ReaderTextCodec.gb18030CodecAvailable,
                       String.Encoding.floeGB18030 != nil)
        if ReaderTextCodec.gb18030CodecAvailable {
            XCTAssertFalse(ReaderTextCodec.utf8Valid(probeBytes),
                           "probe payload must stay invisible to the UTF-8 branch")
            XCTAssertEqual(ReaderTextCodec.probe(probeBytes)?.encoding, .gb18030)
            XCTAssertEqual(ReaderTextCodec.decode(knownPair, as: .gb18030), "中文")
        } else {
            XCTAssertNil(ReaderTextCodec.probe(probeBytes),
                         "without the codec the probe must fail, never guess")
            XCTAssertNil(ReaderTextCodec.decode(knownPair, as: .gb18030))
            // The encoding enum still declares itself honestly.
            XCTAssertNil(ReaderTextEncoding.gb18030.stringEncoding)
        }
    }

    func testManualChoiceContradictingBOMIsRefused() throws {
        XCTAssertTrue(ReaderTextCodec.manualChoiceConflictsWithBOM(.utf16LittleEndian,
                        sample: Data([0xEF, 0xBB, 0xBF])))
        XCTAssertFalse(ReaderTextCodec.manualChoiceConflictsWithBOM(.utf8,
                       sample: Data([0xEF, 0xBB, 0xBF])))
        XCTAssertTrue(ReaderTextCodec.manualChoiceConflictsWithBOM(.gb18030,
                        sample: Data([0xFF, 0xFE, 0x00, 0x00])))
        XCTAssertFalse(ReaderTextCodec.manualChoiceConflictsWithBOM(.utf8,
                        sample: Data("plain".utf8)))
    }

    // MARK: Strict validation

    func testStrictUTF8RejectsOverlongsSurrogatesAndBadLeads() throws {
        XCTAssertTrue(ReaderTextCodec.utf8Valid(Data("ascii ✓ 中 🎉".utf8)))
        XCTAssertFalse(ReaderTextCodec.utf8Valid(Data([0xC0, 0x80])))           // overlong NUL
        XCTAssertFalse(ReaderTextCodec.utf8Valid(Data([0xC1, 0xBF])))           // overlong
        XCTAssertFalse(ReaderTextCodec.utf8Valid(Data([0xE0, 0x80, 0x80])))     // overlong 3-byte
        XCTAssertFalse(ReaderTextCodec.utf8Valid(Data([0xED, 0xA0, 0x80])))     // UTF-16 surrogate
        XCTAssertFalse(ReaderTextCodec.utf8Valid(Data([0xF4, 0x90, 0x80, 0x80]))) // > U+10FFFF
        XCTAssertFalse(ReaderTextCodec.utf8Valid(Data([0xF5, 0x80, 0x80, 0x80]))) // invalid lead
        XCTAssertFalse(ReaderTextCodec.utf8Valid(Data([0x41, 0x80])))             // stray continuation
        // Truncated tail: valid PREFIX, invalid FULL stream (utf8ValidPrefix
        // is the probe; utf8Valid is the whole-stream validator).
        let truncated = Data([0xF0, 0x9F, 0x8E])
        XCTAssertTrue(ReaderTextCodec.utf8ValidPrefix(truncated))
        XCTAssertFalse(ReaderTextCodec.utf8Valid(truncated))
    }

    /// The streaming validator must reassemble sequences split across chunk
    /// boundaries and report ABSOLUTE byte offsets of the first failure.
    func testValidatorReportsAbsoluteOffsetsAcrossChunks() throws {
        var v = ReaderTextValidator(encoding: .utf8, startOffset: 100)
        XCTAssertNil(v.consume(Data("ok ".utf8), isLast: false))
        XCTAssertNil(v.consume(Data([0xF0, 0x9F]), isLast: false))  // partial emoji
        XCTAssertNil(v.consume(Data([0x8E, 0x89]), isLast: false))  // completes at boundary
        XCTAssertEqual(v.consume(Data(" end".utf8), isLast: true), nil)

        var bad = ReaderTextValidator(encoding: .utf8, startOffset: 1000)
        XCTAssertNil(bad.consume(Data("prefix".utf8), isLast: false))
        XCTAssertEqual(bad.consume(Data([0xED, 0xA0, 0x80]), isLast: true), 1007,
                       "surrogate-range continuation fails at its own absolute byte offset")

        var nulReject = ReaderTextValidator(encoding: .utf8, startOffset: 0, rejectsNUL: true)
        XCTAssertEqual(nulReject.consume(Data([0x41, 0x00]), isLast: false), 1)

        var utf16 = ReaderTextValidator(encoding: .utf16LittleEndian, startOffset: 0)
        XCTAssertNil(utf16.consume(Data([0x61, 0x00, 0x62, 0x00]), isLast: false))
        // Lone high surrogate must wait for its low unit unless this is the end.
        var pendingHigh = ReaderTextValidator(encoding: .utf16LittleEndian, startOffset: 6)
        XCTAssertNil(pendingHigh.consume(Data([0x00, 0xD8]), isLast: false))
        XCTAssertEqual(pendingHigh.consume(Data(), isLast: true), 6)
        var loneLow = ReaderTextValidator(encoding: .utf16BigEndian, startOffset: 2)
        XCTAssertEqual(loneLow.consume(Data([0xDC, 0x00]), isLast: false), 2)
        var oddTail = ReaderTextValidator(encoding: .utf16LittleEndian, startOffset: 0)
        XCTAssertNil(oddTail.consume(Data([0x41]), isLast: false))
        XCTAssertEqual(oddTail.consume(Data(), isLast: true), 0)
    }

    // MARK: Window/line decoding

    func testDecodeWindowsAndSampleTextDropPartialSequences() throws {
        let text = "line1\nline2 中文 🎉\nline3"
        let utf8 = Data(text.utf8)
        XCTAssertEqual(ReaderTextCodec.decode(utf8, as: .utf8), text)
        XCTAssertEqual(ReaderTextCodec.sampleText(utf8, as: .utf8, bomLength: 0), text)
        // A sample cut mid-emoji: the partial tail is dropped, never U+FFFD.
        let cut = utf8.prefix(utf8.count - 1)
        let sampled = ReaderTextCodec.sampleText(Data(cut), as: .utf8, bomLength: 0)
        XCTAssertNotNil(sampled)
        XCTAssertFalse(sampled!.unicodeScalars.contains(Unicode.Scalar(0xFFFD)!))
        // BOM skip.
        let withBOM = Data([0xEF, 0xBB, 0xBF]) + utf8
        XCTAssertEqual(ReaderTextCodec.sampleText(withBOM, as: .utf8, bomLength: 3), text)
        // Garbage stays garbage: undecodable windows return nil (caller
        // reports corruptText), they never surface as replacement text.
        XCTAssertNil(ReaderTextCodec.decode(Data([0xC0, 0x80, 0xC0, 0x80, 0xC0]), as: .utf8))
    }

    func testTextinessKeepsControlRatioHonest() throws {
        XCTAssertTrue(ReaderTextCodec.looksLikeText("tab\there\nnewline\rCRLF"))
        XCTAssertFalse(ReaderTextCodec.looksLikeText(""))
        let noisy = String(repeating: "\u{07}", count: 10) + String(repeating: "x", count: 100)
        XCTAssertFalse(ReaderTextCodec.looksLikeText(noisy))
        XCTAssertTrue(ReaderTextCodec.looksLikeText(noisy, controlRatioLimit: 0.5))
    }

    func testEncodingMetadataIsStable() throws {
        XCTAssertEqual(ReaderTextEncoding.utf8.displayName, "UTF-8")
        XCTAssertEqual(ReaderTextEncoding.utf16LittleEndian.displayName, "UTF-16 LE")
        XCTAssertTrue(ReaderTextEncoding.utf8.isASCIICompatible)
        XCTAssertTrue(ReaderTextEncoding.gb18030.isASCIICompatible)
        XCTAssertFalse(ReaderTextEncoding.utf16BigEndian.isASCIICompatible)
        XCTAssertTrue(ReaderTextEncoding.utf16LittleEndian.isUTF16)
        XCTAssertFalse(ReaderTextEncoding.utf8.isUTF16)
    }
}
