import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.PDFFillForm")
struct PDFFillFormToolTests {

    /// Prepends the bundled pdf-lib source, emulating the production
    /// JSPackages injection that SPM test bundles cannot reach.
    private struct PdfLibInjectingService: ScriptExecutionService {
        let base = JavaScriptExecutionService()
        let source: String
        func run(_ request: ScriptExecutionRequest, cancellation: CancellationToken?) async -> ScriptExecutionOutcome {
            var patched = request
            patched.script = "if (typeof setTimeout === 'undefined') { var setTimeout = function(fn) { Promise.resolve().then(function(){ fn(); }); return 0; }; } var clearTimeout = function() {};\n" + source + "\n" + request.script
            return await base.run(patched, cancellation: cancellation)
        }
    }

    private static func pdfLibSource() throws -> String {
        // Tests/FloeExecutionTests -> FloeAgent/FloeApp/Resources/js-packages
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FloeExecutionTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // FloeAgent
            .appendingPathComponent("FloeApp/Resources/js-packages/pdf-lib.min.js")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Builds a real AcroForm PDF through the same engine.
    private static func makeFormPDF(service: any ScriptExecutionService) async throws -> Data {
        let script = #"""
        (async()=>{
          const doc=await PDFLib.PDFDocument.create();
          const page=doc.addPage([400,300]);
          const form=doc.getForm();
          const nameField=form.createTextField('applicant.name');
          nameField.setText('');
          nameField.addToPage(page,{x:40,y:220,width:200,height:24});
          const agree=form.createCheckBox('agree.terms');
          agree.addToPage(page,{x:40,y:180,width:16,height:16});
          const plan=form.createDropdown('plan.tier');
          plan.addOptions(['free','pro','team']);
          plan.addToPage(page,{x:40,y:120,width:120,height:24});
          const out=await doc.save();
          printJSON({pdf:(function(u){const c='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';let s='';for(let i=0;i<u.length;i+=3){const a=u[i],b=i+1<u.length?u[i+1]:null,d=i+2<u.length?u[i+2]:null;s+=c[a>>2]+c[((a&3)<<4)|(b===null?0:b>>4)]+(b===null?'=':c[((b&15)<<2)|(d===null?0:d>>6)])+(d===null?'=':c[d&63]);}return s;})(out)});
        })();
        """#
        let outcome = await service.run(ScriptExecutionRequest(script: script, timeout: 30), cancellation: nil)
        guard case .ok(let resultJSON, _, _, _, _, _) = outcome,
              let resultJSON,
              let object = try JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [String: Any],
              let encoded = object["pdf"] as? String,
              let data = Data(base64Encoded: encoded) else {
            Issue.record("form fixture outcome: \(outcome)")
            throw FloeError.internalError("form fixture could not be created")
        }
        return data
    }

    @Test("descriptor and validation")
    func validation() {
        #expect(PDFFillFormTool.name == "document.pdf.fillForm")
        #expect(PDFFillFormTool.isSideEffecting)
        let tool = PDFFillFormTool()
        #expect(throws: FloeError.self) { try tool.validate(.init(action: "edit", inputPath: "a.pdf")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: "fill", inputPath: "a.pdf")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: "fill", inputPath: "../a.pdf", fills: "{}")) }
        try! tool.validate(.init(action: "list", inputPath: "a.pdf"))
        try! tool.validate(.init(action: "fill", inputPath: "a.pdf", fills: #"{"name":"x"}"#))
    }

    @Test("list reports AcroForm fields through the bundled pdf-lib")
    func listFields() async throws {
        let service = PdfLibInjectingService(source: try Self.pdfLibSource())
        let pdf = try await Self.makeFormPDF(service: service)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-form-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try pdf.write(to: root.appendingPathComponent("form.pdf"))

        let tool = PDFFillFormTool(service: service)
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let output = try await tool.execute(.init(action: "list", inputPath: "form.pdf"), context: context)
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("applicant.name"))
        #expect(output.summary.contains("agree.terms"))
        #expect(output.summary.contains("plan.tier"))
    }

    @Test("fill applies per-type values and never writes invalid options")
    func fillFields() async throws {
        let service = PdfLibInjectingService(source: try Self.pdfLibSource())
        let pdf = try await Self.makeFormPDF(service: service)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-form-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try pdf.write(to: root.appendingPathComponent("form.pdf"))

        let tool = PDFFillFormTool(service: service)
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let fills = #"{"applicant.name":"Zhang San","agree.terms":true,"plan.tier":"pro","missing.field":"x"}"#
        let output = try await tool.execute(.init(action: "fill", inputPath: "form.pdf", fills: fills), context: context)
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("applied=3"), "summary: \(output.summary)")
        #expect(output.summary.contains("skipped=1"), "summary: \(output.summary)")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("form-filled.pdf").path))

        // The filled PDF lists the same fields and round-trips through the engine.
        let listed = try await tool.execute(.init(action: "list", inputPath: "form-filled.pdf"), context: context)
        #expect(listed.summary.contains("applicant.name"))

        // Invalid dropdown option is skipped, not applied.
        let badFills = #"{"plan.tier":"enterprise"}"#
        let rejected = try await tool.execute(
            .init(action: "fill", inputPath: "form.pdf", fills: badFills, outputPath: "second.pdf"),
            context: context
        )
        #expect(rejected.exitStatus == 0)
        #expect(rejected.summary.contains("skipped=1"))
    }
}
