// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

extension BiologyToolSession {
    func readPage(_ p:BiologyProject,arguments:JSONValue) async throws -> JSONValue {
        let offset=try integer(arguments,"offset",default:0),limit=try integer(arguments,"limit",default:100,range:1...20000)
        let view=arguments["view"]?.string ?? (arguments["assetID"]==nil ? "summary":"data")
        guard arguments["assetID"]==nil || arguments["runID"]==nil else {throw BiologyError.invalid("Choose a dataset or a result, not both.")}
        func page(_ entries:[JSONValue],total:Int,start:Int=0)->JSONValue {
            .object(["items":.array(entries),"total":.number(Double(total)),"offset":.number(Double(start)),"nextOffset":start+entries.count<total ? .number(Double(start+entries.count)):.null])
        }
        if let raw=arguments["runID"]?.string {
            guard let run=p.runs.first(where:{$0.id.uuidString.lowercased()==raw.lowercased()}) else {throw BiologyError.invalid("Calculation is missing.")}
            guard let result=run.result else {return try runMetadata(run)}
            if view=="text" {
                guard offset<=result.text.count else {throw BiologyError.invalid("Text offset exceeds output length.")}
                let start=result.text.index(result.text.startIndex,offsetBy:offset),end=result.text.index(start,offsetBy:min(limit,result.text.count-offset))
                return .object(["text":.string(String(result.text[start..<end])),"offset":.number(Double(offset)),"totalCharacters":.number(Double(result.text.count)),"nextOffset":offset+limit<result.text.count ? .number(Double(offset+limit)):.null])
            }
            if view=="summary" {return try runMetadata(run)}
            guard offset<=result.rows.count else {throw BiologyError.invalid("Result row offset exceeds output length.")}
            let end=min(result.rows.count,offset+min(limit,500))
            let rows=Array(result.rows[offset..<end]),names=(offset..<end).map{result.rowNames.indices.contains($0) ? result.rowNames[$0]:String($0+1)}
            return try bounded(JSONValue.object(["runID":.string(run.id.uuidString),"sourceRevision":.number(Double(run.assetRevision)),"columns":try BiologyCoding.json(result.columns),"rows":try BiologyCoding.json(rows),"rowNames":try BiologyCoding.json(names),"totalRows":.number(Double(result.rows.count)),"nextOffset":end<result.rows.count ? .number(Double(end)):.null,"metrics":try BiologyCoding.json(result.metrics),"details":try BiologyCoding.json(result.details)]))
        }
        guard let raw=arguments["assetID"]?.string else {return try metadata(p)}
        guard let asset=p.assets.first(where:{$0.id.uuidString.lowercased()==raw.lowercased()}) else {throw BiologyError.invalid("Dataset is missing.")}
        var answer=try metadata(asset).object ?? [:]
        answer["selection"]=p.selections?[asset.id.uuidString] ?? .object([:])
        if view=="selection" || view=="summary" {return .object(answer)}
        if view=="data" {
            let data=try BiologyCoding.encode(asset.payload)
            if data.count<=1_500_000 {answer["payload"]=try JSONDecoder().decode(JSONValue.self,from:data);return .object(answer)}
            answer["paged"] = .bool(true);answer["availableViews"] = .array(["sequence","annotations","atoms","pixels","matrix","network"].map(JSONValue.string))
            return .object(answer)
        }
        switch asset.payload {
        case .sequence(let records):
            let record=try integer(arguments,"record",default:0,range:0...max(0,records.count-1)),r=records[record]
            if view=="annotations" {
                guard offset<=r.annotations.count else {throw BiologyError.invalid("Annotation offset exceeds its count.")}
                answer["annotations"]=page(try r.annotations.dropFirst(offset).prefix(min(limit,500)).map{try BiologyCoding.json($0)},total:r.annotations.count,start:offset)
            } else {
                guard view=="sequence",offset<=r.sequence.count else {throw BiologyError.invalid("Choose sequence/annotations with a valid offset.")}
                let a=r.sequence.index(r.sequence.startIndex,offsetBy:offset),b=r.sequence.index(a,offsetBy:min(limit,r.sequence.count-offset))
                answer["recordID"] = .string(r.id.uuidString);answer["name"] = .string(r.name);answer["alphabet"] = .string(r.alphabet)
                answer["sequence"] = .string(String(r.sequence[a..<b]));answer["offset"] = .number(Double(offset));answer["totalSymbols"] = .number(Double(r.sequence.count));answer["records"] = .number(Double(records.count))
            }
        case .proteinStructure(let s):
            guard view=="atoms",offset<=s.atoms.count else {throw BiologyError.invalid("Choose atoms with a valid offset.")}
            answer["atoms"]=page(try s.atoms.dropFirst(offset).prefix(min(limit,500)).map{try BiologyCoding.json($0)},total:s.atoms.count,start:offset)
        case .microscopyImage(let image):
            guard view=="pixels" else {throw BiologyError.invalid("Choose a bounded pixels region.")}
            let c=try integer(arguments,"channel",default:0,range:0...image.channels-1),z=try integer(arguments,"slice",default:0,range:0...image.slices-1),t=try integer(arguments,"frame",default:0,range:0...image.frames-1)
            let region=arguments["region"]?.array ?? [.number(0),.number(0),.number(Double(min(image.width,128))),.number(Double(min(image.height,128)))]
            let selection=JSONValue.object(["channel":.number(Double(c)),"slice":.number(Double(z)),"frame":.number(Double(t)),"region":.array(region)])
            try BiologyService.validateSelection(selection,asset:asset)
            let v=region.map{Int($0.number!)},plane=try image.plane(channel:c,slice:z,frame:t)
            guard v[2]*v[3]<=65536 else {throw BiologyError.invalid("Pixel preview exceeds 65,536 samples.")}
            let pixels=(v[1]..<v[1]+v[3]).flatMap{y in Array(plane[y*image.width+v[0]..<y*image.width+v[0]+v[2]])}
            answer["region"] = .array(region);answer["pixels"]=try BiologyCoding.json(pixels);answer["bitDepth"] = .number(Double(image.bitDepth));answer["calibrationUnit"] = .string(image.pixelSizeX==nil ? "px":image.calibrationUnit)
        case .expressionMatrix(let matrix):
            guard view=="matrix",offset<=matrix.geneIDs.count else {throw BiologyError.invalid("Choose a valid matrix gene offset.")}
            let column=try integer(arguments,"columnOffset",default:0,range:0...matrix.cellIDs.count),width=try integer(arguments,"columnLimit",default:32,range:1...128)
            let end=min(offset+min(limit,128),matrix.geneIDs.count),right=min(column+width,matrix.cellIDs.count)
            answer["geneIDs"]=try BiologyCoding.json(Array(matrix.geneIDs[offset..<end]));answer["cellIDs"]=try BiologyCoding.json(Array(matrix.cellIDs[column..<right]))
            answer["rows"]=try BiologyCoding.json((offset..<end).map{g in Array(matrix.values[g*matrix.cellIDs.count+column..<g*matrix.cellIDs.count+right])})
            answer["totalGenes"] = .number(Double(matrix.geneIDs.count));answer["totalCells"] = .number(Double(matrix.cellIDs.count));answer["orientation"] = .string("genes × cells")
        case .biochemicalNetwork(let network):
            guard view=="network" else {throw BiologyError.invalid("Choose network view.")};answer["network"]=try BiologyCoding.json(network)
        case .externalDataset:
            answer["message"] = .string("Use an available format-aware scientific method or bounded host file read; originals are not expanded into this response.")
        }
        return try bounded(JSONValue.object(answer))
    }
}
