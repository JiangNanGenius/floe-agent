// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Small native methods, with explicit budgets. Larger workloads use a configured backend.
public enum BiologyNativeAnalysis {
    public static let methods: [BiologyAssetKind: [String]] = [
        .sequence: ["sequence.stats","sequence.reverseComplement","sequence.translate","sequence.align.global","sequence.align.local","sequence.orfs"],
        .proteinStructure: ["structure.geometry","structure.contacts","structure.distance"],
        .microscopyImage: ["image.segment","image.statistics"],
        .expressionMatrix: ["matrix.qc","matrix.normalize","matrix.log1p","matrix.geneStatistics"],
        .biochemicalNetwork: ["network.simulate","network.sweep"]
    ]
    public static func run(asset: BiologyAsset, method: String, options: JSONValue = .object([:])) throws -> BiologyAnalysisResult {
        try Task.checkCancellation()
        guard methods[asset.kind, default:[]].contains(method) else { throw BiologyError.unavailable("This analysis is not available for the selected dataset.") }
        switch asset.payload {
        case .sequence(let records): return try sequence(records,method:method,options:options)
        case .proteinStructure(let structure): return try geometry(structure,method:method,options:options)
        case .microscopyImage(let image): return try microscopy(image,method:method,options:options)
        case .expressionMatrix(let matrix): return try omics(matrix,method:method,options:options)
        case .biochemicalNetwork(let network): return try simulation(network,method:method,options:options)
        case .externalDataset: throw BiologyError.unavailable("Configure a scientific backend for this dataset.")
        }
    }
    private static func integer(_ o: JSONValue,_ key:String,_ fallback:Int,_ range:ClosedRange<Int>) throws -> Int {
        guard let raw = o[key] else { return fallback }
        guard let x = raw.number,x.isFinite,x.rounded()==x,Double(range.lowerBound)<=x,x<=Double(range.upperBound) else { throw BiologyError.invalid("Invalid \(key).") }; return Int(x)
    }
    private static func number(_ o:JSONValue,_ key:String,_ fallback:Double,_ range:ClosedRange<Double>) throws -> Double {
        guard let raw = o[key] else { return fallback }
        guard let x = raw.number,x.isFinite,range.contains(x) else { throw BiologyError.invalid("Invalid \(key).") }; return x
    }
    public static func reverseComplement(_ s:String) throws -> String {
        let map = Dictionary(uniqueKeysWithValues: zip(Array("ACGTRYSWKMBDHVNU-"),Array("TGCAYRSWMKVHDBNA-")))
        guard s.allSatisfy({ map[$0] != nil }) else { throw BiologyError.invalid("Reverse complement requires a nucleotide sequence.") }
        return String(s.reversed().map { map[$0]! })
    }
    public static func translate(_ sequence:String,frame:Int = 1,code:Int = 1) throws -> String {
        guard [1,2].contains(code), [-3,-2,-1,1,2,3].contains(frame), !sequence.contains("-") else { throw BiologyError.invalid("Choose code 1/2 and a reading frame; aligned gaps need removal before translation.") }
        let s = frame < 0 ? try reverseComplement(sequence) : sequence
        let chars = Array(s.replacingOccurrences(of:"U",with:"T"))
        let bases = Array("TCAG"), amino = Array("FFLLSSSSYY**CC*WLLLLPPPPHHQQRRRRIIIMTTTTNNKKSSRRVVVVAAAADDEEGGGG")
        var table:[String:Character] = [:], index = 0
        for a in bases { for b in bases { for c in bases { table[String([a,b,c])] = amino[index]; index += 1 } } }
        if code == 2 { table["AGA"] = "*"; table["AGG"] = "*"; table["ATA"] = "M"; table["TGA"] = "W" }
        let offset = abs(frame)-1
        if chars.count < offset+3 { return "" }
        return String(stride(from:offset,through:chars.count-3,by:3).map { table[String(chars[$0..<$0+3])] ?? "X" })
    }
    private static func sequence(_ records:[SequenceRecord],method:String,options:JSONValue) throws -> BiologyAnalysisResult {
        let i = try integer(options,"record",0,0...max(0,records.count-1))
        guard records.indices.contains(i) else { throw BiologyError.invalid("Select a valid sequence.") }
        let record = records[i], s = record.sequence
        var result = BiologyAnalysisResult(summary:method)
        if method == "sequence.stats" {
            let counts = Dictionary(grouping:s,by:{$0}).mapValues(\.count)
            let base = ["A","C","G","T","U"].reduce(0) { $0+(counts[Character($1)] ?? 0) }
            result.metrics = ["length":Double(s.count),"ambiguous":Double(s.filter { !"ACGTU".contains($0) }.count)]
            if record.alphabet != "protein" && base > 0 { result.metrics["GC_percent"] = 100*Double((counts["G"] ?? 0)+(counts["C"] ?? 0))/Double(base) }
            result.columns = ["count"]; result.rowNames = counts.keys.map(String.init).sorted()
            result.rows = result.rowNames.map { [Double(counts[Character($0)]!)] }
        } else if method == "sequence.reverseComplement" {
            guard record.alphabet != "protein" else { throw BiologyError.invalid("A protein has no nucleotide complement.") }
            result.text = try reverseComplement(s)
            if record.alphabet == "rna" { result.text = result.text.replacingOccurrences(of:"T",with:"U") }
        } else if method == "sequence.translate" {
            guard record.alphabet != "protein" else { throw BiologyError.invalid("Select a nucleotide sequence to translate.") }
            let frame = try integer(options,"frame",1,-3...3), code = try integer(options,"code",1,1...2)
            result.text = try translate(s,frame:frame,code:code)
            result.metrics = ["aminoAcids":Double(result.text.count),"stops":Double(result.text.filter{$0=="*"}.count)]
            result.details = ["geneticCode":"NCBI \(code)","readingFrame":String(frame),"partialCodonPolicy":"Ignored trailing incomplete codon; ambiguous codons become X."]
        } else if method == "sequence.orfs" {
            guard record.alphabet != "protein", s.count <= 200_000 else { throw BiologyError.invalid("ORF scan requires a bounded nucleotide sequence.") }
            result.columns = ["frame","startCodonIndex","aminoAcids"]
            for frame in [-3,-2,-1,1,2,3] {
                let protein = try translate(s,frame:frame)
                let aa = Array(protein); var start:Int?
                for j in aa.indices {
                    if aa[j] == "M" && start == nil { start=j }
                    if aa[j] == "*", let a = start {
                        result.rows.append([Double(frame),Double(a),Double(j-a)]); start=nil
                    }
                }
            }
            result.metrics["completeORFs"] = Double(result.rows.count)
            result.details["method"] = "Six-frame start-M to first-stop scan, code 1; indices are amino-acid offsets in the indicated frame. Incomplete ORFs omitted."
        } else {
            let j = try integer(options,"query",1,0...max(0,records.count-1))
            guard records.indices.contains(j), j != i else { throw BiologyError.invalid("Import at least two records and choose different sequences.") }
            result = try align(s,records[j].sequence,local:method.hasSuffix("local"))
        }
        return result
    }
    public static func align(_ reference:String,_ query:String,local:Bool = false) throws -> BiologyAnalysisResult {
        let a = Array(reference),b = Array(query), n=a.count,m=b.count
        guard n > 0,m > 0,n <= 4_000_000/m,n*m <= 4_000_000 else { throw BiologyError.invalid("Alignment exceeds the native 4-million-cell budget.") }
        let width=m+1
        var score=[Int](repeating:0,count:(n+1)*(m+1)),trace=[UInt8](repeating:0,count:score.count),best=(score:0,i:n,j:m)
        if !local {
            for i in 1...n { score[i*width] = -2*i; trace[i*width]=2 }
            for j in 1...m { score[j] = -2*j; trace[j]=3 }
        }
        for i in 1...n {
            try Task.checkCancellation()
            for j in 1...m {
                let candidates = [local ? 0 : Int.min/4,score[(i-1)*width+j-1]+(a[i-1]==b[j-1] ? 2 : -1),score[(i-1)*width+j]-2,score[i*width+j-1]-2]
                let k = candidates.indices.max(by:{candidates[$0]<candidates[$1]})!
                score[i*width+j]=candidates[k]; trace[i*width+j]=UInt8(k)
                if local && candidates[k]>best.score { best=(candidates[k],i,j) }
            }
        }
        var i=local ? best.i:n,j=local ? best.j:m, aa:[Character]=[],bb:[Character]=[]
        let total = score[i*width+j]
        while i>0 || j>0 {
            let d=trace[i*width+j]
            if local && (d==0 || score[i*width+j]==0) { break }
            if d==1 && i>0 && j>0 { aa.append(a[i-1]);bb.append(b[j-1]);i-=1;j-=1 }
            else if (d==2 || j==0) && i>0 { aa.append(a[i-1]);bb.append("-");i-=1 }
            else if j>0 { aa.append("-");bb.append(b[j-1]);j-=1 }
            else { break }
        }
        aa.reverse();bb.reverse()
        var r=BiologyAnalysisResult(summary:local ? "Local sequence alignment":"Global sequence alignment")
        r.metrics=["score":Double(total),"alignedColumns":Double(aa.count),"identity_percent":aa.isEmpty ? 0:100*Double(zip(aa,bb).filter{$0==$1}.count)/Double(aa.count)]
        r.text=String(aa)+"\n"+String(bb)
        r.details=["method":local ? "Smith-Waterman, linear gaps":"Needleman-Wunsch, linear gaps","match":"2","mismatch":"-1","gap":"-2","referenceStart":String(i),"queryStart":String(j)]
        return r
    }
    private static func geometry(_ structure:ProteinStructure,method:String,options:JSONValue) throws -> BiologyAnalysisResult {
        let model=try integer(options,"model",structure.atoms.first?.model ?? 1,1...100_000)
        let chain=options["chain"]?.string
        let atoms=structure.atoms.filter{$0.model==model && (chain == nil || $0.chain==chain)}
        guard !atoms.isEmpty else { throw BiologyError.invalid("The selected structure contains no atoms.") }
        var r=BiologyAnalysisResult(summary:method)
        let center=[atoms.map(\.x).reduce(0,+),atoms.map(\.y).reduce(0,+),atoms.map(\.z).reduce(0,+)].map{$0/Double(atoms.count)}
        let rg=sqrt(atoms.reduce(0){$0+pow($1.x-center[0],2)+pow($1.y-center[1],2)+pow($1.z-center[2],2)}/Double(atoms.count))
        r.metrics=["atoms":Double(atoms.count),"polymerAtoms":Double(atoms.filter{!$0.hetero}.count),"residues":Double(Set(atoms.filter{!$0.hetero}.map(\.residueID)).count),"chains":Double(Set(atoms.map(\.chain)).count),"geometricGyration_A":rg]
        r.details=["coordinates":"Å","gyration":"Unweighted geometric radius; not a mass-weighted radius.","altloc":"Highest occupancy per atom identity; original retains all conformers.","representation":"Actual atom coordinates and Cα backbone; no inferred secondary structure."]
        if method=="structure.distance" {
            let a=try integer(options,"atomA",0,0...atoms.count-1), b=try integer(options,"atomB",1,0...atoms.count-1)
            r.metrics["distance_A"]=sqrt(pow(atoms[a].x-atoms[b].x,2)+pow(atoms[a].y-atoms[b].y,2)+pow(atoms[a].z-atoms[b].z,2))
        } else if method=="structure.contacts" {
            let cutoff=try number(options,"cutoff",4,0.1...20)
            struct Bin:Hashable { let x:Int;let y:Int;let z:Int }
            var bins:[Bin:[Int]]=[:], count=0
            r.columns=["atomA","atomB","distance_A"]
            for (i,a) in atoms.enumerated() {
                if i%256==0 { try Task.checkCancellation() }
                let k=Bin(x:Int(floor(a.x/cutoff)),y:Int(floor(a.y/cutoff)),z:Int(floor(a.z/cutoff)))
                for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                    for j in bins[Bin(x:k.x+dx,y:k.y+dy,z:k.z+dz),default:[]] {
                        let b=atoms[j], distance=sqrt(pow(a.x-b.x,2)+pow(a.y-b.y,2)+pow(a.z-b.z,2))
                        if distance<=cutoff {
                            count+=1
                            if r.rows.count<20_000 { r.rows.append([Double(j),Double(i),distance]) }
                            if count>2_000_000 { throw BiologyError.invalid("Contact density exceeds the native budget.") }
                        }
                    }
                } } }
                bins[k,default:[]].append(i)
            }
            r.metrics["contacts"]=Double(count);r.details["tableTruncated"]=String(count>r.rows.count)
        }
        return r
    }
    private static func microscopy(_ image:MicroscopyImage,method:String,options:JSONValue) throws -> BiologyAnalysisResult {
        let channel=try integer(options,"channel",0,0...image.channels-1),slice=try integer(options,"slice",0,0...image.slices-1),frame=try integer(options,"frame",0,0...image.frames-1)
        let plane=try image.plane(channel:channel,slice:slice,frame:frame)
        let low=plane.min()!,high=plane.max()!,mean=plane.reduce(0,+)/Double(plane.count)
        var r=BiologyAnalysisResult(summary:method)
        r.metrics=["minimum":low,"maximum":high,"mean":mean,"pixels":Double(plane.count)]
        r.details=["channel":String(channel),"slice":String(slice),"frame":String(frame),"areaUnit":image.pixelSizeX == nil ? "px²":image.calibrationUnit+"²"]
        guard method=="image.segment" else { return r }
        let threshold:Double
        if options["threshold"] != nil { threshold=try number(options,"threshold",0,-Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude) }
        else {
            var histogram=[Int](repeating:0,count:256)
            let span=max(high-low,1e-12)
            for v in plane { histogram[min(255,max(0,Int((v-low)/span*255)))]+=1 }
            let total=plane.count,totalSum=(0..<256).reduce(0.0){$0+Double($1*histogram[$1])}
            var background=0,sum=0.0,best = -1.0,cut=0
            for t in 0..<255 {
                background+=histogram[t];sum+=Double(t*histogram[t])
                let foreground=total-background
                if background==0 || foreground==0 { continue }
                let difference=sum/Double(background)-(totalSum-sum)/Double(foreground)
                let variance=Double(background)*Double(foreground)*difference*difference
                if variance>best { best=variance;cut=t }
            }
            threshold=low+Double(cut)/255*span
        }
        let connectivity=try integer(options,"connectivity",8,4...8)
        guard [4,8].contains(connectivity) else { throw BiologyError.invalid("Connectivity must be 4 or 8.") }
        let minArea=try integer(options,"minArea",1,1...plane.count)
        var labels=[Int](repeating:0,count:plane.count), visited=[Bool](repeating:false,count:plane.count), label=0
        r.columns=["pixels","area","meanIntensity","centroidX","centroidY"]
        let scale=(image.pixelSizeX ?? 1)*(image.pixelSizeY ?? 1)
        for start in plane.indices {
            if start%4096==0 { try Task.checkCancellation() }
            if visited[start] || plane[start]<=threshold { continue }
            var queue=[start],cursor=0;visited[start]=true
            while cursor<queue.count {
                let index=queue[cursor];cursor+=1;let x=index%image.width,y=index/image.width
                for dy in -1...1 { for dx in -1...1 where !(dx==0 && dy==0) && (connectivity==8 || dx==0 || dy==0) {
                    let xx=x+dx,yy=y+dy
                    if xx>=0 && xx<image.width && yy>=0 && yy<image.height {
                        let next=yy*image.width+xx
                        if !visited[next] && plane[next]>threshold { visited[next]=true;queue.append(next) }
                    }
                } }
            }
            if queue.count>=minArea {
                label+=1;var sum=0.0,x=0.0,y=0.0
                for index in queue { labels[index]=label;sum+=plane[index];x+=Double(index%image.width);y+=Double(index/image.width) }
                let n=Double(queue.count)
                r.rows.append([n,n*scale,sum/n,x/n,y/n]);r.rowNames.append("Object \(label)")
            }
        }
        r.labels=labels;r.metrics["objects"]=Double(label);r.metrics["threshold"]=threshold
        r.details["thresholdMethod"]=options["threshold"] == nil ? "Otsu, 256 bins":"Fixed threshold"
        return r
    }
    private static func omics(_ matrix:ExpressionMatrix,method:String,options:JSONValue) throws -> BiologyAnalysisResult {
        try matrix.validate()
        let n=matrix.cellIDs.count,g=matrix.geneIDs.count
        var sums=[Double](repeating:0,count:n),detected=[Double](repeating:0,count:n)
        for i in 0..<g { for j in 0..<n { let v=matrix.values[i*n+j];sums[j]+=v;if v>0 { detected[j]+=1 } } }
        var r=BiologyAnalysisResult(summary:method)
        r.metrics=["genes":Double(g),"cells":Double(n),"zeroCells":Double(sums.filter{$0==0}.count)]
        if method=="matrix.qc" {
            r.columns=["totalCounts","detectedGenes"];r.rowNames=matrix.cellIDs;r.rows=zip(sums,detected).map{[$0,$1]}
        } else if method=="matrix.geneStatistics" {
            r.columns=["mean","sampleVariance","detectedCells"];r.rowNames=matrix.geneIDs
            for i in 0..<g {
                let row=Array(matrix.values[i*n..<(i+1)*n]),mean=row.reduce(0,+)/Double(n)
                r.rows.append([mean,n>1 ? row.reduce(0){$0+pow($1-mean,2)}/Double(n-1):0,Double(row.filter{$0>0}.count)])
            }
        } else {
            let target=try number(options,"targetSum",10_000,1...1e9)
            r.columns=matrix.cellIDs;r.rowNames=matrix.geneIDs
            for i in 0..<g {
                try Task.checkCancellation()
                r.rows.append((0..<n).map { j in
                    let v=matrix.values[i*n+j]
                    return method=="matrix.log1p" ? log1p(v):(sums[j]>0 ? v/sums[j]*target:0)
                })
            }
            r.details["method"]=method=="matrix.log1p" ? "log1p of input counts":"Per-cell library-size normalization; zero cells remain zero."
            r.details["orientation"]="gene rows × cell columns"
        }
        return r
    }
    public static func timeCourse(_ network:BiochemicalNetwork,end:Double,step:Double) throws -> BiologyAnalysisResult {
        try network.validate()
        guard end.isFinite,step.isFinite,end>0,step>0,end<=1e6,ceil(end/step)<=100_000 else { throw BiologyError.invalid("Invalid simulation duration or step budget.") }
        let ids=network.species.map(\.id),positions=Dictionary(uniqueKeysWithValues:ids.enumerated().map{($0.element,$0.offset)})
        func derivative(_ y:[Double]) -> [Double] {
            var d=[Double](repeating:0,count:y.count)
            for reaction in network.reactions {
                var rate=reaction.rateConstant
                for (id,stoich) in reaction.reactants { rate*=pow(y[positions[id]!],Double(stoich)) }
                for (id,s) in reaction.reactants { d[positions[id]!] -= Double(s)*rate }
                for (id,s) in reaction.products { d[positions[id]!] += Double(s)*rate }
            };return d
        }
        var y=network.species.map(\.initialAmount),t=0.0
        var result=BiologyAnalysisResult(summary:"Biochemical time course")
        result.columns=["time"]+ids;result.rows=[[0]+y]
        let count=Int(ceil(end/step))
        for k in 0..<count {
            if k%32==0 { try Task.checkCancellation() }
            let h=min(step,end-t),a=derivative(y),b=derivative(zip(y,a).map{$0+$1*h/2}),c=derivative(zip(y,b).map{$0+$1*h/2}),d=derivative(zip(y,c).map{$0+$1*h})
            for i in y.indices { y[i]+=h*(a[i]+2*b[i]+2*c[i]+d[i])/6 }
            guard y.allSatisfy({$0.isFinite && $0>=0}) else { throw BiologyError.invalid("Solver reached a negative or non-finite amount. Reduce the step or use an adaptive backend.") }
            t=min(end,t+h)
            if count<=5000 || k%max(1,count/5000)==0 || k==count-1 { result.rows.append([t]+y) }
        }
        result.metrics=["steps":Double(count),"finalTime":t]
        for (i,id) in ids.enumerated() { result.metrics["final_"+id]=y[i] }
        result.details=["solver":"Classical RK4, fixed maximum step","step":String(step),"timeUnit":network.timeUnit,"amountUnit":network.amountUnit,"negativePolicy":"Fail; no clipping."]
        return result
    }
    private static func simulation(_ network:BiochemicalNetwork,method:String,options:JSONValue) throws -> BiologyAnalysisResult {
        let end=try number(options,"timeEnd",30,1e-9...1e6),step=try number(options,"step",0.1,1e-9...1e6)
        if method=="network.simulate" { return try timeCourse(network,end:end,step:step) }
        let index=try integer(options,"reaction",0,0...max(0,network.reactions.count-1))
        guard network.reactions.indices.contains(index),let raw=options["values"]?.array,!raw.isEmpty,raw.count<=32 else { throw BiologyError.invalid("Provide up to 32 rate values for a parameter sweep.") }
        var r=BiologyAnalysisResult(summary:"Reaction-rate comparison");r.columns=["rate"]+network.species.map(\.id)
        for value in raw {
            guard let k=value.number,k.isFinite,k>=0 else { throw BiologyError.invalid("Invalid sweep rate.") }
            var changed=network;changed.reactions[index].rateConstant=k
            let output=try timeCourse(changed,end:end,step:step)
            r.rows.append([k]+network.species.map{output.metrics["final_"+$0.id]!})
        }
        r.details["solver"]="Classical RK4, fixed maximum step";return r
    }
}
