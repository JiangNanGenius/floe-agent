// FloeExecution — document.pdf.fillForm agent tool.
//
// AcroForm support through the bundled pdf-lib (pure JS, pre-installed via
// JSPackages) running in JavaScriptCore: list interactive fields or fill
// them with per-type validation. PDFKit cannot touch AcroForm fields, so
// this closes the form gap without a native engine.

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

/// Lists or fills interactive PDF (AcroForm) fields via bundled pdf-lib.
public struct PDFFillFormTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var inputPath: String
        /// Required for fill: {"fieldName": value}; text fields take strings,
        /// checkboxes take booleans, dropdown/radio/option lists take one of
        /// their options.
        public var fills: String?
        public var outputPath: String?

        public init(action: String, inputPath: String, fills: String? = nil, outputPath: String? = nil) {
            self.action = action
            self.inputPath = inputPath
            self.fills = fills
            self.outputPath = outputPath
        }
    }

    public static let name = "document.pdf.fillForm"
    public static let toolDescription =
        "Read or fill interactive PDF form (AcroForm) fields using the bundled pdf-lib engine. action=list returns every field's name and type; action=fill applies fills (JSON object: field name to value) with per-type validation and writes a new filled PDF to outputPath (default <name>-filled.pdf). Text fields take strings, checkboxes booleans, dropdown/radio/option lists one of their own options. Unknown fields and invalid options are reported per field, never silently applied. Existing outputs are never overwritten. For non-form text changes use document.pdf.edit."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"action":{"type":"string","enum":["list","fill"]},"inputPath":{"type":"string"},"fills":{"type":"string","description":"JSON object of field name to value (fill only)"},"outputPath":{"type":"string","description":"Workspace-relative output PDF (fill only)"}},"required":["action","inputPath"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: any ScriptExecutionService

    public init(service: any ScriptExecutionService = JavaScriptExecutionService()) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        guard ["list", "fill"].contains(args.action) else {
            throw FloeError.validationFailed("action must be list or fill")
        }
        for path in [args.inputPath, args.outputPath].compactMap({ $0 }) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
                  !trimmed.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("paths must be workspace-relative")
            }
        }
        if args.action == "fill" {
            guard let fills = args.fills,
                  let object = try? JSONSerialization.jsonObject(with: Data(fills.utf8)) as? [String: Any],
                  !object.isEmpty, object.count <= 100 else {
                throw FloeError.validationFailed("fill requires a non-empty JSON object of at most 100 fields")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let root = context.workspaceRootURL else {
            return Self.output("status=error error=No task workspace is available", exitStatus: 2)
        }
        do {
            try context.authorizeWorkspacePath(args.inputPath)
            let guarder = WorkspacePathGuard(rootURL: root, maxReadBytes: FileLimits.pdf)
            let sourceURL = try guarder.resolve(args.inputPath)
            try guarder.assertReadableSize(sourceURL)
            let data = try Data(floeContentsOf: sourceURL, options: [.mappedIfSafe])
            guard data.count <= FileLimits.pdf else {
                throw FloeError.validationFailed("PDF exceeds the 64 MB limit")
            }
            var input: [String: Any] = ["action": args.action, "pdf": data.base64EncodedString()]
            if args.action == "fill" {
                input["fills"] = try JSONSerialization.jsonObject(with: Data(args.fills!.utf8))
            }
            let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            let outcome = await service.run(
                ScriptExecutionRequest(script: Self.script, inputJSON: inputJSON, timeout: 30, maxOutputBytes: 64 * 1024),
                cancellation: context.cancellation
            )
            switch outcome {
            case .ok(let resultJSON, _, _, _, _, _):
                guard let resultJSON,
                      let result = try JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [String: Any] else {
                    return Self.output("status=error error=Form engine returned no result", exitStatus: 2)
                }
                if args.action == "list" {
                    let fields = result["fields"] as? [[String: Any]] ?? []
                    var lines = ["status=ok action=list fields=\(fields.count)"]
                    for field in fields {
                        lines.append("\(field["name"] ?? "")\t\(field["type"] ?? "")")
                    }
                    return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
                }
                guard let encoded = result["pdf"] as? String,
                      let filled = Data(base64Encoded: encoded) else {
                    let error = result["error"] as? String ?? "form fill produced no PDF"
                    return Self.output("status=error error=\(error)", exitStatus: 2)
                }
                let outputPath: String
                if let explicit = args.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
                    outputPath = explicit
                } else {
                    let base = (args.inputPath as NSString).deletingPathExtension
                    outputPath = base + "-filled.pdf"
                }
                try context.authorizeWorkspacePath(outputPath)
                let outputURL = try guarder.resolve(outputPath)
                try guarder.assertWritable(outputURL)
                let filledReceipt = try AtomicFileCommitter.commit(
                    filled,
                    to: outputURL,
                    policy: FileCommitPolicy(
                        conflict: .failIfExists,
                        maxBytes: FileLimits.pdf,
                        checkCancellation: { try context.cancellation.throwIfCancelled() }
                    )
                )
                let applied = (result["applied"] as? [String]) ?? []
                let skipped = (result["skipped"] as? [String]) ?? []
                return Self.output(
                    "status=ok action=fill output=\(outputPath) sha256=\(filledReceipt.sha256.prefix(16)) applied=\(applied.count) skipped=\(skipped.count)\(skipped.isEmpty ? "" : " skippedFields=" + skipped.joined(separator: ","))",
                    exitStatus: 0
                )
            case .jsException(let message, _):
                return Self.output("status=error error=\(message)", exitStatus: 2)
            case .timedOut:
                return Self.output("status=error error=Form engine timed out", exitStatus: 2)
            case .cancelled:
                throw FloeError.cancelled
            }
        } catch let error as FloeError {
            throw error
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    /// The fixed pdf-lib driver. Runs entirely in JavaScriptCore: manual
    /// base64 (no atob in JSC), pdf-lib UMD pre-injected as `PDFLib`, and a
    /// microtask-only async body that completes before evaluation returns.
    static let script = #"""
    function __b64dec(s){const c='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';const m=Object.create(null);for(let i=0;i<64;i++)m[c[i]]=i;const out=[];let acc=0,bits=0;for(const ch of s){if(ch==='=')break;const v=m[ch];if(v===undefined)continue;acc=(acc<<6)|v;bits+=6;if(bits>=8){bits-=8;out.push((acc>>bits)&255);}}return new Uint8Array(out);}
    function __b64enc(u){const c='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';let s='';for(let i=0;i<u.length;i+=3){const a=u[i],b=i+1<u.length?u[i+1]:null,d=i+2<u.length?u[i+2]:null;s+=c[a>>2]+c[((a&3)<<4)|(b===null?0:b>>4)]+(b===null?'=':c[((b&15)<<2)|(d===null?0:d>>6)])+(d===null?'=':c[d&63]);}return s;}
    (async()=>{
      try{
        const doc=await PDFLib.PDFDocument.load(__b64dec(input.pdf),{ignoreEncryption:true});
        let form;
        try{form=doc.getForm();}catch(e){printJSON({status:'ok',fields:[],note:'notAForm'});return;}
        if(input.action==='list'){
          const kinds=[['getTextField','text'],['getCheckBox','checkBox'],['getDropdown','dropdown'],['getRadioGroup','radioGroup'],['getOptionList','optionList'],['getButton','button']];
          const typed=form.getFields().map(f=>{
            const name=f.getName();
            let type='other';
            for(const k of kinds){try{form[k[0]](name);type=k[1];break;}catch(e){}}
            return {name:name,type:type};
          });
          printJSON({status:'ok',fields:typed});
          return;
        }
        const fills=input.fills||{};
        const applied=[],skipped=[];
        for(const name of Object.keys(fills)){
          const value=fills[name];
          try{
            if(applyFill(form,name,value)){applied.push(name);}
            else{skipped.push(name+':invalidValue');}
          }catch(e){
            const msg=String(e&&e.message||e);
            skipped.push(name+(msg.indexOf('No field')>=0||msg.indexOf('not found')>=0?':missing':':invalidValue'));
          }
        }
        const out=await doc.save();
        printJSON({status:'ok',applied:applied,skipped:skipped,pdf:__b64enc(out)});
      }catch(e){printJSON({status:'error',error:String(e&&e.message||e)});}
    })();
    function applyFill(form,name,value){
      try{form.getTextField(name).setText(String(value));return true;}catch(e){}
      try{if(value){form.getCheckBox(name).check();}else{form.getCheckBox(name).uncheck();}return true;}catch(e){}
      const optionSets=[
        ()=>form.getDropdown(name),
        ()=>form.getRadioGroup(name),
        ()=>form.getOptionList(name)
      ];
      for(const get of optionSets){
        try{
          const field=get();
          const options=field.getOptions();
          if(!options.includes(String(value))){return false;}
          field.select(String(value));
          return true;
        }catch(e){}
      }
      throw new Error('No field named '+name);
    }
    """#

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
