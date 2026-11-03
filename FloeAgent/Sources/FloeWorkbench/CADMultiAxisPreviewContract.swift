// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Tool-tip XYZ plus axis toward spindle. No machine rotary-axis, G-code or IK authority.
public struct CadMultiAxisPreviewPose: Codable, Sendable, Equatable {
    public var tipMM: [Double]
    public var axisTowardSpindle: [Double]
    public init(tipMM:[Double],axisTowardSpindle:[Double]) {self.tipMM=tipMM;self.axisTowardSpindle=axisTowardSpindle}
}
public struct CadMultiAxisPreviewSampling: Codable, Sendable, Equatable {
    public var maxLinearStepMM=0.25
    public var maxAngularStepDegrees=0.125
    public var maxChordErrorMM=0.001
    public init() {}
}
public struct CadMultiAxisPreviewHolder: Codable, Sendable, Equatable {
    public var kind="noncutting-cylinder"
    public var radiusMM:Double
    public var lengthMM:Double
    public var offsetFromTipMM:Double
    public init(radiusMM:Double,lengthMM:Double,offsetFromTipMM:Double) {self.radiusMM=radiusMM;self.lengthMM=lengthMM;self.offsetFromTipMM=offsetFromTipMM}
}
public struct CadMultiAxisPreviewFixture: Codable, Sendable, Equatable {
    public var id:String
    public var minMM:[Double]
    public var maxMM:[Double]
    public var resolutionMM:Double
    public init(id:String,minMM:[Double],maxMM:[Double],resolutionMM:Double) {self.id=id;self.minMM=minMM;self.maxMM=maxMM;self.resolutionMM=resolutionMM}
}
public struct CadMultiAxisPreviewParameters: Codable, Sendable, Equatable {
    public var poses:[CadMultiAxisPreviewPose]
    public var sampling:CadMultiAxisPreviewSampling
    public var holder:CadMultiAxisPreviewHolder?
    public var fixtures:[CadMultiAxisPreviewFixture]
    public init(poses:[CadMultiAxisPreviewPose],sampling:CadMultiAxisPreviewSampling = .init(),holder:CadMultiAxisPreviewHolder?=nil,fixtures:[CadMultiAxisPreviewFixture]=[]) {self.poses=poses;self.sampling=sampling;self.holder=holder;self.fixtures=fixtures}
    public func validate(radius:Double,length:Double,resolution:Double)throws {
        func vector(_ a:[Double])->Bool {a.count==3 && a.allSatisfy{$0.isFinite && abs($0)<=100}}
        guard [0.25,0.5,1].contains(resolution),radius.isFinite,length.isFinite,(1...10).contains(radius),(2...25).contains(length),
              (2...9).contains(poses.count),poses.allSatisfy({vector($0.tipMM)&&vector($0.axisTowardSpindle)&&$0.axisTowardSpindle.reduce(0){$0+$1*$1}>1e-16}),
              sampling.maxLinearStepMM.isFinite,(0.05...1).contains(sampling.maxLinearStepMM),sampling.maxAngularStepDegrees.isFinite,(0.1...2).contains(sampling.maxAngularStepDegrees),sampling.maxChordErrorMM.isFinite,(0.0001...0.01).contains(sampling.maxChordErrorMM),fixtures.count<=8 else {throw FloeError.validationFailed("Multi-axis preview requires bounded XYZ/IJK poses, a 1–10 mm radius flat tool, 2–25 mm length and 0.25/0.5/1 mm voxels.")}
        var changed=false
        for pair in zip(poses,poses.dropFirst()) {
            let a=pair.0.axisTowardSpindle,b=pair.1.axisTowardSpindle
            let dot=zip(a,b).reduce(0){$0+$1.0*$1.1}/sqrt(a.reduce(0){$0+$1*$1}*b.reduce(0){$0+$1*$1})
            changed = changed || dot<0.9998
            guard sqrt(zip(pair.0.tipMM,pair.1.tipMM).reduce(0){$0+pow($1.1-$1.0,2)})<=50 else {throw FloeError.validationFailed("Preview tip segments are limited to 50 mm.")}
        }
        guard changed else {throw FloeError.validationFailed("Use basic machining for fixed-axis motion; this preview requires a changing tool axis.")}
        if let h=holder {guard h.kind=="noncutting-cylinder",h.radiusMM.isFinite,(0.5...12).contains(h.radiusMM),h.lengthMM.isFinite,(1...20).contains(h.lengthMM),h.offsetFromTipMM.isFinite,(length...40).contains(h.offsetFromTipMM) else{throw FloeError.validationFailed("Only an explicit cylindrical noncutting holder beyond the cutting edge is supported.")}}
        guard fixtures.isEmpty || holder != nil else{throw FloeError.validationFailed("Fixture checks need an explicit holder.")}
        var ids=Set<String>();var cells=0.0
        for f in fixtures {
            guard !f.id.isEmpty,f.id.utf8.count<=40,f.id.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45}),ids.insert(f.id).inserted,vector(f.minMM),vector(f.maxMM),[0.125,0.25,0.5,1].contains(f.resolutionMM),
                  (f.minMM+f.maxMM).allSatisfy({Double(Float($0))==$0}) else{throw FloeError.validationFailed("Fixtures must be uniquely named grid-aligned boxes.")}
            var n=1.0;for i in 0..<3 {let d=(f.maxMM[i]-f.minMM[i])/f.resolutionMM;guard d>0,d==d.rounded() else{throw FloeError.validationFailed("Fixture dimensions must be positive whole voxels.")};n *= d};cells += n
        }
        guard cells<=32768 else{throw FloeError.validationFailed("Fixture voxel budget exceeded.")}
    }
    public func taskParameters(radius:Double,length:Double,resolution:Double)throws->[String:Any] {
        var p=try JSONSerialization.jsonObject(with:JSONEncoder().encode(self)) as! [String:Any]
        p["mode"]="multi-axis-preview";p["radiusMM"]=radius;p["lengthMM"]=length;p["resolutionMM"]=resolution;p["holder"]=p["holder"] ?? NSNull()
        return p
    }
    static func decode(_ fields:[String:Any])throws->CadBasicMachiningParameters {
        guard Set(fields.keys)==["mode","resolutionMM","radiusMM","lengthMM","poses","sampling","holder","fixtures"],fields["mode"] as? String=="multi-axis-preview" else{throw FloeError.validationFailed("Unsupported multi-axis preview fields; machine joints, turning, G-code and CAM planning are unavailable.")}
        let selected=fields.filter{["poses","sampling","holder","fixtures"].contains($0.key)}
        let preview=try JSONDecoder().decode(Self.self,from:JSONSerialization.data(withJSONObject:selected))
        struct Numbers:Decodable {var resolutionMM:Double;var radiusMM:Double;var lengthMM:Double}
        let n=try JSONDecoder().decode(Numbers.self,from:JSONSerialization.data(withJSONObject:fields))
        try preview.validate(radius:n.radiusMM,length:n.lengthMM,resolution:n.resolutionMM)
        return CadBasicMachiningParameters(resolutionMM:n.resolutionMM,radiusMM:n.radiusMM,lengthMM:n.lengthMM,startTipMM:preview.poses.first!.tipMM,endTipMM:preview.poses.last!.tipMM,preview:preview)
    }
}
