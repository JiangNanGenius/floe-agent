import Foundation
import XCTest
@testable import FloeDesktopSync

final class ProtocolAndJSONTests: XCTestCase {
    func testSHA256MatchesPublishedVectors() {
        XCTAssertEqual(
            ContentDigest.compute(Array("".utf8)).description,
            "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            ContentDigest.compute(Array("abc".utf8)).description,
            "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            ContentDigest.compute(
                Array("The quick brown fox jumps over the lazy dog".utf8)
            ).description,
            "sha256:d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        )
    }

    func testCanonicalJSONIgnoresKeyOrderWhitespaceAndDuplicatesDigest() throws {
        let first = try JSONValue.parse(#"{ "b": 2, "a": [true, null, "x"] }"#)
        let second = try JSONValue.parse(#"{"a":[true,null,"x"],"b":2}"#)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.canonicalJSON(), #"{"a":[true,null,"x"],"b":2}"#)
        XCTAssertEqual(
            ContentDigest.compute(first.canonicalUTF8),
            ContentDigest.compute(second.canonicalUTF8)
        )
    }

    func testParserRejectsFractionalNumbersDuplicateKeysAndTrailingData() {
        XCTAssertThrowsError(try JSONValue.parse("1.5")) { error in
            XCTAssertEqual(
                error as? JSONValueParseError,
                .unsupportedNumber("1.5", offset: 0)
            )
        }
        XCTAssertThrowsError(try JSONValue.parse(#"{"a":1,"a":2}"#)) { error in
            guard case .duplicateKey(let key, _)? = error as? JSONValueParseError else {
                return XCTFail("expected duplicate-key error, got \(error)")
            }
            XCTAssertEqual(key, "a")
        }
        XCTAssertThrowsError(try JSONValue.parse("{} trailing")) { error in
            guard case .trailingData? = error as? JSONValueParseError else {
                return XCTFail("expected trailing-data error, got \(error)")
            }
        }
        XCTAssertThrowsError(try JSONValue.parse(#"{"a": 01}"#))
        XCTAssertThrowsError(try JSONValue.parse(#""\ud800""#))
    }

    func testParserAcceptsEscapedUnicodeAndReencodesCanonically() throws {
        let value = try JSONValue.parse(#"{"note":"\u4f60\u597d\n\ud83d\ude00"}"#)
        XCTAssertEqual(value["note"]?.stringValue, "你好\n😀")
        XCTAssertEqual(value.canonicalJSON(), #"{"note":"你好\n😀"}"#)
        let roundTrip = try JSONValue.parse(value.canonicalJSON())
        XCTAssertEqual(roundTrip, value)
    }

    func testIdentifiersRejectPathDerivedStringsAndNormalizeUUIDs() throws {
        let identifier = try TaskID(
            validating: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        )
        XCTAssertEqual(
            identifier.canonical,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )
        XCTAssertThrowsError(try TaskID(validating: "/Users/alice/notes/task"))
        XCTAssertThrowsError(try TaskID(validating: "task-1234"))
        XCTAssertThrowsError(try Revision(0))
        XCTAssertThrowsError(try ExecutionEpoch(0))
        XCTAssertThrowsError(try ChangeCursor(-1))
        XCTAssertThrowsError(try Revision(decimalString: "1.0"))
        XCTAssertThrowsError(try ExecutionEpoch(decimalString: "02x"))
        XCTAssertEqual(try Revision(decimalString: "12").rawValue, 12)
        XCTAssertEqual(try ExecutionEpoch(decimalString: "3").rawValue, 3)
        XCTAssertEqual(ChangeCursor.zero.rawValue, 0)

        let legacy = try LegacyBridgeIdentifier(
            validating: "/Users/alice/notes/task"
        )
        XCTAssertEqual(legacy.rawValue, "/Users/alice/notes/task")
        XCTAssertThrowsError(try LegacyBridgeIdentifier(validating: ""))
    }

    func testPortablePathRules() throws {
        try PortabilityPolicy.validatePortableRelativePath("notes/a.md")
        try PortabilityPolicy.validatePortableRelativePath("中文/说明.md")
        for path in [
            "/Users/alice/a.md",
            "../a.md",
            "notes/../../a.md",
            "notes//a.md",
            "notes\\a.md",
            "C:/notes/a.md",
            "~/notes/a.md",
            "file:///tmp/a.md"
        ] {
            XCTAssertThrowsError(
                try PortabilityPolicy.validatePortableRelativePath(path),
                "expected \(path) to be rejected"
            )
        }
    }

    func testPortabilityPolicyRejectsDeviceLocalKeysRecursively() {
        let payload = JSONValue.object([
            "task": .object([
                "metadata": .array([
                    .object(["rootPath": .string("/Users/alice")])
                ])
            ])
        ])
        XCTAssertThrowsError(try PortabilityPolicy.validate(payload)) { error in
            XCTAssertEqual(error as? SyncStoreError, .nonPortableField("rootPath"))
        }
        XCTAssertNoThrow(
            try PortabilityPolicy.validate(.object(["logicalPath": .string("notes/a.md")]))
        )
    }

    func testWireCommandRequiresVersionAndDecimalEpochStrings() throws {
        let base = """
        {
          "protocolMajor": 1,
          "protocolMinor": 0,
          "commandID": "00000000-0000-4000-8000-000000000001",
          "kind": "run.stop",
          "taskID": "00000000-0000-4000-8000-000000000002",
          "runID": "00000000-0000-4000-8000-000000000003",
          "executionEpoch": "3",
          "payload": {"reason": "user"}
        }
        """
        let command = try SyncCommand(wireJSON: base)
        XCTAssertEqual(command.protocolVersion, .v1)
        XCTAssertEqual(command.executionEpoch?.rawValue, 3)
        XCTAssertEqual(command.runID?.canonical, "00000000-0000-4000-8000-000000000003")
        XCTAssertEqual(try SyncCommand(wireJSON: command.wireJSON()), command)

        let numericEpoch = base.replacingOccurrences(
            of: #""executionEpoch": "3""#,
            with: #""executionEpoch": 3"#
        )
        XCTAssertThrowsError(try SyncCommand(wireJSON: numericEpoch))

        let futureMajor = base.replacingOccurrences(
            of: #""protocolMajor": 1"#,
            with: #""protocolMajor": 2"#
        )
        XCTAssertThrowsError(try SyncCommand(wireJSON: futureMajor)) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .unsupportedProtocolVersion(major: 2, minor: 0)
            )
        }
    }

    func testCanonicalByteCountMatchesEncodingForUnicodeAndEscapes() {
        let value = JSONValue.object([
            "title": .string("说明 \"quoted\"\n\u{0001}"),
            "nested": .array([
                .integer(-12),
                .bool(true),
                .null,
                .object(["ключ": .string("значение")])
            ])
        ])
        let encoded = value.canonicalUTF8.count
        XCTAssertEqual(value.canonicalByteCount(upTo: encoded + 10), encoded)
        XCTAssertEqual(value.canonicalByteCount(upTo: encoded), encoded)
        XCTAssertEqual(value.canonicalByteCount(upTo: encoded - 1), encoded)
    }

}
