// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore
import FloeLaTeXWorkerResources

public struct LaTeXEnvironmentCommandResult:Sendable {
    public var stdout:String;public var exitStatus:Int;public var workerStopped:Bool
    public init(stdout:String,exitStatus:Int,workerStopped:Bool) {self.stdout=stdout;self.exitStatus=exitStatus;self.workerStopped=workerStopped}
}
/// Implemented by the host's existing exec.shell + jobs service, with a frozen
/// resolved environment/run binding. It must join an owned worker on cancel.
public protocol LaTeXEnvironmentTransport:Sendable {
    var owner:LaTeXExecutionOwner {get}
    var isLocal:Bool {get}
    func authorize(relativePath:String) async throws
    func execute(script:String,maximumOutputBytes:Int) async throws -> LaTeXEnvironmentCommandResult
    func run(script:String,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEnvironmentCommandResult
}
public struct LaTeXEnvironmentQualification:Sendable {
    public var environmentID:String
    public var engines:[String:String]
    public var tools:[String:String]
    public var workerSHA256:String
    public var isLocal:Bool
    public init(environmentID:String,engines:[String:String],tools:[String:String],workerSHA256:String,isLocal:Bool) {self.environmentID=environmentID;self.engines=engines;self.tools=tools;self.workerSHA256=workerSHA256;self.isLocal=isLocal}
}

public struct LaTeXLinuxEngine:LaTeXEngineRunning {
    private let qualification:LaTeXEnvironmentQualification
    private let transport:any LaTeXEnvironmentTransport
    private static let programs:[LaTeXEngine:String]=[.xeLaTeX:"xelatex",.luaLaTeX:"lualatex",.pdfLaTeX:"pdflatex",.latex:"latex"]
    public init(qualification:LaTeXEnvironmentQualification,transport:any LaTeXEnvironmentTransport) throws {
        guard qualification.environmentID==transport.owner.environmentID,qualification.isLocal==transport.isLocal,qualification.workerSHA256==LaTeXDigest.hash(try LaTeXWorkerResources.verifiedSource()) else {throw LaTeXError.unavailable("The qualified TeX environment changed. Probe this task's resolved environment again.")}
        self.qualification=qualification;self.transport=transport
    }
    public static func probe(transport:any LaTeXEnvironmentTransport) async throws -> LaTeXEnvironmentQualification {
        guard let id=transport.owner.environmentID else {throw LaTeXError.unavailable("Resolve a Linux environment for this task first.")}
        let worker=try LaTeXWorkerResources.verifiedSource()
        let script="""
        import base64,json,sys
        sys.dont_write_bytecode=True
        namespace={'__name__':'floe_latex_probe'}
        exec(compile(base64.b64decode('\(worker.base64EncodedString())'),'floe_latex_worker.py','exec'),namespace)
        print('FLOE_LATEX_RECEIPT '+base64.b64encode(json.dumps(namespace['probe']()).encode()).decode())
        """
        let result=try await transport.execute(script:python(script),maximumOutputBytes:32768)
        let value:Probe=try decode(result)
        if let reason=value.unavailableReason {throw LaTeXError.unavailable(reason)}
        return .init(environmentID:id,engines:value.engines,tools:value.tools,workerSHA256:LaTeXDigest.hash(worker),isLocal:transport.isLocal)
    }
    public func capabilities() async -> [LaTeXEngineCapability] {
        Self.programs.compactMap {engine,program in
            guard let version=qualification.engines[program] else{return nil}
            guard engine != .latex || qualification.tools["dvipdfmx"] != nil else{return nil}
            return .init(engine:engine,version:version,bibliography:["bibtex","biber"].filter{qualification.tools[$0] != nil}.map{$0=="biber" ? "Biber":"BibTeX"},isLocal:qualification.isLocal,environmentID:qualification.environmentID,auxiliaryTools:qualification.tools)
        }.sorted{$0.engine.rawValue<$1.engine.rawValue}
    }
    public func run(_ request:LaTeXEngineRequest,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEngineOutput {
        guard request.executionOwner==transport.owner,let environmentID=transport.owner.environmentID,
              let program=Self.programs[request.snapshot.manifest.engine],qualification.engines[program] != nil else {throw LaTeXError.unavailable("Typesetting must use this run's explicitly resolved and qualified Linux environment.")}
        let requestID=UUID(),directory=".floe-latex/"+request.snapshot.manifest.id.uuidString.lowercased()+"/"+requestID.uuidString.lowercased()
        try await transport.authorize(relativePath:directory)
        progress("Preparing the project in the selected environment")
        let setup="""
        import pathlib,os
        root=pathlib.Path('\(directory)')
        assert root.resolve()==pathlib.Path.cwd()/root
        root.mkdir(parents=True,exist_ok=False)
        (root/'Source').mkdir()
        """
        try check(await transport.execute(script:Self.python(setup),maximumOutputBytes:4096))
        let worker=try LaTeXWorkerResources.verifiedSource()
        try await put(worker,path:directory+"/worker.py")
        let payload=Payload(requestID:requestID,environmentID:environmentID,manifest:request.snapshot.manifest,timeoutSeconds:request.configuration.timeoutSeconds,offline:request.configuration.offline,buildTimestamp:Int(request.buildDate.timeIntervalSince1970))
        try await put(LaTeXDigest.encode(payload),path:directory+"/request.json")
        for file in request.snapshot.manifest.files {
            try Task.checkCancellation()
            let url=try LaTeXPath.child(file.path,root:request.snapshot.sourceRoot),data=try Data(contentsOf:url,options:.mappedIfSafe)
            guard data.count==file.byteCount,LaTeXDigest.hash(data)==file.sha256 else {throw LaTeXError.changedFile(file.path)}
            try await put(data,path:directory+"/Source/"+file.path)
        }
        progress("Typesetting in the selected environment")
        let command="python3 '"+directory+"/worker.py' build --request '"+directory+"/request.json'"
        let execution:LaTeXEnvironmentCommandResult
        do {execution=try await transport.run(script:command,progress:progress)}
        catch let failure as LaTeXEngineFailure {throw failure}
        catch {throw LaTeXEngineFailure("The typesetting worker's outcome is unknown.",messages:[error.localizedDescription],workerStopped:false)}
        guard execution.workerStopped else {throw LaTeXEngineFailure("The environment has not confirmed that its typesetting worker stopped. Reconcile the existing job before starting another.",workerStopped:false)}
        let terminal:Terminal
        do {terminal=try Self.decode(execution,allowFailure:true)}
        catch {throw LaTeXEngineFailure("No complete typesetting worker exit receipt was returned.",messages:[String(execution.stdout.suffix(8192))],workerStopped:false)}
        guard terminal.protocolName=="floe.latex.worker",terminal.version==1,terminal.workerStopped,
              terminal.receiptBytes>0,terminal.receiptBytes<=4*1024*1024 else {throw LaTeXError.invalidOperation("The environment returned an invalid build receipt.")}
        var receiptData=Data()
        while receiptData.count<terminal.receiptBytes {
            let count=min(16384,terminal.receiptBytes-receiptData.count)
            let command="python3 '"+directory+"/worker.py' receipt --request '"+directory+"/request.json' --offset "+String(receiptData.count)+" --length "+String(count)
            let chunk:Chunk=try Self.decode(await transport.execute(script:command,maximumOutputBytes:32768))
            guard let data=Data(base64Encoded:chunk.bytes),data.count==count else {throw LaTeXError.invalidOperation("The build receipt read-back was incomplete.")}
            receiptData+=data
        }
        guard LaTeXDigest.hash(receiptData)==terminal.receiptSHA256 else {throw LaTeXError.checksumMismatch("build receipt")}
        let receipt=try JSONDecoder().decode(Receipt.self,from:receiptData)
        guard receipt.requestID==requestID,receipt.projectID==request.snapshot.manifest.id,receipt.revision==request.snapshot.manifest.revision,receipt.environmentID==environmentID,
              receipt.protocolName=="floe.latex.worker",receipt.version==1,receipt.workerStopped,
              let artifacts=receipt.artifacts,artifacts.count<=10000 else {throw LaTeXError.invalidOperation("The environment returned a mismatched typesetting receipt.")}
        var total=0,paths=Set<String>()
        try FileManager.default.createDirectory(at:request.outputRoot,withIntermediateDirectories:true)
        for artifact in artifacts {
            guard paths.insert(LaTeXPath.collisionKey(try LaTeXPath.validate(artifact.path))).inserted else {throw LaTeXError.duplicatePath(artifact.path)}
            guard artifact.byteCount>=0,artifact.byteCount<=256*1024*1024 else {throw LaTeXError.limitExceeded("build output")}
            total+=artifact.byteCount;guard total<=256*1024*1024 else {throw LaTeXError.limitExceeded("build output")}
            let target=try LaTeXPath.child(artifact.path,root:request.outputRoot,createParents:true)
            // Read bounded ranges through the same resolved transport. An
            // artifact is published only after exact length + digest validation.
            var bytes=Data();bytes.reserveCapacity(artifact.byteCount)
            while bytes.count<artifact.byteCount {
                try Task.checkCancellation()
                let count=min(16384,artifact.byteCount-bytes.count)
                let metadata=try LaTeXDigest.encode(["file":artifact.path])
                let script="""
                import base64,json,os,pathlib
                path=json.loads(base64.b64decode('\(metadata.base64EncodedString())'))['file']
                root=pathlib.Path('\(directory)/Output').resolve()
                target=root/path
                assert root in target.resolve().parents and not target.is_symlink()
                fd=os.open(target,os.O_RDONLY|os.O_NOFOLLOW)
                with os.fdopen(fd,'rb') as stream:
                    assert os.fstat(stream.fileno()).st_size==\(artifact.byteCount)
                    stream.seek(\(bytes.count));data=stream.read(\(count));assert len(data)==\(count)
                print('FLOE_LATEX_RECEIPT '+base64.b64encode(json.dumps({'bytes':base64.b64encode(data).decode()}).encode()).decode())
                """
                let result=try await transport.execute(script:Self.python(script),maximumOutputBytes:32768)
                let piece:Chunk=try Self.decode(result)
                guard let data=Data(base64Encoded:piece.bytes),data.count==count else {throw LaTeXError.invalidOperation("The typesetting artifact read-back was incomplete.")}
                bytes+=data
            }
            guard LaTeXDigest.hash(bytes)==artifact.sha256 else {throw LaTeXError.checksumMismatch(artifact.path)}
            try bytes.write(to:target,options:.atomic)
        }
        let log=request.outputRoot.appendingPathComponent("worker.log")
        var messages=(try? String(contentsOf:log,encoding:.utf8)).map{[String($0.suffix(65536))]} ?? []
        // Verified outputs and diagnostics now survive in the App-owned build.
        // A cleanup failure preserves recoverable staging and is reported.
        do {
            let cleanup=try await transport.execute(script:"python3 '"+directory+"/worker.py' cleanup --request '"+directory+"/request.json'",maximumOutputBytes:4096)
            try check(cleanup)
        }catch {messages.append("Environment staging was retained: "+directory+" ("+error.localizedDescription+")")}
        guard receipt.success else {throw LaTeXEngineFailure(receipt.error ?? "Typesetting failed in the selected environment",messages:messages,cancelled:receipt.cancelled ?? false)}
        guard let pdf=receipt.pdf else {throw LaTeXError.missingFile("PDF")}
        let pdfURL=try LaTeXPath.child(pdf,root:request.outputRoot)
        guard artifacts.contains(where:{$0.path==pdf}),FileManager.default.fileExists(atPath:pdfURL.path) else {throw LaTeXError.missingFile(pdf)}
        return .init(pdf:pdfURL,version:receipt.engineVersion ?? program,messages:messages)
    }
    private func put(_ data:Data,path:String) async throws {
        _=try LaTeXPath.validate(path)
        let name=try LaTeXDigest.encode(["path":path])
        let create="""
        import pathlib,json,base64,os
        relative=json.loads(base64.b64decode('\(name.base64EncodedString())'))['path']
        root=pathlib.Path.cwd();target=root/relative
        assert root in target.resolve().parents
        parent=root
        for component in pathlib.PurePosixPath(relative).parts[:-1]:
            parent=parent/component
            assert not parent.is_symlink()
            parent.mkdir(exist_ok=True)
        fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600);os.close(fd)
        """
        try check(await transport.execute(script:Self.python(create),maximumOutputBytes:4096))
        for offset in stride(from:0,to:data.count,by:32768) {
            try Task.checkCancellation()
            let part=data[offset..<min(data.count,offset+32768)].base64EncodedString()
            let append="""
            import json,base64,os,pathlib
            path=json.loads(base64.b64decode('\(name.base64EncodedString())'))['path']
            fd=os.open(path,os.O_WRONLY|os.O_APPEND|os.O_NOFOLLOW)
            with os.fdopen(fd,'ab') as stream:
                assert os.fstat(stream.fileno()).st_size==\(offset)
                stream.write(base64.b64decode('\(part)',validate=True))
            """
            try check(await transport.execute(script:Self.python(append),maximumOutputBytes:4096))
        }
    }
    private func check(_ result:LaTeXEnvironmentCommandResult)throws {
        guard result.exitStatus==0,result.workerStopped else {throw LaTeXEngineFailure("Project preparation did not complete in the selected environment.",messages:[String(result.stdout.suffix(8192))],workerStopped:result.workerStopped)}
    }
    private static func python(_ source:String)->String {"python3 - <<'FLOE_LATEX_COMPILED'\n"+source+"\nFLOE_LATEX_COMPILED"}
    private static func decode<T:Decodable>(_ result:LaTeXEnvironmentCommandResult,allowFailure:Bool=false)throws->T {
        guard result.workerStopped,allowFailure || result.exitStatus==0,
              let line=result.stdout.split(separator:"\n").last(where:{$0.hasPrefix("FLOE_LATEX_RECEIPT ")}),let bytes=Data(base64Encoded:String(line.dropFirst(19))) else {throw LaTeXEngineFailure("The selected environment returned no complete worker receipt.",messages:[String(result.stdout.suffix(8192))],workerStopped:result.workerStopped)}
        return try JSONDecoder().decode(T.self,from:bytes)
    }
    private struct Payload:Encodable {var `protocol`="floe.latex.worker";var version=1;var requestID:UUID;var environmentID:String;var manifest:LaTeXProjectManifest;var timeoutSeconds:Int;var offline:Bool=false;var buildTimestamp:Int}
    private struct Probe:Decodable {var engines:[String:String];var tools:[String:String];var unavailableReason:String?}
    private struct Chunk:Decodable {var bytes:String}
    private struct Artifact:Decodable {var path:String;var sha256:String;var byteCount:Int}
    private struct Terminal:Decodable {
        var protocolName:String;var version:Int;var workerStopped:Bool;var receiptBytes:Int;var receiptSHA256:String
        enum CodingKeys:String,CodingKey {case protocolName="protocol",version,workerStopped,receiptBytes,receiptSHA256}
    }
    private struct Receipt:Decodable {
        var protocolName:String;var version:Int;var workerStopped:Bool;var success:Bool;var error:String?;var cancelled:Bool?;var requestID:UUID?;var projectID:UUID?;var revision:Int64?;var environmentID:String?;var engineVersion:String?;var pdf:String?;var artifacts:[Artifact]?
        enum CodingKeys:String,CodingKey {case protocolName="protocol",version,workerStopped,success,error,cancelled,requestID,projectID,revision,environmentID,engineVersion,pdf,artifacts}
    }
}
