// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation

/// Owns cancellation and publication across editing, reopening and view disappearance.
/// A late worker never replaces a newer source/result.
@MainActor @Observable public final class NCLocalSession {
    public private(set) var source = ""
    public private(set) var configuration = NCConfiguration()
    public private(set) var program: NCProgram?
    public private(set) var paths = [NCSampledPath]()
    public private(set) var report: NCRoundTripReport?
    public private(set) var error: String?
    public private(set) var busy = false
    public private(set) var revision = UUID()
    private var cancellation: NCCancellation?
    private var task: Task<Void,Never>?
    public init() {}
    public func replaceSource(_ source:String,configuration:NCConfiguration? = nil) {
        cancel(); self.source=source
        if let configuration { self.configuration=configuration }
        error=nil
    }
    public func cancel() {
        cancellation?.cancel(); task?.cancel(); task=nil;cancellation=nil
        revision=UUID();busy=false;program=nil;paths=[];report=nil
    }
    public func setTolerance(_ tolerance:Double) { cancel();configuration.chordToleranceMM=tolerance }
    public func calculate() {
        let source=self.source,configuration=self.configuration
        run { (source,configuration) }
    }
    public func reopen(_ url:URL) {
        run { let value=try NCArchive.open(url);return (value.source,value.program.configuration) }
    }
    public func save(to url:URL) throws {
        guard !busy,program != nil,report?.passed == true else { throw NCError("Interpret and verify the current source before saving") }
        try NCArchive.save(source:source,configuration:configuration,to:url)
    }
    public func export(to url:URL) throws {
        guard !busy,let program,report?.passed == true else { throw NCError("Interpret and verify the current source before exporting") }
        let text=NCCodec.encode(program)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(text.utf8).write(to:url,options:.atomic)
    }
    private struct Result:Sendable { let source:String;let program:NCProgram;let paths:[NCSampledPath];let report:NCRoundTripReport }
    private func run(_ load:@escaping @Sendable () throws -> (String,NCConfiguration)) {
        cancel();error=nil;busy=true
        let revision=self.revision,token=NCCancellation();cancellation=token
        let worker=Task.detached(priority:.userInitiated) {
            try token.check()
            let (source,configuration)=try load()
            let program=try NCCodec.decode(source,configuration:configuration,cancellation:token)
            let paths=try NCGeometry.sample(program,cancellation:token)
            let report=try NCVerification.roundTrip(program,cancellation:token)
            try token.check()
            return Result(source:source,program:program,paths:paths,report:report)
        }
        task=Task { [weak self] in
            do {
                let value=try await worker.value
                guard let self,self.revision == revision,!Task.isCancelled else { return }
                self.source=value.source;self.configuration=value.program.configuration
                self.program=value.program;self.paths=value.paths;self.report=value.report;self.busy=false
                self.cancellation=nil;self.task=nil
            } catch {
                guard let self,self.revision == revision,!Task.isCancelled else { return }
                self.busy=false;self.cancellation=nil;self.task=nil
                if !(error is CancellationError) { self.error=error.localizedDescription }
            }
        }
    }
}
