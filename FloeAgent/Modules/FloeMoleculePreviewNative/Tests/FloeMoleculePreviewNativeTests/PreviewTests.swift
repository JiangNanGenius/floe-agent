import XCTest
@testable import FloeMoleculePreviewNative

final class PreviewTests: XCTestCase {
    func testRealGenerationAndDeterministicCoordinates() async throws {
        let first = try await MoleculePreviewNative.generate(input: "CCO", format: .smiles)
        let second = try await MoleculePreviewNative.generate(input: "CCO", format: .smiles)
        XCTAssertEqual(first.atomCount, 9)
        XCTAssertEqual(first.inputAtomToOutput, [0, 1, 2])
        XCTAssertEqual(first.cjson, second.cjson)
        XCTAssertTrue(first.molblock.contains("3D"))
        XCTAssertTrue(first.specifiedStereoPreserved)
        XCTAssertEqual(first.method, "ETKDGv3")
    }
    func testInvalidAndCancelledRequestsFailExplicitly() async throws {
        do { _ = try await MoleculePreviewNative.generate(input: "C(C)(C)(C)(C)C", format: .smiles); XCTFail("Invalid valence accepted") }
        catch let error as MoleculePreviewError { XCTAssertEqual(error.code, "invalidMolecule") }
        let token = try MoleculePreviewCancellation(); token.cancel()
        do { _ = try await MoleculePreviewNative.generate(input: "CCO", format: .smiles, cancellation: token); XCTFail("Cancelled generation accepted") }
        catch let error as MoleculePreviewError { XCTAssertEqual(error.code, "cancelled") }
        XCTAssertEqual(token.stage, 4)
    }
}
