// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

public extension BiologyService {
    func importProjectFile(_ sourceProjectID:UUID,fileID:UUID,owner:BiologyExecutionOwner,identity:BiologyMutationIdentity?=nil) async throws -> BiologyProject {
        try await permit(.read,sourceProjectID)
        _=try await store.load(sourceProjectID)
        guard let fileAccess else {throw BiologyError.unavailable("The host file service is unavailable.")}
        let context=BiologyFileContext(projectID:sourceProjectID,owner:owner),reference=try await fileAccess.resolve(fileID,context:context)
        guard reference.projectID==sourceProjectID,reference.byteCount>0,reference.byteCount<=BiologyProjectStore.maximumProjectBytes else {throw BiologyError.invalid("The authorized project file exceeds its import limit.")}
        var data=Data(),offset:UInt64=0
        while offset<reference.byteCount {
            try Task.checkCancellation()
            let count=Int(min(reference.byteCount-offset,1_048_576)),chunk=try await fileAccess.read(reference,offset:offset,length:count,context:context)
            guard chunk.count==count else {throw BiologyError.corrupt("Project file was truncated.")};data+=chunk;offset+=UInt64(count)
        }
        guard BiologyProjectStore.digest(data)==reference.sha256 else {throw BiologyError.corrupt("Project file digest changed.")}
        return try await importProject(data,identity:identity)
    }
    /// Trusted native UI only; model tools continue to receive opaque file IDs.
    func nativeOriginalExport(_ id:UUID,assetID:UUID,owner:BiologyExecutionOwner?=nil) async throws -> BiologyNativeFileExport {
        try await permit(.export,id)
        let project=try await store.load(id)
        guard let asset=project.assets.first(where:{$0.id==assetID}),let reference=asset.fileReference,let fileAccess else {throw BiologyError.unavailable("No authorized file-backed original is available.")}
        return try await fileAccess.prepareNativeExport(reference,context:.init(projectID:id,owner:owner))
    }
    func finishNativeExport(_ export:BiologyNativeFileExport) async {await fileAccess?.finishNativeExport(export)}
    /// Native file-picker/service entry, deliberately absent from model JSON.
    func importURL(_ id:UUID,trustedSourceURL:URL,owner:BiologyExecutionOwner?=nil) async throws -> BiologyAsset {
        try await permit(.edit,id)
        guard let fileAccess else {throw BiologyError.unavailable("Connect the host file service to import larger datasets.")}
        let ref=try await fileAccess.register(trustedSourceURL:trustedSourceURL,fileName:trustedSourceURL.lastPathComponent,context:.init(projectID:id,owner:owner))
        return try await importFile(id,fileID:ref.id,title:trustedSourceURL.deletingPathExtension().lastPathComponent,format:trustedSourceURL.pathExtension,owner:owner)
    }
    func importFile(_ id:UUID,fileID:UUID,title:String,format:String,owner:BiologyExecutionOwner?,identity:BiologyMutationIdentity? = nil) async throws -> BiologyAsset {
        try await permit(.edit,id)
        guard let fileAccess else {throw BiologyError.unavailable("This host has not connected its authorized file service.")}
        let reference=try await fileAccess.resolve(fileID,context:.init(projectID:id,owner:owner))
        try reference.validate()
        guard reference.projectID==id else {throw BiologyError.invalid("File is outside this project.")}
        if reference.byteCount<=BiologyImporter.maximumInputBytes {
            var data=Data();var offset:UInt64=0
            while offset<reference.byteCount {
                let length=Int(min(reference.byteCount-offset,1_048_576))
                data+=try await fileAccess.read(reference,offset:offset,length:length,context:.init(projectID:id,owner:owner));offset+=UInt64(length)
            }
            guard BiologyProjectStore.digest(data)==reference.sha256 else {throw BiologyError.corrupt("Input file digest changed.")}
            return try await importAsset(id,title:title,format:format,data:data,provenance:["fileID":fileID.uuidString,"sha256":reference.sha256],identity:identity)
        }
        guard ["tif","tiff","h5ad","mtx","sbml","xml","mrc","map","ccp4"].contains(format.lowercased()) else {throw BiologyError.unavailable("This format does not have a file-backed reader.")}
        let asset=BiologyAsset(title:title,payload:.externalDataset(format.lowercased()),originalData:Data(),originalFormat:format.lowercased(),fileReference:reference)
        let result=try await store.transact(id,identity:identity){p in p.assets.append(asset);return asset}
        changed(id);return result
    }
    func exportFile(_ id:UUID,assetID:UUID?,runID:UUID? = nil,format:String,owner:BiologyExecutionOwner?,identity:BiologyMutationIdentity?=nil) async throws -> BiologyExportReceipt {
        try await permit(.export,id)
        guard let identity else {return try await makeExportFile(id,assetID:assetID,runID:runID,format:format,owner:owner)}
        if let bytes=try await store.receipt(id,identity:identity) {
            let saved=try JSONDecoder().decode(BiologyExportReceipt.self,from:bytes)
            guard let fileAccess else {throw BiologyError.unavailable("The host file service is unavailable.")}
            let current=try await fileAccess.resolve(saved.fileID,context:.init(projectID:id,owner:owner))
            guard current.sha256==saved.sha256,current.byteCount==saved.byteCount else {throw BiologyError.corrupt("Previously exported bytes changed.")};return saved
        }
        let key=identity.owner.taskID.uuidString+":"+identity.owner.hostRunID.uuidString+":"+identity.requestID
        if let existing=exportWorkers[key] {
            guard existing.identity==identity else {throw BiologyError.invalid("Export call identity was reused with different arguments.")}
            return try await withTaskCancellationHandler{try await existing.task.value}onCancel:{existing.task.cancel()}
        }
        let task=Task{[self] in
            let receipt=try await makeExportFile(id,assetID:assetID,runID:runID,format:format,owner:owner)
            try await permit(.export,id)
            let saved=try await store.transact(id,identity:identity){_ in receipt};changed(id);return saved
        }
        exportWorkers[key]=(identity,task);defer{exportWorkers.removeValue(forKey:key)}
        return try await withTaskCancellationHandler{try await task.value}onCancel:{task.cancel()}
    }
    private func makeExportFile(_ id:UUID,assetID:UUID?,runID:UUID?,format:String,owner:BiologyExecutionOwner?) async throws -> BiologyExportReceipt {
        try await permit(.export,id)
        guard assetID==nil || runID==nil else {throw BiologyError.invalid("Choose a dataset or a result.")}
        guard let fileAccess else {throw BiologyError.unavailable("This host has not connected its authorized file export service.")}
        let p=try await store.load(id),context=BiologyFileContext(projectID:id,owner:owner)
        if let assetID {
            guard let a=p.assets.first(where:{$0.id==assetID}) else {throw BiologyError.invalid("Dataset no longer exists.")}
            if format=="original",let reference=a.fileReference {return try await fileAccess.export(reference,fileName:reference.fileName,context:context)}
            return try await fileAccess.export(BiologyExport.asset(a,format:format),fileName:a.title+"."+(format=="original" ? a.originalFormat:format),context:context)
        }
        if let runID {
            guard let run=p.runs.first(where:{$0.id==runID}),let result=run.result else {throw BiologyError.invalid("No saved result is available.")}
            let data:Data
            switch format {case "csv":data=Data(result.csv().utf8);case "text":data=Data(result.text.utf8);case "json":data=try BiologyCoding.encode(result);default:throw BiologyError.invalid("Choose csv, text or json result export.")}
            return try await fileAccess.export(data,fileName:"Biology-result."+format,context:context)
        }
        return try await fileAccess.export(BiologyCoding.encode(p),fileName:p.title+".biology.json",context:context)
    }
    /// All structured edits validate and commit with the replay receipt in the
    /// same storage transaction. Scientific originals remain immutable.
    func update(_ id:UUID,operation:String,assetID:UUID?,expectedRevision:UInt64,parameters:JSONValue,identity:BiologyMutationIdentity? = nil) async throws -> JSONValue {
        try await permit(operation=="asset.delete" ? .delete:.edit,id)
        try BiologyToolSchemas.validate(parameters,against:BiologyEditCatalog.schema(operation))
        let result:JSONValue=try await store.transact(id,identity:identity){p in
            func string(_ key:String) throws -> String {guard let s=parameters[key]?.string,!s.isEmpty else {throw BiologyError.invalid("Missing "+key)};return s}
            if operation=="project.rename" || operation=="project.notes" || operation=="project.linkChemistry" {
                guard p.revision==expectedRevision else {throw BiologyError.conflict(expected:expectedRevision,actual:p.revision)}
                if operation=="project.rename" {p.title=try string("title")}
                else if operation=="project.notes" {guard let notes=parameters["text"]?.string else {throw BiologyError.invalid("Notes text is required.")};p.notes=notes}
                else {let reference=try string("reference");guard reference.hasPrefix("floe-chemistry:"),reference.utf8.count<=4096 else {throw BiologyError.invalid("Choose an explicit chemistry reference.")};if !p.chemistryLinks.contains(reference){p.chemistryLinks.append(reference)}}
                return .object(["projectID":.string(p.id.uuidString),"revision":.number(Double(p.revision+1))])
            }
            if operation=="asset.create" {
                guard p.revision==expectedRevision else {throw BiologyError.conflict(expected:expectedRevision,actual:p.revision)}
                let title=try string("title")
                guard title.utf8.count<=4096 else {throw BiologyError.invalid("Invalid dataset title.")}
                guard let kind=parameters["kind"]?.string else {throw BiologyError.invalid("Choose the new dataset kind.")}
                let payload:BiologyAssetPayload,original:Data,format:String
                if kind=="sequence" {
                    let recordName=parameters["recordName"]?.string ?? title
                    guard !recordName.isEmpty,recordName.utf8.count<=4096 else {throw BiologyError.invalid("Invalid record name.")}
                    // A blank board stays an uncommitted editing draft until the
                    // caller supplies real symbols; no implicit sequence is ever
                    // invented here.
                    guard let rawSequence=parameters["sequence"]?.string,!rawSequence.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw BiologyError.invalid("Enter a sequence to create a sequence dataset.")}
                    var records=try BiologyImporter.sequences(">"+recordName+"\n"+rawSequence+"\n",format:"fasta")
                    if let raw=parameters["annotation"] {
                        var fields=raw.object ?? [:]
                        if fields["id"]==nil {fields["id"] = .string(UUID().uuidString)}
                        if fields["strand"]==nil {fields["strand"] = .number(1)}
                        if fields["qualifiers"]==nil {fields["qualifiers"] = .object([:])}
                        let annotation=try JSONDecoder().decode(SequenceAnnotation.self,from:BiologyCoding.encode(JSONValue.object(fields)))
                        guard annotation.start>=0,annotation.end>annotation.start,annotation.end<=records[0].sequence.count else {throw BiologyError.invalid("Annotation range is outside the new sequence.")}
                        records[0].annotations.append(annotation)
                    }
                    payload = .sequence(records);original=Data(BiologyImporter.fasta(records).utf8);format="fasta"
                } else if kind=="biochemicalNetwork" {
                    let network:BiochemicalNetwork
                    if let raw=parameters["network"] {network=try JSONDecoder().decode(BiochemicalNetwork.self,from:BiologyCoding.encode(raw));try network.validate()}
                    else {network=BiochemicalNetwork(species:[.init(id:"S1",initialAmount:0)],reactions:[])}
                    payload = .biochemicalNetwork(network);original=try BiologyCoding.encode(network);format="network.json"
                } else {throw BiologyError.invalid("Unsupported dataset kind.")}
                var asset=BiologyAsset(title:title,payload:payload,originalData:original,originalFormat:format)
                asset.provenance=["origin":"native.blank.create"]
                p.assets.append(asset);p.activeAssetID=asset.id
                return .object(["assetID":.string(asset.id.uuidString),"revision":.number(1)])
            }
            guard let assetID,let i=p.assets.firstIndex(where:{$0.id==assetID}) else {throw BiologyError.invalid("Choose an existing dataset.")}
            guard p.assets[i].revision==expectedRevision,expectedRevision<UInt64.max else {throw BiologyError.conflict(expected:expectedRevision,actual:p.assets[i].revision)}
            if operation=="asset.delete" {
                guard !p.runs.contains(where:{$0.assetID==assetID && $0.isActive}) else {throw BiologyError.invalid("Stop this dataset's calculations before deleting it.")}
                p.assets.remove(at:i);p.selections?.removeValue(forKey:assetID.uuidString)
                if p.activeAssetID==assetID {p.activeAssetID=p.assets.first?.id}
                return .object(["deletedAssetID":.string(assetID.uuidString)])
            }
            if operation=="asset.rename" {p.assets[i].title=try string("title")}
            else if operation=="asset.replace" {
                guard let raw=parameters["payload"] else {throw BiologyError.invalid("A typed payload is required.")}
                let payload=try JSONDecoder().decode(BiologyAssetPayload.self,from:BiologyCoding.encode(raw))
                guard payload.kind==p.assets[i].kind else {throw BiologyError.invalid("A dataset edit cannot change its kind.")};p.assets[i].payload=payload;p.selections?.removeValue(forKey:assetID.uuidString)
            } else if operation.hasPrefix("annotation.") {
                guard case .sequence(var records)=p.assets[i].payload else {throw BiologyError.invalid("Choose a sequence dataset.")}
                let index=try Self.optionInteger(parameters,"record",default:0,range:0...255)
                guard records.indices.contains(index) else {throw BiologyError.invalid("Sequence record is missing.")}
                if operation=="annotation.upsert" {
                    guard let value=parameters["annotation"] else {throw BiologyError.invalid("Annotation is required.")}
                    var raw=value.object ?? [:]
                    if raw["id"]==nil {raw["id"] = .string(UUID().uuidString)}
                    if raw["strand"]==nil {raw["strand"] = .number(1)}
                    if raw["qualifiers"]==nil {raw["qualifiers"] = .object([:])}
                    let annotation=try JSONDecoder().decode(SequenceAnnotation.self,from:BiologyCoding.encode(JSONValue.object(raw)))
                    if let j=records[index].annotations.firstIndex(where:{$0.id==annotation.id}) {records[index].annotations[j]=annotation}else{records[index].annotations.append(annotation)}
                } else if operation=="annotation.remove" {
                    let raw=try string("annotationID");guard let j=records[index].annotations.firstIndex(where:{$0.id.uuidString.lowercased()==raw.lowercased()}) else {throw BiologyError.invalid("Annotation is missing.")};records[index].annotations.remove(at:j)
                }else {throw BiologyError.invalid("Unknown annotation operation.")}
                p.assets[i].payload = .sequence(records)
            } else if operation=="image.calibrate" {
                guard case .microscopyImage(var image)=p.assets[i].payload else {throw BiologyError.invalid("Choose a native image.")}
                if parameters["clear"]?.bool==true {image.pixelSizeX=nil;image.pixelSizeY=nil}
                else {guard let x=parameters["pixelSizeX"]?.number,let y=parameters["pixelSizeY"]?.number else {throw BiologyError.invalid("Both pixel sizes are required.")};image.pixelSizeX=x;image.pixelSizeY=y;image.calibrationUnit=try string("unit")}
                try image.validate();p.assets[i].payload = .microscopyImage(image)
            } else if operation=="network.replace" {
                guard case .biochemicalNetwork=p.assets[i].payload,let raw=parameters["network"] else {throw BiologyError.invalid("Choose a network and its complete typed model.")}
                let network=try JSONDecoder().decode(BiochemicalNetwork.self,from:BiologyCoding.encode(raw));try network.validate();p.assets[i].payload = .biochemicalNetwork(network)
            } else if operation=="matrix.filter" {
                guard case .expressionMatrix(let matrix)=p.assets[i].payload else {throw BiologyError.invalid("Choose an expression matrix.")}
                let genes=try Self.identifiers(parameters["genes"],fallback:matrix.geneIDs),cells=try Self.identifiers(parameters["cells"],fallback:matrix.cellIDs)
                let gi=Dictionary(uniqueKeysWithValues:matrix.geneIDs.enumerated().map{($0.element,$0.offset)}),ci=Dictionary(uniqueKeysWithValues:matrix.cellIDs.enumerated().map{($0.element,$0.offset)})
                guard genes.allSatisfy({gi[$0] != nil}),cells.allSatisfy({ci[$0] != nil}) else {throw BiologyError.invalid("A requested gene or cell is missing.")}
                let filtered=ExpressionMatrix(geneIDs:genes,cellIDs:cells,values:genes.flatMap{g in cells.map{c in matrix.values[gi[g]!*matrix.cellIDs.count+ci[c]!]}})
                try filtered.validate()
                var derived=BiologyAsset(title:parameters["title"]?.string ?? p.assets[i].title+" filtered",payload:.expressionMatrix(filtered),originalData:try BiologyCoding.encode(BiologyAssetPayload.expressionMatrix(filtered)),originalFormat:"json")
                derived.provenance=["sourceAsset":assetID.uuidString,"sourceRevision":String(expectedRevision),"operation":"matrix.filter"]
                p.assets.append(derived)
                return .object(["assetID":.string(derived.id.uuidString),"revision":.number(1)])
            } else if operation=="structure.transform" {
                guard case .proteinStructure(var structure)=p.assets[i].payload else {throw BiologyError.invalid("Choose a structure.")}
                func vector(_ key:String,default value:[Double]) throws -> [Double] {
                    guard let raw=parameters[key] else {return value}
                    guard let array=raw.array,array.count==3,array.allSatisfy({$0.number?.isFinite==true}) else {throw BiologyError.invalid("Invalid "+key)};return array.map{$0.number!}
                }
                let translation=try vector("translation",default:[0,0,0]),axis=try vector("axis",default:[0,0,1]),angle=parameters["angleRadians"]?.number ?? 0
                let norm=sqrt(axis.reduce(0){$0+$1*$1})
                guard angle.isFinite,norm.isFinite,norm>1e-12,translation.allSatisfy({abs($0)<=1e7}) else {throw BiologyError.invalid("Invalid rigid transform.")}
                let u=axis.map{$0/norm},c=cos(angle),s=sin(angle)
                let selected=parameters["atomIDs"]?.array?.map{$0.number ?? .nan}
                guard selected==nil || selected!.allSatisfy({$0.isFinite && $0.rounded()==$0 && $0>=0 && $0<=100_000}) else {throw BiologyError.invalid("Invalid atom identifiers.")}
                let ids=selected.map{Set($0.map(Int.init))}
                if let ids {guard !ids.isEmpty,ids.isSubset(of:Set(structure.atoms.map(\.id))) else {throw BiologyError.invalid("An atom is missing.")}}
                for j in structure.atoms.indices where ids==nil || ids!.contains(structure.atoms[j].id) {
                    let v=[structure.atoms[j].x,structure.atoms[j].y,structure.atoms[j].z],dot=zip(u,v).reduce(0){$0+$1.0*$1.1}
                    let cross=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
                    let moved=(0..<3).map{v[$0]*c+cross[$0]*s+u[$0]*dot*(1-c)+translation[$0]}
                    structure.atoms[j].x=moved[0];structure.atoms[j].y=moved[1];structure.atoms[j].z=moved[2]
                }
                p.assets[i].payload = .proteinStructure(structure)
            } else {throw BiologyError.invalid("Unknown structured edit operation.")}
            p.assets[i].revision+=1
            return .object(["assetID":.string(assetID.uuidString),"revision":.number(Double(p.assets[i].revision))])
        }
        changed(id);return result
    }
    func select(_ id:UUID,assetID:UUID,selection:JSONValue,expectedAssetRevision:UInt64,identity:BiologyMutationIdentity? = nil) async throws -> JSONValue {
        try await permit(.edit,id)
        let result:JSONValue=try await store.transact(id,identity:identity){p in
            guard let asset=p.assets.first(where:{$0.id==assetID}),asset.revision==expectedAssetRevision else {throw BiologyError.invalid("Selection source changed.")}
            try Self.validateSelection(selection,asset:asset)
            p.activeAssetID=assetID
            var selections=p.selections ?? [:];selections[assetID.uuidString]=selection;p.selections=selections
            return .object(["assetID":.string(assetID.uuidString),"selection":selection])
        };changed(id);return result
    }
    static func optionInteger(_ value:JSONValue,_ key:String,default fallback:Int,range:ClosedRange<Int>) throws -> Int {
        guard let raw=value[key] else {return fallback}
        guard let n=raw.number,n.isFinite,n.rounded()==n,Double(range.lowerBound)<=n,n<=Double(range.upperBound) else {throw BiologyError.invalid("Invalid "+key)};return Int(n)
    }
    static func identifiers(_ raw:JSONValue?,fallback:[String]) throws -> [String] {
        guard let raw else {return fallback}
        guard let array=raw.array,!array.isEmpty,array.count<=100_000,array.allSatisfy({$0.string != nil}) else {throw BiologyError.invalid("Choose nonempty identifiers.")}
        let result=array.map{$0.string!};guard Set(result).count==result.count else {throw BiologyError.invalid("Duplicate identifiers.")};return result
    }
    static func validateSelection(_ selection:JSONValue,asset:BiologyAsset) throws {try BiologySelection.validate(selection,asset:asset)}

}
