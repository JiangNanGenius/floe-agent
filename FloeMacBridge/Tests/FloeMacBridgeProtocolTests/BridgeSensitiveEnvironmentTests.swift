import XCTest
@testable import FloeMacBridgeProtocol

final class BridgeSensitiveEnvironmentTests: XCTestCase {
    private let secret = "bridge-secret-sentinel-7f2a"

    func testCapabilityAndMetadataCarryNamesOnly() throws {
        XCTAssertEqual(BridgeSensitiveEnvironment.capability, "sensitiveEnvironmentV1")
        let metadata = BridgeSensitiveEnvironment.metadata(names: ["OPENAI_API_KEY"])
        let text = try XCTUnwrap(String(data: BridgeWire.encode(metadata), encoding: .utf8))
        XCTAssertTrue(text.contains("OPENAI_API_KEY"))
        XCTAssertTrue(text.contains(BridgeSensitiveEnvironment.capability))
        XCTAssertFalse(text.contains(secret))
    }

    func testNameValidationRejectsInvalidAndReserved() throws {
        XCTAssertNoThrow(try BridgeSensitiveEnvironment.validatedNames(["OPENAI_API_KEY", "_PRIVATE", "A1"]))
        XCTAssertThrowsError(try BridgeSensitiveEnvironment.validatedNames(["BAD-NAME"]))
        XCTAssertThrowsError(try BridgeSensitiveEnvironment.validatedNames(["1BAD"]))
        XCTAssertThrowsError(try BridgeSensitiveEnvironment.validatedNames([""]))
        XCTAssertThrowsError(try BridgeSensitiveEnvironment.validatedNames(["DUP", "DUP"]))
        for name in BridgeSensitiveEnvironment.reservedNames {
            XCTAssertThrowsError(try BridgeSensitiveEnvironment.validatedNames([name]), name)
        }
        XCTAssertThrowsError(try BridgeSensitiveEnvironment.validatedNames(
            (0...BridgeSensitiveEnvironment.maximumNames).map { "V\($0)" }
        ))
    }

    func testTypedRequestField() throws {
        let value = BridgeValue.array([.string("OPENAI_API_KEY"), .string("TOKEN")])
        XCTAssertEqual(try BridgeSensitiveEnvironment.names(from: value), ["OPENAI_API_KEY", "TOKEN"])
        XCTAssertEqual(try BridgeSensitiveEnvironment.names(from: nil), [])
        XCTAssertThrowsError(try BridgeSensitiveEnvironment.names(from: .string("OPENAI_API_KEY")))
        XCTAssertThrowsError(try BridgeSensitiveEnvironment.names(from: .array([.integer(1)])))
    }

    func testRedactsExactValuesAndLeavesOrdinaryText() throws {
        var redactor = try BridgeSensitiveRedactor(names: ["OPENAI_API_KEY"], environment: ["OPENAI_API_KEY": secret])
        let output = redactor.redact(Data("value=\(secret); other=\(secret) tail".utf8))
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertEqual(text, "value=[REDACTED]; other=[REDACTED] tail")
    }

    func testSplitValueAcrossChunksIsRemoved() throws {
        var redactor = try BridgeSensitiveRedactor(names: ["OPENAI_API_KEY"], environment: ["OPENAI_API_KEY": secret])
        let split = secret.index(secret.startIndex, offsetBy: 6)
        let first = String(secret[..<split])
        let second = String(secret[split...])
        var output = Data("value=".utf8)
        output.append(redactor.redact(Data(first.utf8)))
        output.append(redactor.redact(Data(second.utf8)))
        output.append(redactor.redact(Data(" done".utf8), flush: true))
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertEqual(text, "value=[REDACTED] done")
    }

    func testFlushNeverEmitsPartialPrefix() throws {
        var redactor = try BridgeSensitiveRedactor(names: ["OPENAI_API_KEY"], environment: ["OPENAI_API_KEY": secret])
        let partial = String(secret.prefix(5))
        let held = redactor.redact(Data("value=\(partial)".utf8))
        XCTAssertFalse(String(decoding: held, as: UTF8.self).contains(partial))
        let tail = redactor.redact(Data(), flush: true)
        let text = String(decoding: tail, as: UTF8.self)
        XCTAssertFalse(text.contains(partial))
        XCTAssertEqual(text, "[REDACTED]")
    }

    func testOverlappingValuesLongestFirst() throws {
        var redactor = try BridgeSensitiveRedactor(
            names: ["LONG", "SHORT"],
            environment: ["LONG": "abcdef", "SHORT": "abc"]
        )
        let output = redactor.redact(Data("xxabcdefyy".utf8), flush: true)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "xx[REDACTED]yy")
    }

    func testMissingOrEmptyValueFailsClosedOnlyWhenMissing() throws {
        XCTAssertThrowsError(try BridgeSensitiveRedactor(names: ["TOKEN"], environment: [:]))
        XCTAssertNoThrow(try BridgeSensitiveRedactor(names: ["TOKEN"], environment: ["TOKEN": ""]))
    }

    func testOrdinaryJobHasNoRedactorWork() throws {
        var redactor = try BridgeSensitiveRedactor(names: [], environment: ["ORDINARY": "value"])
        XCTAssertFalse(redactor.isActive)
        let output = redactor.redact(Data("ordinary value".utf8), flush: true)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "ordinary value")
    }
}
