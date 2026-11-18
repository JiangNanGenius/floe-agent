import Foundation
import Testing
import FloeToolboxUtilities
@testable import FloeMacToolbox

private actor TextChecksumGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
@Suite("Mac text checksum", .serialized)
struct MacTextChecksumTests {
    private func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    @Test func computesUTF8AndEmptyInputUsingSharedChecksum() async throws {
        let model = MacTextChecksumModel()
        model.input = "abc"
        model.calculate()
        #expect(await until { !model.busy })
        #expect(model.result?.hexadecimal == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(model.result?.matches("  BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD  ") == true)
        model.input = ""
        model.calculate()
        #expect(await until { !model.busy })
        #expect(model.result?.hexadecimal == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        model.input = "中文 🧭"
        model.algorithm = .md5
        model.calculate()
        #expect(await until { !model.busy })
        #expect(model.result?.hexadecimal == "8a3d0c3b2fb07d146207d9a02572e661")
        model.algorithm = .sha256
        model.input = "é"; model.calculate()
        #expect(await until { !model.busy })
        #expect(model.result?.hexadecimal == "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c")
        model.input = "e\u{0301}"
        #expect(model.result == nil)
        model.calculate()
        #expect(await until { !model.busy })
        #expect(model.result?.hexadecimal == "bf12767b0f2a56b2190075bae8169f656e3ce8d6357d4aff184bc6c7ea48f9f6")
    }

    @Test func editsFenceLateResultsAndOversizedInputIsRejected() async throws {
        let gate = TextChecksumGate()
        let model = MacTextChecksumModel { bytes, algorithm in
            await gate.wait()
            return try await MacTextChecksumModel.checksum(bytes, algorithm)
        }
        model.input = "é"
        model.calculate()
        for _ in 0..<500 {
            if await gate.entered { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await gate.entered)
        model.input = "e\u{0301}"
        #expect(!model.busy && model.result == nil)
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.result == nil)
        model.input = String(repeating: "x", count: MacTextChecksumModel.maximumInputBytes + 1)
        model.calculate()
        #expect(model.tooLarge && model.result == nil && !model.busy)
    }
}
