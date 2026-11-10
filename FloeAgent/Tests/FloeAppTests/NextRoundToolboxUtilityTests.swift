import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxUtilities
@testable import FloeToolboxWorkbenches

private actor ChecksumGate {
    var started=false
    private var opened=false
    private var waiters=[CheckedContinuation<Void,Never>]()
    func wait() async {started=true;if opened {return};await withCheckedContinuation {waiters.append($0)}}
    func open() {opened=true;let pending=waiters;waiters=[];for waiter in pending {waiter.resume()}}
}
@MainActor private final class FileSelections {
    enum Choice {case file(ToolboxSelectedChecksumFile),failure,none,gated(ChecksumGate,ToolboxSelectedChecksumFile)}
    var choices:[Choice]
    var count=0
    init(_ choices:[Choice]) {self.choices=choices}
    func select() async throws -> ToolboxSelectedChecksumFile? {
        count+=1
        guard !choices.isEmpty else {throw ToolboxError.invalid("No remaining fixture file")}
        switch choices.removeFirst() {
        case .file(let file):return file
        case .failure:throw ToolboxError.denied
        case .none:return nil
        case .gated(let gate,let file):await gate.wait();return file
        }
    }
}
@MainActor @Suite("RQ32 actual utility input/result identity and owned cancellation",.serialized)
struct NextRoundToolboxUtilityTests {
    private func file(_ title:String,_ text:String,gate:ChecksumGate?=nil,expected:UInt64?=nil)->ToolboxSelectedChecksumFile {
        let data=Data(text.utf8)
        return .init(title:title,byteCount:expected ?? UInt64(data.count)) {offset,maximum in
            if offset==0,let gate {await gate.wait()}
            return offset<UInt64(data.count) ? Data(data[Int(offset)..<min(data.count,Int(offset)+maximum)]):Data()
        }
    }
    private func settle(_ model:ChecksumWorkbenchModel) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while model.busy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(1))}
        try #require(!model.busy,"The owned checksum did not settle before the bounded deadline")
    }
    private func entered(_ gate:ChecksumGate) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while !(await gate.started),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(1))}
        try #require(await gate.started,"The exact fixture read/selection never began")
    }
    @Test("A failed new file cannot retain the prior successful digest or file identity")
    func failedReplacementClearsOldResult() async throws {
        let selections=FileSelections([.file(file("first.bin","abc")),.failure])
        let model=ChecksumWorkbenchModel {try await selections.select()}
        model.selectAndCalculate();try await settle(model)
        #expect(model.result?.hexadecimal=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        model.comparison="retained user input"
        model.selectAndCalculate()
        #expect(model.result==nil && model.title.isEmpty && model.busy)
        try await settle(model)
        #expect(model.failed && model.result==nil && model.title.isEmpty)
        #expect(model.comparison=="retained user input")
    }
    @Test("Changing the algorithm invalidates the old digest and the next result records its actual algorithm")
    func algorithmIdentity() async throws {
        let selections=FileSelections([.file(file("first.bin","abc")),.file(file("second.bin","abc"))])
        let model=ChecksumWorkbenchModel {try await selections.select()}
        model.selectAndCalculate();try await settle(model)
        model.algorithm = .md5
        #expect(model.result==nil && model.title.isEmpty && !model.failed)
        model.selectAndCalculate();try await settle(model)
        #expect(model.result?.algorithm == .md5)
        #expect(model.result?.hexadecimal=="900150983cd24fb0d6963f7d28e17f72")
        #expect(model.title=="second.bin" && model.expectedBytes==3 && model.completedBytes==3)
    }
    @Test("Stop waits for the owned reader to drain, refuses an overlapping run and cannot publish its late digest")
    func cancelDrainAndRetry() async throws {
        let gate=ChecksumGate(),selections=FileSelections([.file(file("held.bin","abc",gate:gate)),.file(file("retry.bin","next"))])
        let model=ChecksumWorkbenchModel {try await selections.select()}
        model.selectAndCalculate();try await entered(gate)
        model.cancel()
        #expect(model.stopping && model.busy && model.result==nil)
        model.selectAndCalculate()
        #expect(selections.count==1)
        await gate.open();try await settle(model)
        #expect(model.cancelled && !model.stopping && !model.failed && model.result==nil)
        model.selectAndCalculate();try await settle(model)
        #expect(model.title=="retry.bin" && model.result?.byteCount==4 && !model.cancelled)
        #expect(model.result?.hexadecimal=="c6c1c9a9c8543f1e4cd980064cf1625eeb61a90703b2464fff039f21682508b3")
    }
    @Test("An algorithm change while the file picker waits cannot reinterpret that old selection")
    func algorithmChangeDuringSelection() async throws {
        let gate=ChecksumGate(),selections=FileSelections([.gated(gate,file("old.bin","abc")),.file(file("new.bin","abc"))])
        let model=ChecksumWorkbenchModel {try await selections.select()}
        model.selectAndCalculate();try await entered(gate)
        model.algorithm = .md5
        #expect(model.busy && model.stopping && model.result==nil)
        await gate.open();try await settle(model)
        #expect(model.result==nil && model.title.isEmpty)
        model.selectAndCalculate();try await settle(model)
        #expect(model.title=="new.bin" && model.result?.algorithm == .md5)
    }
    @Test("Cancelling the picker leaves a true empty result, not a successful checksum from the previous file")
    func pickerCancellation() async throws {
        let selections=FileSelections([.file(file("first.bin","abc")),.none])
        let model=ChecksumWorkbenchModel {try await selections.select()}
        model.selectAndCalculate();try await settle(model)
        model.selectAndCalculate();try await settle(model)
        #expect(model.result==nil && model.title.isEmpty && !model.failed && !model.cancelled)
    }
    @Test("A source-size mismatch fails without publishing a digest for changed bytes")
    func sourceSizeMismatch() async throws {
        let selections=FileSelections([.file(file("changed.bin","abcd",expected:3))])
        let model=ChecksumWorkbenchModel {try await selections.select()}
        model.selectAndCalculate();try await settle(model)
        #expect(model.failed && model.result==nil && model.title=="changed.bin")
        #expect(model.completedBytes==4 && model.expectedBytes==3)
    }
    @Test("Encoding/decoding and JSON errors retain the actual input while clearing obsolete derived output")
    func conversionResultIdentity() {
        let model=ToolboxTextUtilityModel()
        model.input="Hello 世界";model.perform(.base64Encode)
        let encoded=model.output
        #expect(!encoded.isEmpty && model.lastAction == .base64Encode && !model.failed)
        model.input=encoded
        #expect(model.output.isEmpty && model.lastAction==nil)
        model.perform(.base64Decode)
        #expect(model.output=="Hello 世界" && model.lastAction == .base64Decode)
        model.input="{broken JSON";model.perform(.formatJSON)
        #expect(model.failed && model.output.isEmpty && model.input=="{broken JSON")
        model.input=#"{"b":2,"a":1}"#;model.perform(.sortJSON)
        #expect(!model.failed && model.output.range(of:"\"a\"")!.lowerBound<model.output.range(of:"\"b\"")!.lowerBound)
    }
}
