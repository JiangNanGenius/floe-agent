#if os(macOS)
import XCTest
import Foundation
import FloeLaTeXCore
import FloeLaTeXEngine

/// Qualification-only transport. The production target never imports Process
/// or executes on the host; these fixtures test its exact transfer scripts.
private actor ProtocolFixtureTransport:LaTeXEnvironmentTransport {
    nonisolated let owner=LaTeXExecutionOwner(taskID:UUID(),runID:UUID(),environmentID:"worker-protocol-fixture")
    nonisolated let isLocal=true
    let workspace:URL
    let bin:URL
    let missingReceipt:Bool
    let throwsAtRun:Bool
    init(root:URL,missingReceipt:Bool=false,throwsAtRun:Bool=false) throws {
        self.missingReceipt=missingReceipt;self.throwsAtRun=throwsAtRun
        workspace=root.appendingPathComponent("Environment");bin=root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
        let fixtures=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WorkerProtocol/test_worker.py")
        let source=try String(contentsOf:fixtures,encoding:.utf8)
        let start=try XCTUnwrap(source.range(of:"FAKE=r'''")),remaining=source[start.upperBound...]
        let end=try XCTUnwrap(remaining.range(of:"'''"));let script=String(remaining[..<end.lowerBound])
        for name in ["xelatex","lualatex","pdflatex","latex","bibtex","biber","makeindex","dvipdfmx","bwrap"] {
            let path=bin.appendingPathComponent(name);try Data(script.utf8).write(to:path)
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:path.path)
        }
    }
    func authorize(relativePath:String) async throws {_=try LaTeXPath.validate(relativePath)}
    func execute(script:String,maximumOutputBytes:Int) async throws->LaTeXEnvironmentCommandResult {try perform(script)}
    func run(script:String,progress:@escaping @Sendable (String)->Void) async throws->LaTeXEnvironmentCommandResult {
        progress("Deterministic worker protocol fixture")
        if throwsAtRun {throw NSError(domain:"FixtureLostTransport",code:1)}
        if missingReceipt {return .init(stdout:"exit=0\nNo complete worker receipt",exitStatus:0,workerStopped:true)}
        return try perform(script)
    }
    private func perform(_ script:String) throws->LaTeXEnvironmentCommandResult {
        let process=Process(),out=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c",script];process.currentDirectoryURL=workspace
        var env=ProcessInfo.processInfo.environment;env["PATH"]=bin.path+":"+(env["PATH"] ?? "/usr/bin:/bin");env["PYTHONDONTWRITEBYTECODE"]="1";process.environment=env
        process.standardOutput=out;process.standardError=out;try process.run()
        let data=out.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        return .init(stdout:"exit=\(process.terminationStatus)\n"+String(decoding:data,as:UTF8.self),exitStatus:Int(process.terminationStatus),workerStopped:true)
    }
}
final class LinuxProtocolTests:XCTestCase,@unchecked Sendable {
    func testTraditionalPDFCapabilityRequiresActualConverter() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let transport=try ProtocolFixtureTransport(root:root)
        var qualification=try await LaTeXLinuxEngine.probe(transport:transport)
        qualification.tools.removeValue(forKey:"dvipdfmx")
        let engine=try LaTeXLinuxEngine(qualification:qualification,transport:transport)
        let values=await engine.capabilities()
        XCTAssertFalse(values.contains{$0.engine == .latex})
        XCTAssertTrue(values.contains{$0.engine == .pdfLaTeX})
    }
    func testLostWorkerOutcomeRetainsSourceEvenWhenOuterShellClaimsExit() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        for missing in [true,false] {
            let directory=root.appendingPathComponent(String(missing))
            let transport=try ProtocolFixtureTransport(root:directory,missingReceipt:missing,throwsAtRun:!missing),qualification=try await LaTeXLinuxEngine.probe(transport:transport)
            let engine=try LaTeXLinuxEngine(qualification:qualification,transport:transport)
            let store=try LaTeXProjectStore.create(root:directory.appendingPathComponent("Project"),owner:.init(kind:.task,id:transport.owner.taskID),title:"Protocol fixture",files:["main.tex":Data("Source".utf8)])
            let service=try LaTeXBuildService(cacheRoot:directory.appendingPathComponent("Cache"),engine:engine)
            let started=try await service.start(store:store,executionOwner:transport.owner),result=try await service.wait(started.id)
            XCTAssertEqual(result.state,.interrupted);XCTAssertEqual(result.workerStopped,false)
            XCTAssertTrue(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("Snapshots/"+result.snapshotID.uuidString).path))
        }
    }
    func testProductionTransferProtocolReadsLargeReceiptAndCleansOnlyVerifiedStaging() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let transport=try ProtocolFixtureTransport(root:root),qualification=try await LaTeXLinuxEngine.probe(transport:transport)
        XCTAssertEqual(qualification.engines.count,4);XCTAssertNotNil(qualification.tools["biber"])
        let engine=try LaTeXLinuxEngine(qualification:qualification,transport:transport)
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),owner:.init(kind:.task,id:transport.owner.taskID),title:"Protocol fixture",files:["main.tex":Data("LARGE BIBTEX INDEX".utf8)])
        let service=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"),engine:engine)
        let started=try await service.start(store:store,expectedRevision:0,executionOwner:transport.owner)
        let result=try await service.wait(started.id);XCTAssertEqual(result.state,.succeeded,result.diagnostics.map(\.message).joined(separator:"\n"))
        let directory=store.root.appendingPathComponent("Builds/"+result.id.uuidString+"/Output")
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("document.bbl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("chapters/a.aux").path))
        let staging=await transport.workspace.appendingPathComponent(".floe-latex/"+(try await store.manifest().id.uuidString.lowercased()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:staging.path).isEmpty)
    }
    func testFailedWorkerCopiesDiagnosticLogBeforeReleasingSource() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let transport=try ProtocolFixtureTransport(root:root),qualification=try await LaTeXLinuxEngine.probe(transport:transport)
        let engine=try LaTeXLinuxEngine(qualification:qualification,transport:transport)
        let store=try LaTeXProjectStore.create(root:root.appendingPathComponent("Project"),owner:.init(kind:.task,id:transport.owner.taskID),title:"Protocol fixture",files:["main.tex":Data("FAIL".utf8)])
        let service=try LaTeXBuildService(cacheRoot:root.appendingPathComponent("Cache"),engine:engine)
        let started=try await service.start(store:store,executionOwner:transport.owner),result=try await service.wait(started.id)
        XCTAssertEqual(result.state,.failed);XCTAssertEqual(result.workerStopped,true)
        XCTAssertTrue(result.diagnostics.contains{$0.path=="main.tex" && $0.line==4 && $0.message.contains("Undefined control sequence")})
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("Snapshots").path).isEmpty)
    }
}
#endif
