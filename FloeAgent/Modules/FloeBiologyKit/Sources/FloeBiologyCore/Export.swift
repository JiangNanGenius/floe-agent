// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum BiologyExport {
    public static func asset(_ asset:BiologyAsset,format:String) throws -> Data {
        if format=="original" {
            guard asset.fileReference==nil || !asset.originalData.isEmpty else {throw BiologyError.unavailable("Export this referenced original through its authorized host file service.")}
            return asset.originalData
        }
        if format=="json" { return try BiologyCoding.encode(asset.payload) }
        switch asset.payload {
        case .sequence(let records):
            if ["fasta","fa"].contains(format) { return Data(BiologyImporter.fasta(records).utf8) }
            if ["fastq","fq"].contains(format) {
                guard records.allSatisfy({$0.quality != nil}) else { throw BiologyError.unavailable("Sequence edits invalidate quality scores. Export FASTA or the original.") }
                return Data(records.map{"@\($0.name)\n\($0.sequence)\n+\n\($0.quality!)\n"}.joined().utf8)
            }
        case .proteinStructure(let structure):
            if format=="pdb" {
                var lines:[String]=[]
                for a in structure.atoms {
                    guard a.serial>=0,a.serial<100000,a.residueNumber > -1000,a.residueNumber<10000,a.chain.utf8.count<=1,a.insertionCode.utf8.count<=1,a.name.utf8.count<=4,a.residue.utf8.count<=3,a.element.utf8.count<=2,
                          [a.x,a.y,a.z].allSatisfy({$0.isFinite && $0 >= -999.999 && $0 <= 9999.999}),a.occupancy.isFinite,a.occupancy>=0,a.occupancy<=999.99,
                          (a.chain+a.insertionCode+a.name+a.residue+a.element).utf8.allSatisfy({(32...126).contains($0)}) else { throw BiologyError.unavailable("This structure cannot be represented faithfully in legacy PDB. Export the original mmCIF or JSON.") }
                    let record=a.hetero ? "HETATM":"ATOM"
                    func fixed(_ text:String,_ width:Int,left:Bool=false)->String {
                        let padding=String(repeating:" ",count:width-text.utf8.count)
                        return left ? text+padding:padding+text
                    }
                    // Explicit fixed columns: NSString format width is not a
                    // faithful substitute for the PDB field layout.
                    let atomName=(a.name.count<4 && a.element.count==1 && a.name.first?.isLetter==true) ? " "+a.name:a.name
                    lines.append(fixed(record,6,left:true)+fixed(String(a.serial),5)+" "+fixed(atomName,4,left:true)+" "+fixed(a.residue,3)+" "+fixed(a.chain,1)+fixed(String(a.residueNumber),4)+fixed(a.insertionCode,1)+"   "+String(format:"%8.3f%8.3f%8.3f%6.2f%6.2f",a.x,a.y,a.z,a.occupancy,0.0)+"          "+fixed(a.element,2))
                }
                // Preserve multiple MODEL identities instead of joining models.
                var output="",previous:Int?
                for (i,a) in structure.atoms.enumerated() {
                    if previous != a.model {
                        if previous != nil { output+="ENDMDL\n" }
                        output+=String(format:"MODEL     %4d\n",a.model);previous=a.model
                    }
                    output+=lines[i]+"\n"
                }
                return Data((output+"ENDMDL\nEND\n").utf8)
            }
        case .microscopyImage(let image):
            if format=="image.json" {
                let object:[String:Any] = ["width":image.width,"height":image.height,"channels":image.channels,"slices":image.slices,"frames":image.frames,"bitDepth":image.bitDepth,"samples":image.samples,"pixelSizeX":image.pixelSizeX.map{$0 as Any} ?? NSNull(),"pixelSizeY":image.pixelSizeY.map{$0 as Any} ?? NSNull(),"calibrationUnit":image.calibrationUnit]
                return try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
            }
            if format=="pgm" {
                let samples=try image.plane()
                guard samples.allSatisfy({$0>=0 && $0<=65535 && $0.rounded()==$0}) else { throw BiologyError.unavailable("PGM requires integer pixels. Export image JSON to retain floating-point samples.") }
                var data=Data("P5\n\(image.width) \(image.height)\n65535\n".utf8)
                for value in samples { let n=UInt16(value);data.append(UInt8(n>>8));data.append(UInt8(n&255)) };return data
            }
        case .expressionMatrix(let matrix):
            if ["csv","tsv"].contains(format) {
                let separator=format=="csv" ? ",":"\t"
                func quote(_ s:String)->String { "\""+s.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
                var lines=[(["gene"]+matrix.cellIDs).map(quote).joined(separator:separator)]
                for (i,gene) in matrix.geneIDs.enumerated() { lines.append(quote(gene)+separator+matrix.values[i*matrix.cellIDs.count..<(i+1)*matrix.cellIDs.count].map{String($0)}.joined(separator:separator)) }
                return Data((lines.joined(separator:"\n")+"\n").utf8)
            }
        case .biochemicalNetwork(let network):if format=="network.json" { return try BiologyCoding.encode(network) }
        case .externalDataset:break
        }
        throw BiologyError.unavailable("Choose the original format or a supported derived format.")
    }
}
