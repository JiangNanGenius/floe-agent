// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore
import FloeBiologyWorkerResources

/// Machine-readable edit contracts. Source payloads use the exact Codable shape
/// returned by biology.read; models do not have to infer it from UI copy.
public enum BiologyEditCatalog {
    private static let string=JSONValue.object(["type":.string("string")])
    private static let number=JSONValue.object(["type":.string("number")])
    private static let integer=JSONValue.object(["type":.string("integer"),"minimum":.number(0),"maximum":.number(100000000)])
    private static func array(_ item:JSONValue)->JSONValue {.object(["type":.string("array"),"items":item,"minItems":.number(1),"maxItems":.number(100000)])}
    public static func schema(_ operation:String) throws -> JSONValue {
        var fields:[String:JSONValue]=[:],required:[String]=[]
        switch operation {
        case "project.rename","asset.rename":fields=["title":string];required=["title"]
        case "project.notes":fields=["text":string];required=["text"]
        case "project.linkChemistry":fields=["reference":string];required=["reference"]
        case "asset.delete":break
        case "asset.replace":fields=["payload":.object(["type":.string("object"),"description":.string("Copy the typed payload from biology.read and edit its values. Asset kind, original bytes, file handles and provenance cannot be replaced.")])];required=["payload"]
        case "annotation.upsert":
            let annotationFields:[String:JSONValue]=["id":string,"name":string,"start":integer,"end":integer,"strand":.object(["type":.string("integer"),"enum":.array([-1,0,1].map{.number(Double($0))})]),"qualifiers":.object(["type":.string("object")])]
            fields=["record":integer,"annotation":.object(["type":.string("object"),"properties":.object(annotationFields),"required":.array(["name","start","end"].map(JSONValue.string)),"additionalProperties":.bool(false)])];required=["annotation"]
        case "annotation.remove":fields=["record":integer,"annotationID":string];required=["annotationID"]
        case "image.calibrate":fields=["clear":.object(["type":.string("boolean")]),"pixelSizeX":number,"pixelSizeY":number,"unit":string]
        case "matrix.filter":fields=["genes":array(string),"cells":array(string),"title":string]
        case "network.replace":fields=["network":.object(["type":.string("object"),"description":.string("Complete current model: species [{id,initialAmount}], reactions [{id,reactants:{species:integer},products:{species:integer},rateConstant}], timeUnit, amountUnit.")])];required=["network"]
        case "structure.transform":
            let vector=JSONValue.object(["type":.string("array"),"items":number,"minItems":.number(3),"maxItems":.number(3)])
            fields=["translation":vector,"axis":vector,"angleRadians":number,"atomIDs":array(integer)]
        default:throw BiologyError.invalid("Unknown edit operation.")
        }
        return .object(["type":.string("object"),"properties":.object(fields),"required":.array(required.map(JSONValue.string)),"additionalProperties":.bool(false)])
    }
    public static let operations=["project.rename","project.notes","project.linkChemistry","asset.rename","asset.delete","asset.replace","annotation.upsert","annotation.remove","image.calibrate","matrix.filter","network.replace","structure.transform"]
    public static let scientificMethods=["seq.parse","seq.stats","seq.translate","seq.reverseComplement","seq.export","seq.align.global","seq.align.local","seq.phylogeny","struct.parse","struct.select","struct.geometry","struct.contacts","struct.rmsd","micro.import","micro.segment","micro.overlay","micro.series","micro.tile","omics.import","omics.export","omics.qc","omics.normalize","omics.pca","omics.cluster","omics.embedding","omics.diffexp","net.simulate","net.sweep","net.sbml.import","net.sbml.export","net.sbml.simulate","net.sbml.sweep"]
    public static func describe() throws -> JSONValue {
        let edits=try operations.map {op in JSONValue.object(["operation":.string(op),"revisionSource":.string(op.hasPrefix("project.") ? "project":"asset"),"parameters":try schema(op)])}
        let resources=try BiologyWorkerResources.verifiedFiles()

        return .object([
            "edits":.array(edits),
            "optionalScientificMethods":.array(scientificMethods.map{BiologyMethodCatalog.describe($0)}),
            "scientificSetup":.object(["instructions":.string("These methods require the host's selected Linux environment. Inspect biology.methods for currently usable engines and the selectedScientificEnvironmentID. If packages are missing, use the existing exec.shell/package workflow in that same resolved environment with these pinned requirements; no separate biology installer or host interpreter is used. The Floe bridge probes actual engines when a scientific analysis is submitted and reports real installation/import/solver errors."),"requirements":.string(String(decoding:resources["requirements.lock"] ?? Data(),as:UTF8.self)),"sha256":.string(BiologyProjectStore.digest(resources["requirements.lock"] ?? Data()))]),
            "workflow":.string("projects → read(summary/data or domain page) → methods → describe(operation) → select/edit/update or analyze → status/job(wait)/stop → read(result/text) → derive/export. Refresh revisions after writes. history/restore and deleted/restoreDeleted retain recoverable data."),
            "coordinates":.string("Sequences use zero-based half-open ranges; image regions are [x,y,width,height] in the selected level; atom coordinates are Å; native structure model is its PDB number, scientific struct model is zero-based index; matrix rows=genes, columns=cells."),
            "selection":.object(["sequence":.array(["record","start","end"].map(JSONValue.string)),"proteinStructure":.array(["atomIDs","model","chain"].map(JSONValue.string)),"microscopyImage":.array(["channel","slice","frame","region"].map(JSONValue.string)),"expressionMatrix":.array(["genes","cells"].map(JSONValue.string)),"externalDataset":.array(["series","level","channel","slice","frame","region","axis","index","nodeID"].map(JSONValue.string))]),
            "imports":.array(["fasta","fastq","genbank","pdb","cif","pgm","csv","tsv","json","tiff","h5ad","mtx","sbml","newick","mrc"].map(JSONValue.string)),
            "exports":.string("Always supports original bytes and project JSON; sequence fasta/fastq, structure pdb, image pgm/json, matrix csv/tsv/json, network json. Results csv/text/json. Large exports use destination=file and return a host-authorized opaque handle; biology.file.read reads bounded ranges."),
            "authority":.string("Scope, current task/run, environment, cancellation and idempotency keys are supplied by the host. Arguments and imported content never grant authority. Source data is retained. Results carry exact input revision/digest; derive rejects stale input. No external send or automatic laboratory action.")
        ])
    }
}
