import XCTest

/// XCTest's XCTAssertThrowsError uses a synchronous autoclosure and cannot
/// accept `await`. This is the minimal async equivalent used across the
/// FloeCanvasKit qualification tests.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verifier: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown, but none was", file: file, line: line)
    } catch {
        verifier(error)
    }
}
