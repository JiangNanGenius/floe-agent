// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum BiologyScientificAnalysis {
    public static func run(asset:BiologyAsset,method:String,options:JSONValue) throws -> BiologyAnalysisResult {
        guard asset.fileReference==nil else {throw BiologyError.unavailable("This large dataset requires a configured file-backed scientific reader.")}
        if method=="tree.inspect" {
            guard ["newick","nwk","tree"].contains(asset.originalFormat) else {throw BiologyError.invalid("Choose a Newick tree.")}
            let tree=try BiologyTree.parse(asset.originalData)
            var result=BiologyAnalysisResult(summary:"Tree topology and branch lengths")
            result.metrics=["nodes":Double(tree.nodes.count),"leaves":Double(tree.leaves.count),"negativeBranches":Double(tree.nodes.filter{($0.length ?? 0)<0}.count)]
            result.columns=["node","children","branchLength","hasLength"]
            result.rows=tree.nodes.map{[Double($0.id),Double($0.children.count),$0.length ?? 0,$0.length==nil ? 0:1]};result.rowNames=tree.nodes.map(\.label)
            result.text=String(decoding:asset.originalData,as:UTF8.self);result.details=["missingLength":"hasLength=0 marks absent lengths; the length placeholder is not a measured zero."]
            return result
        }
        guard ["mrc","map","ccp4"].contains(asset.originalFormat) else {throw BiologyError.invalid("Choose an MRC/CCP4 density map.")}
        let volume=try BiologyDensityVolume.parse(asset.originalData),mean=volume.values.reduce(0,+)/Double(volume.values.count)
        var result=BiologyAnalysisResult(summary:"Density map")
        result.metrics=["voxels":Double(volume.values.count),"width":Double(volume.dimensions.x),"height":Double(volume.dimensions.y),"depth":Double(volume.dimensions.z),"minimum":volume.values.min()!,"maximum":volume.values.max()!,"mean":mean,"standardDeviation":sqrt(volume.values.reduce(0){$0+pow($1-mean,2)}/Double(volume.values.count))]
        result.details=["coordinates":"Å; crystallographic axes reordered from MAPC/MAPR/MAPS, cell angles and starts/origin applied.","density":"Original sample units; no invented normalization."]
        func integer(_ key:String,_ fallback:Int) throws -> Int {
            guard let value=options[key] else{return fallback}
            guard let n=value.number,n.isFinite,let number=Int(exactly:n) else {throw BiologyError.invalid("Invalid density coordinate: "+key)};return number
        }
        if method=="volume.slice" {
            let axis=try integer("axis",2)
            guard (0...2).contains(axis) else {throw BiologyError.invalid("Choose density axis X, Y or Z.")}
            let slice=try volume.slice(axis:axis,index:integer("index",volume.dimensions[axis]/2))
            result.columns=["density"]
            guard slice.values.count<=100000 else {throw BiologyError.invalid("Slice table exceeds 100,000 rows. Use the native image view or a smaller volume.")}
            result.rows=slice.values.map{[$0]};result.metrics["sliceWidth"]=Double(slice.width);result.metrics["sliceHeight"]=Double(slice.height)
        } else if method=="volume.isosurface" {
            let mesh=try volume.isosurface(value:options["isovalue"]?.number ?? mean,stride:integer("stride",2))
            result.columns=["x_A","y_A","z_A"];result.rows=mesh.vertices.map{[Double($0.x),Double($0.y),Double($0.z)]};result.metrics["triangles"]=Double(mesh.vertices.count/3)
            result.details["topology"]="Each three consecutive vertices form an outward triangle; marching tetrahedra on the chosen sampling stride."
        } else if method != "volume.statistics" {throw BiologyError.invalid("Unknown density operation.")}
        return result
    }
}
