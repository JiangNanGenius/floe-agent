// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeModalLAPACK

public struct EngineeringMode: Codable, Equatable, Sendable {
    public var index:Int
    public var frequencyHz:Double
    public var angularFrequencySquaredPerSecondSquared:Double
    /// Dimensionless; largest nodal vector norm is one. No excitation amplitude.
    public var normalizedShape:[Vector3]
    /// For normalizedShape: phi^T M phi in kg and phi^T K_SI phi in N/m.
    public var generalizedMassKg:Double
    public var generalizedStiffnessNPerMeter:Double
    public var relativeResidual:Double
    public var massNormalizationError:Double
}
public struct EngineeringModalResult: Codable, Equatable, Sendable {
    public var modes:[EngineeringMode]
    public var freeDOFs:Int
    public var maximumMassOrthogonalityError:Double
    public var minimumStiffnessPivot:Double
    public var wallSeconds:Double
    public var sourceHash:String
}

/// Constrained, unloaded, small-strain isotropic tet4 modes. The existing
/// static element stiffness and support certification are reused unchanged.
/// Dense native eigen work is explicitly limited to 512 free displacement DOFs.
public struct EngineeringModalRequest: Codable, Sendable {
    public var meshNodes:[MeshNode]
    public var meshElements:[Tetrahedron]
    public var material:EngineeringMaterial
    public var displacementBCs:[DisplacementBC]
    public var requestedModes:Int
    public var tolerance:EngineeringTolerance
    public var budget:EngineeringBudget
    public init(meshNodes:[MeshNode],meshElements:[Tetrahedron],material:EngineeringMaterial,displacementBCs:[DisplacementBC],requestedModes:Int=6,tolerance:EngineeringTolerance = .init(),budget:EngineeringBudget = .init()) {
        self.meshNodes=meshNodes;self.meshElements=meshElements;self.material=material;self.displacementBCs=displacementBCs;self.requestedModes=requestedModes;self.tolerance=tolerance;self.budget=budget
    }
    public func solve(control:EngineeringSolveControl = .init()) throws -> EngineeringModalResult {
        let started=Date();try budget.validate();try tolerance.validate();try material.validateForStructural();try control.checkCancelled()
        guard let density=material.massDensityKgPerMM3,density.isFinite,density>0 else { throw EngineeringError.invalidMaterial("Modal analysis needs positive mass density in kg/mm^3.") }
        guard requestedModes>0,requestedModes<=512 else { throw EngineeringError.invalidInput("Request 1...512 modes within the free-DOF count.") }
        let mesh=try ValidatedTetraMesh(nodes:meshNodes,elements:meshElements,budget:budget)
        let totalDOFs=mesh.nodes.count*3
        var fixed=[Bool](repeating:false,count:totalDOFs)
        for bc in displacementBCs {
            guard mesh.nodes.indices.contains(bc.node),bc.constrained.count==3,bc.prescribedMM.count==3,bc.constrained.contains(true),bc.prescribedMM.allSatisfy(\.isFinite) else { throw EngineeringError.invalidInput("Invalid modal displacement support.") }
            for axis in 0..<3 where bc.constrained[axis] {
                guard bc.prescribedMM[axis]==0 else { throw EngineeringError.unsupportedAnalysis("Unloaded modes require zero prescribed support displacement; prestress is not implemented.") }
                fixed[bc.node*3+axis]=true
            }
        }
        try SystemValidation.requireSupportInEveryComponent(elementNodes:mesh.elements.map(\.nodes),nodeCount:mesh.nodes.count,isSupported:{ node in (0..<3).contains { fixed[3*node+$0] } },kind:"constrained modal")
        let free=fixed.indices.filter { !fixed[$0] },n=free.count
        guard n>0,n<=512,requestedModes<=n else { throw EngineeringError.budgetExceeded("Constrained modal analysis supports 1...512 free DOFs and no more requested modes than free DOFs.") }
        let workingBytes=12*n*n*8+mesh.nodes.count*3*8*(requestedModes+4)+mesh.elements.count*512
        guard workingBytes<=budget.maxEstimatedBytes,n*(n-1)/2<=budget.maxNonzeros else { throw EngineeringError.budgetExceeded("Dense modal matrices, native workspace or shape history exceed this request's memory/nonzero budget.") }
        var inverse=[Int](repeating:-1,count:totalDOFs);for (i,dof) in free.enumerated(){inverse[dof]=i}
        var stiffness=[Double](repeating:0,count:n*n),mass=stiffness
        let elastic=try IsotropicElasticity(material:material)
        for (index,tet) in mesh.elements.enumerated() {
            if index&63==0 { try control.checkCancelled();try checkTime(started) }
            let geometry=mesh.geometry[index],ke=elastic.elementStiffness(geometry:geometry)
            let coefficient=density*geometry.volume/20
            guard coefficient.isFinite,coefficient>0 else { throw EngineeringError.invalidMaterial("An element has non-positive or unresolvable modal mass.") }
            let dofs=tet.nodes.flatMap { [$0*3,$0*3+1,$0*3+2] }
            for r in 0..<12 {
                let row=inverse[dofs[r]];if row<0{continue}
                for c in 0..<12 {
                    let col=inverse[dofs[c]];if col<row{continue}
                    // Core Ke is N/mm. SI K is N/m; mass stays kg because
                    // density(kg/mm^3)*volume(mm^3) already yields kg.
                    stiffness[row+col*n]+=ke[r*12+c]*1000
                    if r%3==c%3 { mass[row+col*n]+=coefficient*(r==c ? 2:1) }
                }
            }
        }
        // Mirror the same upper triangle used by the static sparse assembler.
        for col in 0..<n { for row in 0..<col { stiffness[col+row*n]=stiffness[row+col*n];mass[col+row*n]=mass[row+col*n] } }
        guard stiffness.allSatisfy(\.isFinite),mass.allSatisfy(\.isFinite) else { throw EngineeringError.illConditioned("Modal matrix assembly overflowed.") }
        let sparse=upperSparse(stiffness,size:n)
        try SystemValidation.requirePositiveDiagonal(sparse.diag,label:"modal stiffness")
        let certificate=try LDLCertification.certifySPD(sparse,budget:budget,control:control,start:started)
        // No diagonal shift or artificial support is introduced for null modes.
        try control.checkCancelled();try checkTime(started)
        var vectors=stiffness,factoredMass=mass,values=[Double](repeating:0,count:n),nativeInfo:Int64=0
        let status=vectors.withUnsafeMutableBufferPointer { a in factoredMass.withUnsafeMutableBufferPointer { b in values.withUnsafeMutableBufferPointer { w in
            floe_modal_generalized_eigen(Int32(n),a.baseAddress,b.baseAddress,w.baseAddress,&nativeInfo)
        } } }
        try control.checkCancelled();try checkTime(started)
        guard status==0 else {
            switch status {
            case 1:throw EngineeringError.invalidInput("Invalid native modal dimensions.")
            case 2:throw EngineeringError.budgetExceeded("The native modal workspace could not be allocated.")
            case 4:throw EngineeringError.singular("The consistent mass matrix is not positive definite; check isolated/free nodes.")
            default:throw EngineeringError.illConditioned("Native generalized eigen solve failed (status\(status), info\(nativeInfo)).")
            }
        }
        guard values.allSatisfy({$0.isFinite&&$0>0}),vectors.allSatisfy(\.isFinite) else { throw EngineeringError.singular("The constrained eigenproblem contains a non-positive or non-finite mode.") }
        let acceptance=max(1e-10,min(1e-6,tolerance.relativeResidual*10))
        var modes:[EngineeringMode]=[],rawVectors:[[Double]]=[],maximumOrthogonality=0.0
        for mode in 0..<requestedModes {
            try control.checkCancelled();try checkTime(started)
            let vector=Array(vectors[(mode*n)..<((mode+1)*n)]),mv=multiply(mass,vector,size:n),kv=multiply(stiffness,vector,size:n),lambda=values[mode]
            let difference=zip(kv,mv).map { pair in pair.0-lambda*pair.1 }
            let residual=norm(difference)/max(norm(kv)+abs(lambda)*norm(mv),Double.leastNormalMagnitude)
            let normalizationError=abs(dot(vector,mv)-1)
            guard residual.isFinite,residual<=acceptance,normalizationError.isFinite,normalizationError<=acceptance else { throw EngineeringError.illConditioned("A modal eigenpair failed independent residual or mass-normalization read-back.") }
            for prior in rawVectors { maximumOrthogonality=max(maximumOrthogonality,abs(dot(prior,mv))) }
            guard maximumOrthogonality<=acceptance else { throw EngineeringError.illConditioned("Computed modes are not mass-orthogonal.") }
            rawVectors.append(vector)
            let phaseIndex=vector.indices.max { abs(vector[$0])<abs(vector[$1]) }!
            let sign=vector[phaseIndex]<0 ? -1.0:1.0
            var shape=[Vector3](repeating:.zero,count:mesh.nodes.count)
            for (i,dof) in free.enumerated() {
                let value=sign*vector[i],node=dof/3
                switch dof%3 { case 0:shape[node].x=value;case 1:shape[node].y=value;default:shape[node].z=value }
            }
            let largest=shape.map { hypot(hypot($0.x,$0.y),$0.z) }.max()!
            guard largest.isFinite,largest>0 else { throw EngineeringError.illConditioned("A mode has no finite displacement shape.") }
            let normalized=vector.map { sign*$0/largest },mm=multiply(mass,normalized,size:n),kk=multiply(stiffness,normalized,size:n)
            let generalizedMass=dot(normalized,mm),generalizedStiffness=dot(normalized,kk),frequency=sqrt(lambda)/(2*Double.pi)
            guard generalizedMass.isFinite,generalizedMass>0,generalizedStiffness.isFinite,generalizedStiffness>0,frequency.isFinite,frequency>0 else { throw EngineeringError.illConditioned("Modal mass, stiffness or frequency is not finite and positive.") }
            shape=shape.map { Vector3($0.x/largest,$0.y/largest,$0.z/largest) }
            modes.append(.init(index:mode,frequencyHz:frequency,angularFrequencySquaredPerSecondSquared:lambda,normalizedShape:shape,generalizedMassKg:generalizedMass,generalizedStiffnessNPerMeter:generalizedStiffness,relativeResidual:residual,massNormalizationError:normalizationError))
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let hash=SHA256.hash(data:try encoder.encode(self)).map { String(format:"%02x",$0) }.joined()
        return .init(modes:modes,freeDOFs:n,maximumMassOrthogonalityError:maximumOrthogonality,minimumStiffnessPivot:certificate.minPivot,wallSeconds:Date().timeIntervalSince(started),sourceHash:hash)
    }
    private func checkTime(_ started:Date) throws {
        guard Date().timeIntervalSince(started)<=budget.maxWallSeconds else { throw EngineeringError.budgetExceeded("Modal solve exceeded its wall-time budget.") }
    }
    private func upperSparse(_ a:[Double],size n:Int) -> SymmetricSparseMatrix {
        var rows=[0],columns:[Int]=[],entries:[Double]=[]
        for r in 0..<n { for c in (r+1)..<n where a[r+c*n] != 0 { columns.append(c);entries.append(a[r+c*n]) };rows.append(columns.count) }
        return .init(size:n,diag:(0..<n).map { a[$0+$0*n] },rowStart:rows,column:columns,value:entries)
    }
    private func multiply(_ a:[Double],_ x:[Double],size n:Int) -> [Double] {
        (0..<n).map { r in (0..<n).reduce(0.0) { $0+a[r+$1*n]*x[$1] } }
    }
    private func dot(_ x:[Double],_ y:[Double]) -> Double { zip(x,y).reduce(0.0) { $0+$1.0*$1.1 } }
    private func norm(_ x:[Double]) -> Double { x.reduce(0.0) { hypot($0,$1) } }
}
