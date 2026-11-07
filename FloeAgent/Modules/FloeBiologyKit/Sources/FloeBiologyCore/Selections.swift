// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum BiologySelection {
    private static func optionInteger(_ value:JSONValue,_ key:String,default fallback:Int,range:ClosedRange<Int>) throws -> Int {
        guard let raw=value[key] else {return fallback}
        guard let n=raw.number,n.isFinite,n.rounded()==n,Double(range.lowerBound)<=n,n<=Double(range.upperBound) else {throw BiologyError.invalid("Invalid "+key)};return Int(n)
    }
    private static func identifiers(_ raw:JSONValue?,fallback:[String]) throws -> [String] {
        guard let raw else {return fallback}
        guard let array=raw.array,!array.isEmpty,array.count<=100_000,array.allSatisfy({$0.string != nil}) else {throw BiologyError.invalid("Choose nonempty identifiers.")}
        let result=array.map{$0.string!};guard Set(result).count==result.count else {throw BiologyError.invalid("Duplicate identifiers.")};return result
    }
    public static func validate(_ selection:JSONValue,asset:BiologyAsset) throws {
        guard let fields=selection.object,fields.count<=12,(try BiologyCoding.encode(selection)).count<=32768 else {throw BiologyError.invalid("Invalid selection.")}
        let allowed:Set<String>
        switch asset.kind {
        case .sequence:allowed=["record","start","end"]
        case .proteinStructure:allowed=["atomIDs","chain","model"]
        case .microscopyImage:allowed=["channel","slice","frame","region"]
        case .expressionMatrix:allowed=["genes","cells"]
        case .biochemicalNetwork:allowed=[]
        case .externalDataset:
            switch asset.originalFormat {
            case "newick","nwk","tree":allowed=["nodeID"]
            case "mrc","map","ccp4":allowed=["axis","index"]
            case "tif","tiff":allowed=["series","level","channel","slice","frame","region"]
            case "h5ad","mtx":allowed=["genes","cells"]
            default:allowed=[]
            }
        }
        guard Set(fields.keys).isSubset(of:allowed) else {throw BiologyError.invalid("Unknown selection field.")}
        switch asset.payload {
        case .sequence(let records):
            let record=try optionInteger(selection,"record",default:0,range:0...max(0,records.count-1))
            let start=try optionInteger(selection,"start",default:0,range:0...records[record].sequence.count)
            let end=try optionInteger(selection,"end",default:records[record].sequence.count,range:start...records[record].sequence.count);_ = end
        case .proteinStructure(let structure):
            if let raw=selection["atomIDs"] {guard let values=raw.array,values.count<=1000,values.allSatisfy({v in guard let n=v.number,n.isFinite,n.rounded()==n,n>=0,n<=100_000 else{return false};return structure.atoms.contains{$0.id==Int(n)}}) else {throw BiologyError.invalid("Unknown atom selection.")}}
            if let chain=selection["chain"]?.string {guard structure.atoms.contains(where:{$0.chain==chain}) else {throw BiologyError.invalid("Unknown chain.")}}
            if let model=selection["model"]?.number {guard model.isFinite,model.rounded()==model,structure.atoms.contains(where:{Double($0.model)==model}) else {throw BiologyError.invalid("Unknown model.")}}
        case .microscopyImage(let image):
            _=try optionInteger(selection,"channel",default:0,range:0...image.channels-1)
            _=try optionInteger(selection,"slice",default:0,range:0...image.slices-1)
            _=try optionInteger(selection,"frame",default:0,range:0...image.frames-1)
            if let raw=selection["region"] {guard let values=raw.array,values.count==4,values.allSatisfy({$0.number?.isFinite==true && $0.number!>=0 && $0.number!.rounded()==$0.number!}) else {throw BiologyError.invalid("Invalid image region.")};let v=values.map{$0.number!};guard v[2]>0,v[3]>0,v[0]+v[2]<=Double(image.width),v[1]+v[3]<=Double(image.height) else {throw BiologyError.invalid("Image region lies outside the dataset.")}}
        case .expressionMatrix(let matrix):
            guard Set(try identifiers(selection["genes"],fallback:matrix.geneIDs)).isSubset(of:Set(matrix.geneIDs)),Set(try identifiers(selection["cells"],fallback:matrix.cellIDs)).isSubset(of:Set(matrix.cellIDs)) else {throw BiologyError.invalid("Unknown matrix selection.")}
        case .biochemicalNetwork:guard fields.isEmpty else {throw BiologyError.invalid("Network edits use typed species/reactions.")}
        case .externalDataset:
            for key in ["series","level","channel","slice","frame","axis","index"] where fields[key] != nil {_=try optionInteger(selection,key,default:0,range:0...100000000)}
            if let raw=selection["region"] {guard let v=raw.array,v.count==4,v.allSatisfy({$0.number.map{$0.isFinite && $0.rounded()==$0 && $0>=0 && $0<=100000000}==true}),v[2].number!>0,v[3].number!>0 else {throw BiologyError.invalid("Invalid file-backed image region.")}}
            if let node=selection["nodeID"] {
                let tree=try BiologyTree.parse(asset.originalData)
                guard let text=node.string,let id=Int(text),tree.nodes.indices.contains(id) else {throw BiologyError.invalid("Unknown tree node.")}
            }
            if ["mrc","map","ccp4"].contains(asset.originalFormat),!fields.isEmpty {
                guard asset.fileReference==nil else {throw BiologyError.unavailable("This density selection requires a configured volume reader.")}
                let volume=try BiologyDensityVolume.parse(asset.originalData),axis=try optionInteger(selection,"axis",default:2,range:0...2)
                _=try optionInteger(selection,"index",default:0,range:0...volume.dimensions[axis]-1)
            }
            for key in ["genes","cells"] where fields[key] != nil {_=try identifiers(fields[key],fallback:[])}
        }
    }
}
