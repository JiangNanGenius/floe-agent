// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

public enum BiologyToolSchemas {
    public static let readOnlyNames:Set<String>=["biology.read","biology.methods","biology.projects","biology.status","biology.history","biology.deleted","biology.file.read","biology.describe"]
    private static func string(_ description:String="",values:[String]? = nil)->JSONValue {
        var value:[String:JSONValue]=["type":.string("string")]
        if !description.isEmpty {value["description"] = .string(description)}
        if let values {value["enum"] = .array(values.map(JSONValue.string))}
        return .object(value)
    }
    private static func integer(_ minimum:Int=0,_ maximum:Int=Int.max)->JSONValue {.object(["type":.string("integer"),"minimum":.number(Double(minimum)),"maximum":.number(Double(maximum))])}
    public static func schema(_ name:String)->JSONValue? {
        var fields:[String:JSONValue]=["projectID":string("Host-authorized project UUID.")]
        var required=["projectID"]
        let freeObject=JSONValue.object(["type":.string("object"),"additionalProperties":.bool(true)])
        switch name {
        case "biology.describe":fields=["operation":string()];required=[]
        case "biology.projects","biology.deleted":fields=[:];required=[]
        case "biology.importProject":fields=["base64":string("Actual saved project JSON bytes. Choose this or fileID + sourceProjectID. Historic run owners and authority receipts are discarded."),"fileID":string("Opaque authorized saved-project file UUID; never a path."),"sourceProjectID":string("Authorized project that owns the source file handle.")];required=[]
        case "biology.read":
            fields.merge(["assetID":string(),"runID":string(),"view":string(values:["summary","data","sequence","annotations","atoms","pixels","matrix","network","result","text","selection"]),"offset":integer(0,10_000_000),"limit":integer(1,20000),"record":integer(0,255),"channel":integer(0,31),"slice":integer(0,511),"frame":integer(0,511),"columnOffset":integer(0,100000),"columnLimit":integer(1,128),"region":.object(["type":.string("array"),"items":integer(0,100_000_000),"minItems":.number(4),"maxItems":.number(4)])]){_,new in new}
        case "biology.methods":fields["assetID"]=string()
        case "biology.import":fields.merge(["title":string(),"format":string(),"base64":string("Use exactly one of base64 or an authorized fileID."),"fileID":string("Opaque file UUID from the host's file service; never a path.")]){_,new in new};required += ["title","format"]
        case "biology.analyze":
            fields.merge(["assetID":string(),"expectedRevision":integer(1),"method":string("Exact usable method from biology.methods."),"environmentID":string("Configured, resolved environment identity, not a label granting execution."),"options":freeObject]){_,new in new}
            required += ["assetID","expectedRevision","method"]
        case "biology.job":fields.merge(["runID":string(),"action":string(values:["status","wait","cancel"])]){_,new in new};required += ["runID"]
        case "biology.status","biology.stop":fields["runID"]=string();required += ["runID"]
        case "biology.derive":fields["runID"]=string();fields["expectedRevision"]=integer(1);required += ["runID","expectedRevision"]
        case "biology.update":
            fields["assetID"]=string();fields["expectedRevision"]=integer(1)
            fields["operation"]=string(values:["project.rename","project.notes","project.linkChemistry","asset.rename","asset.delete","asset.replace","annotation.upsert","annotation.remove","image.calibrate","matrix.filter","network.replace","structure.transform"])
            fields["parameters"]=freeObject;required += ["operation","expectedRevision","parameters"]
        case "biology.select":fields["assetID"]=string();fields["expectedRevision"]=integer(1);fields["selection"]=freeObject;required += ["assetID","expectedRevision","selection"]
        case "biology.history":fields["offset"]=integer();fields["limit"]=integer(1,100)
        case "biology.restore":fields["revision"]=integer(1);fields["expectedRevision"]=integer(1);required += ["revision","expectedRevision"]
        case "biology.deleteProject":fields["expectedRevision"]=integer(1);required += ["expectedRevision"]
        case "biology.restoreDeleted":fields["trashID"]=string();required += ["trashID"]
        case "biology.export":
            fields["assetID"]=string();fields["runID"]=string();fields["format"]=string("original, supported dataset format, or csv/text/json for results.")
            fields["destination"]=string(values:["inline","file"])
        case "biology.file.read":
            fields["fileID"]=string();fields["offset"]=integer(0);fields["length"]=integer(1,196608);required += ["fileID","offset","length"]
        default:return nil
        }
        for key in ["projectID","assetID","runID","fileID","sourceProjectID"] where fields[key] != nil {var value=fields[key]!.object!;value["format"] = .string("uuid");fields[key] = .object(value)}
        var result:[String:JSONValue]=["type":.string("object"),"properties":.object(fields),"required":.array(required.map(JSONValue.string)),"additionalProperties":.bool(false)]
        if name=="biology.importProject" {result["oneOf"] = .array([["base64"],["fileID","sourceProjectID"]].map{.object(["type":.string("object"),"required":.array($0.map(JSONValue.string))])})}
        return .object(result)
    }
    public static func validate(_ value:JSONValue,against schema:JSONValue) throws {
        try validateValue(value,schema:schema,path:"arguments",depth:0)
    }
    private static func validateValue(_ value:JSONValue,schema:JSONValue,path:String,depth:Int) throws {
        guard depth<32 else {throw BiologyError.invalid("Arguments exceed the nesting budget.")}
        if let choices=schema["enum"]?.array,!choices.contains(value) {throw BiologyError.invalid("Unsupported value: "+path)}
        if let variants=schema["oneOf"]?.array {
            let matches=variants.filter{(try? validateValue(value,schema:$0,path:path,depth:depth+1)) != nil}
            guard matches.count==1 else {throw BiologyError.invalid("Choose exactly one supported form: "+path)}
        }
        switch schema["type"]?.string {
        case "object":
            guard let object=value.object,object.count<=256 else {throw BiologyError.invalid("Expected bounded object: "+path)}
            let fields=schema["properties"]?.object ?? [:]
            if schema["additionalProperties"]?.bool==false,!Set(object.keys).isSubset(of:Set(fields.keys)) {throw BiologyError.invalid("Unknown field: "+path)}
            for item in schema["required"]?.array ?? [] {if let key=item.string,object[key]==nil {throw BiologyError.invalid("Missing "+path+"."+key)}}
            for (key,raw) in object {if let field=fields[key] {try validateValue(raw,schema:field,path:path+"."+key,depth:depth+1)}}
        case "array":
            guard let array=value.array,array.count>=Int(schema["minItems"]?.number ?? 0),array.count<=Int(schema["maxItems"]?.number ?? 100000) else {throw BiologyError.invalid("Invalid array length: "+path)}
            if let items=schema["items"] {for raw in array {try validateValue(raw,schema:items,path:path+"[]",depth:depth+1)}}
        case "string":
            guard let text=value.string,text.utf8.count<=2*1024*1024 else {throw BiologyError.invalid("Expected bounded string: "+path)}
            if schema["format"]?.string=="uuid",UUID(uuidString:text)==nil {throw BiologyError.invalid("Expected UUID: "+path)}
        case "boolean":guard value.bool != nil else {throw BiologyError.invalid("Expected boolean: "+path)}
        case "number","integer":
            guard let n=value.number,n.isFinite,n>=(schema["minimum"]?.number ?? -Double.greatestFiniteMagnitude),n<=(schema["maximum"]?.number ?? Double.greatestFiniteMagnitude),schema["type"]?.string != "integer" || n.rounded()==n else {throw BiologyError.invalid("Invalid numeric value: "+path)}
        case nil:break
        default:throw BiologyError.invalid("Unsupported schema type: "+path)
        }
    }
}

public enum BiologyMethodCatalog {
    public static func describe(_ method:String)->JSONValue {
        .object(["method":.string(method),"options":schema(method),"coordinateConvention":.string("Sequence ranges and image regions use zero-based half-open coordinates; structure coordinates use Å.")])
    }
    public static func schema(_ method:String)->JSONValue {
        func number(_ lo:Double,_ hi:Double)->JSONValue {.object(["type":.string("number"),"minimum":.number(lo),"maximum":.number(hi)])}
        func integer(_ lo:Int,_ hi:Int)->JSONValue {.object(["type":.string("integer"),"minimum":.number(Double(lo)),"maximum":.number(Double(hi))])}
        func choice(_ values:[String])->JSONValue {.object(["type":.string("string"),"enum":.array(values.map(JSONValue.string))])}
        func array(_ item:JSONValue,_ count:Int=100000)->JSONValue {.object(["type":.string("array"),"items":item,"minItems":.number(1),"maxItems":.number(Double(count))])}
        let string=JSONValue.object(["type":.string("string")])
        var f:[String:JSONValue]=[:],required:[String]=[]
        let score:[String:JSONValue]=["match":number(-100,100),"mismatch":number(-100,100),"gapOpen":number(-100,0),"gapExtend":number(-100,0)]
        if method.hasPrefix("sequence.") || method.hasPrefix("seq.") {
            if !["seq.parse","seq.export","seq.phylogeny"].contains(method) {f["record"]=integer(0,255)}
            if method.hasSuffix("translate") {f["frame"] = .object(["type":.string("integer"),"enum":.array([-3,-2,-1,1,2,3].map{.number(Double($0))})]);f["code"]=integer(1,method.hasPrefix("sequence.") ? 2:33)}
            if method.contains(".align.") {f["query"]=integer(0,255);if method.hasPrefix("seq."){f.merge(score){_,n in n}}}
            if method=="seq.phylogeny" {f=score}
            if method=="seq.export" {f=["format":choice(["fasta","fastq","genbank"]),"source":choice(["current","original"])]}
        } else if method.hasPrefix("structure.") || method.hasPrefix("struct.") {
            let mature=method.hasPrefix("struct.")
            f=["model":integer(mature ? 0:1,100000),"chain":string]
            if mature {f["kind"]=choice(["all","polymer","water"]);f["atomNames"]=array(string,100)}
            if method.hasSuffix("contacts") {f["cutoff"]=number(0.1,20)}
            if method=="structure.distance" {f["atomA"]=integer(0,99999);f["atomB"]=integer(0,99999)}
            if method=="struct.rmsd" {f["reference"]=string;f["referenceFormat"]=choice(["pdb","cif","mmcif"]);f["referenceModel"]=integer(0,100000)}
        } else if method.hasPrefix("image.") || method.hasPrefix("micro.") {
            if method != "micro.series" {f=["channel":integer(0,31),"slice":integer(0,511),"frame":integer(0,511)]}
            if method.hasPrefix("micro."),method != "micro.import",method != "micro.series" {f["series"]=integer(0,1024);f["level"]=integer(0,64);f["region"] = .object(["type":.string("array"),"items":integer(0,100000000),"minItems":.number(4),"maxItems":.number(4)])}
            if method=="image.segment" || ["micro.segment","micro.overlay"].contains(method) {
                f["threshold"]=number(-1e15,1e15);f["minArea"]=integer(1,4194304)
                f["connectivity"] = .object(["type":.string("integer"),"enum":.array((method.hasPrefix("image.") ? [4,8]:[1,2]).map{.number(Double($0))})])
                if method.hasPrefix("micro.") {f["radius"]=integer(0,16)}
            }
        } else if method.hasPrefix("matrix.") || method.hasPrefix("omics.") {
            if ["matrix.normalize","omics.normalize","omics.pca","omics.cluster","omics.embedding"].contains(method) {f["targetSum"]=number(1,1e9)}
            if ["omics.pca","omics.cluster","omics.embedding"].contains(method) {f["nComps"]=integer(1,100)}
            if ["omics.cluster","omics.embedding"].contains(method) {f["nNeighbors"]=integer(2,10000)}
            if method=="omics.cluster" {f["resolution"]=number(0.01,10)}
            if method=="omics.diffexp" {f["groupA"]=array(string);f["groupB"]=array(string);required=["groupA","groupB"]}
            if method=="omics.export" {f["format"]=choice(["csv","tsv"])}
        } else if method=="network.simulate" || method=="network.sweep" || method=="net.simulate" || method=="net.sweep" || method=="net.sbml.simulate" || method=="net.sbml.sweep" {
            f["timeEnd"]=number(1e-9,1e6)
            if method.hasPrefix("network.") {f["step"]=number(1e-9,1e6)}else {f["points"]=integer(2,10001);f["solver"]=choice(method.contains("sbml") ? ["cvode"]:["DOP853","RK45","LSODA","BDF","Radau"])}
            if method.hasSuffix("sweep") {f["values"]=array(number(0,1e12),32);required=["values"];if method.contains("sbml") {f["parameter"]=string;required.append("parameter")}else{f["reaction"]=integer(0,511)}}
        } else if method.hasPrefix("volume.") {
            if method=="volume.slice" {f=["axis":integer(0,2),"index":integer(0,16383)]}
            if method=="volume.isosurface" {f=["isovalue":number(-1e15,1e15),"stride":integer(1,32)];required=["isovalue"]}
        }
        return .object(["type":.string("object"),"properties":.object(f),"required":.array(required.map(JSONValue.string)),"additionalProperties":.bool(false)])
    }
    public static func validate(_ options:JSONValue,method:String) throws {try BiologyToolSchemas.validate(options,against:schema(method))}
}
