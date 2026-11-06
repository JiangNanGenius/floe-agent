import XCTest

// XCTest's ordinary assertion autoclosures cannot suspend. Evaluate the
// async expression first, preserving the original assertion and call site.
@MainActor
func XCTAssertEqualAsync<T: Equatable>(_ lhs: @autoclosure () async throws -> T,
                                       _ rhs: @autoclosure () async throws -> T,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
    let left = try await lhs()
    let right = try await rhs()
    XCTAssertEqual(left, right, file: file, line: line)
}

@MainActor
func XCTAssertNoThrowAsync<T>(_ expression: @autoclosure () async throws -> T,
                              file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression() }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

@MainActor
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ inspect: (any Error) -> Void = { _ in }) async {
    do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) }
    catch { inspect(error) }
}

@MainActor
func XCTAssertTrueAsync(_ expression: @autoclosure () async throws -> Bool,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
    let value = try await expression()
    XCTAssertTrue(value, file: file, line: line)
}

@MainActor
func XCTAssertFalseAsync(_ expression: @autoclosure () async throws -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
    let value = try await expression()
    XCTAssertFalse(value, file: file, line: line)
}
