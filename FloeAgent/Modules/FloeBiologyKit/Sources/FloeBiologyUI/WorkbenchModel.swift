// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Observation
import UniformTypeIdentifiers
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologySamples

public func biologyText(_ english:String,_ chinese:String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese:english
}
public struct BiologyAIContext: Sendable, Identifiable {
    public let id=UUID()
    public var projectID:UUID
    public var assetID:UUID?
    public var assetRevision:UInt64?
    public var selectedRunID:UUID?
}
public typealias BiologyAIHandler = @MainActor @Sendable (String,BiologyAIContext) async throws -> String
public typealias BiologyNotesHandler = @MainActor @Sendable (UUID,UUID?,UUID?) async throws -> Void

public enum BiologyLabels {
    public static func kind(_ kind:BiologyAssetKind) -> String {
        switch kind {
        case .sequence:biologyText("Sequences","序列")
        case .proteinStructure:biologyText("Protein structure","蛋白结构")
        case .microscopyImage:biologyText("Microscopy","显微图像")
        case .expressionMatrix:biologyText("Expression matrix","表达矩阵")
        case .biochemicalNetwork:biologyText("Reaction network","反应网络")
        case .externalDataset:biologyText("Scientific dataset","科学数据")
        }
    }
    public static func icon(_ kind:BiologyAssetKind) -> String {
        switch kind {
        case .sequence:"text.alignleft"
        case .proteinStructure:"point.3.connected.trianglepath.dotted"
        case .microscopyImage:"viewfinder"
        case .expressionMatrix:"tablecells"
        case .biochemicalNetwork:"point.3.filled.connected.trianglepath.dotted"
        case .externalDataset:"doc"
        }
    }
    public static func method(_ name:String) -> String {
        let map:[String:(String,String)] = [
            "sequence.stats":("Sequence statistics","序列统计"),"sequence.reverseComplement":("Reverse complement","反向互补"),
            "sequence.translate":("Translate sequence","翻译序列"),"sequence.align.global":("Global alignment","全局比对"),
            "sequence.align.local":("Local alignment","局部比对"),"sequence.orfs":("Find complete ORFs","查找完整阅读框"),
            "structure.geometry":("Structure geometry","结构统计"),"structure.contacts":("Atomic contacts","原子接触"),
            "structure.distance":("Measure distance","测量距离"),"image.segment":("Segment and count","分割与计数"),
            "image.statistics":("Image statistics","图像统计"),"matrix.qc":("Quality control","质量控制"),
            "matrix.normalize":("Normalize library size","按细胞标准化"),"matrix.log1p":("Log transform","对数变换"),
            "matrix.geneStatistics":("Gene statistics","基因统计"),"network.simulate":("Simulate time course","模拟时间过程"),
            "network.sweep":("Compare rate constants","比较反应速率"),
            "seq.parse":("Read annotations","读取注释"),"seq.stats":("Sequence statistics","序列统计"),
            "seq.translate":("Translate sequence","翻译序列"),"seq.reverseComplement":("Reverse complement","反向互补"),
            "seq.export":("Export sequence","导出序列"),"seq.align.global":("Global alignment","全局比对"),"seq.align.local":("Local alignment","局部比对"),"seq.phylogeny":("Build sequence tree","建立序列树"),
            "struct.parse":("Read structure","读取结构"),"struct.select":("Select structure","选择结构"),"struct.geometry":("Structure geometry","结构统计"),"struct.contacts":("Atomic contacts","原子接触"),"struct.rmsd":("Superpose structures","叠合结构"),
            "micro.import":("Read microscopy dataset","读取显微数据"),"micro.segment":("Segment and measure","分割与测量"),"micro.overlay":("Create label overlay","生成标记叠加图"),
            "omics.import":("Read expression dataset","读取表达数据"),"omics.export":("Export expression data","导出表达数据"),"omics.qc":("Quality control","质量控制"),"omics.normalize":("Normalize counts","标准化计数"),"omics.pca":("Principal components","主成分分析"),"omics.cluster":("Cluster cells","细胞聚类"),"omics.embedding":("UMAP embedding","UMAP 降维"),"omics.diffexp":("Compare expression groups","比较表达分组"),
            "net.simulate":("Adaptive time course","自适应时间过程"),"net.sweep":("Parameter comparison","参数比较"),"net.sbml.import":("Read SBML model","读取 SBML 模型"),"net.sbml.export":("Export SBML model","导出 SBML 模型"),
            "net.sbml.simulate":("Simulate SBML model","模拟 SBML 模型"),"net.sbml.sweep":("Compare SBML parameters","比较 SBML 参数"),
            "micro.tile":("Read image region","读取图像区域"),"micro.series":("Inspect image series","查看图像序列"),
            "tree.inspect":("Tree statistics","系统树统计"),"volume.statistics":("Density statistics","密度统计"),"volume.slice":("Density slice","密度切片"),"volume.isosurface":("Density surface","密度等值面")
        ]
        if let value=map[name] {return biologyText(value.0,value.1)}
        return name
    }
}
@MainActor @Observable public final class BiologyWorkbenchModel {
    public let service:BiologyService
    public let projectID:UUID
    public var project:BiologyProject?
    public var selectedID:UUID?
    public var selectedRunID:UUID?
    public var error:String?
    public var busy=false
    public var notice:String?
    public var methods:[String:[String]] = [:]
    public var selected:BiologyAsset? {project?.assets.first{$0.id==selectedID}}
    public var run:BiologyRun? {
        if let selectedRunID,let r=project?.runs.first(where:{$0.id==selectedRunID}) {return r}
        return project?.runs.last{$0.assetID==selectedID}
    }
    public var activeRuns:[BiologyRun] {project?.runs.filter(\.isActive) ?? []}
    public var runSource:BiologyAsset? {run.flatMap{r in project?.assets.first{$0.id==r.assetID}}}
    public var hasPinnedResultForSelection:Bool {
        guard let selectedRunID,let run=project?.runs.first(where:{$0.id==selectedRunID}) else{return false}
        return run.assetID==selectedID || (selectedID==nil && !(project?.assets.contains{$0.id==run.assetID} ?? false))
    }
    @ObservationIgnored private var refreshGeneration:UInt64=0
    private var undo:[UUID:[BiologyAssetPayload]] = [:]
    private var redo:[UUID:[BiologyAssetPayload]] = [:]
    public var canUndo:Bool {selectedID.map{!(undo[$0] ?? []).isEmpty} ?? false}
    public var canRedo:Bool {selectedID.map{!(redo[$0] ?? []).isEmpty} ?? false}
    public init(service:BiologyService,projectID:UUID) {self.service=service;self.projectID=projectID}
    public func refresh() async {
        refreshGeneration &+= 1
        let generation=refreshGeneration
        do {
            let latest=try await service.project(projectID)
            guard !Task.isCancelled,generation==refreshGeneration else{return}
            if let project,project.revision>latest.revision {return}
            project=latest
            if !latest.assets.contains(where:{$0.id==selectedID}) {
                // A saved result can outlive its source. Keep its source nil,
                // never label it with an unrelated dataset.
                if let selectedRunID,let pinned=latest.runs.first(where:{$0.id==selectedRunID}),
                   !latest.assets.contains(where:{$0.id==pinned.assetID}) {selectedID=nil}
                else {selectedID=latest.activeAssetID ?? latest.assets.first?.id}
            }
            if selectedRunID != nil,!hasPinnedResultForSelection {selectedRunID=nil}
            let asset=selected
            let offered:[String:[String]]=if let asset {await service.capabilities(for:asset)} else {[:]}
            guard !Task.isCancelled,generation==refreshGeneration,selectedID==asset?.id else{return}
            methods=offered
        } catch {
            if !Task.isCancelled,generation==refreshGeneration {self.error=error.localizedDescription}
        }
    }
    /// Explicit history selection follows its real input, independently of a
    /// background tool's persisted activeAssetID.
    @discardableResult public func selectRun(_ id:UUID)->Bool {
        guard let run=project?.runs.first(where:{$0.id==id}) else{return false}
        selectedID=project?.assets.first(where:{$0.id==run.assetID})?.id
        selectedRunID=id
        return true
    }
    public func perform(_ operation:@MainActor () async throws -> Void) async {
        busy=true;defer{busy=false}
        do {try await operation();error=nil;await refresh()} catch {self.error=error.localizedDescription}
    }
    public func importData(title:String,format:String,data:Data,provenance:[String:String] = [:]) async {
        await perform {
            let a=try await service.importAsset(projectID,title:title,format:format,data:data,provenance:provenance)
            selectedID=a.id;selectedRunID=nil
        }
    }
    public func addSample(_ sample:BiologySampleID) async {
        await perform {
            let info=try BiologySamples.provenance(for:sample)
            let format:String
            switch sample {
            case .ubiquitinPDB:format="pdb"
            case .ubiquitinMMCIF:format="cif"
            case .sequenceComparison:format="fasta"
            case .expressionCounts:format="csv"
            case .microscopy:format="json"
            case .microscopyPGM:format="pgm"
            case .reactionNetwork:format="json"
            case .phylogeneticTree:format="newick"
            case .densityVolume:format="mrc"
            }
            let a=try await service.importAsset(projectID,title:Self.sampleTitle(sample),format:format,data:BiologySamples.data(for:sample),provenance:["origin":info.origin,"license":info.license,"sha256":info.sha256])
            selectedID=a.id;selectedRunID=nil
        }
    }
    public static func sampleTitle(_ s:BiologySampleID) -> String {
        switch s {
        case .ubiquitinPDB:biologyText("Ubiquitin · PDB 1UBQ","泛素结构 · PDB 1UBQ")
        case .ubiquitinMMCIF:biologyText("Ubiquitin · mmCIF","泛素结构 · mmCIF")
        case .sequenceComparison:biologyText("Sequence comparison · synthetic","序列比较 · 合成示例")
        case .expressionCounts:biologyText("Expression matrix · synthetic","表达矩阵 · 合成示例")
        case .microscopy,.microscopyPGM:biologyText("Microscopy · synthetic","显微图像 · 合成示例")
        case .reactionNetwork:biologyText("Reaction network · synthetic","反应网络 · 合成示例")
        case .phylogeneticTree:biologyText("Branching tree · synthetic","分支树 · 合成示例")
        case .densityVolume:biologyText("Density volume · synthetic","密度体 · 合成示例")
        }
    }
    public func start(method:String,options:JSONValue = .object([:]),environmentID:String = "native.local",owner:BiologyExecutionOwner? = nil) async {
        guard let asset=selected else {return}
        await perform {
            let r=try await service.start(projectID,assetID:asset.id,expectedAssetRevision:asset.revision,method:method,options:options,environmentID:environmentID,owner:owner)
            selectedRunID=r.id
        }
    }
    public func savePayload(_ payload:BiologyAssetPayload,for asset:BiologyAsset) async throws {
        try await service.replacePayload(projectID,assetID:asset.id,expectedAssetRevision:asset.revision,payload:payload)
        rememberUndo(asset)
        await refresh()
    }
    public func rememberUndo(_ asset:BiologyAsset) {
        undo[asset.id,default:[]].append(asset.payload)
        if undo[asset.id]!.count>16 {undo[asset.id]!.removeFirst()}
        redo[asset.id]=[]
    }
    /// A deleted dataset has no live payload stack; removal recovery goes
    /// through the project's durable version history instead.
    public func clearUndo(for assetID:UUID) {
        undo.removeValue(forKey:assetID);redo.removeValue(forKey:assetID)
    }
    public func undoEdit() async {
        guard let a=selected,let payload=undo[a.id]?.last else {return}
        await perform {
            try await service.replacePayload(projectID,assetID:a.id,expectedAssetRevision:a.revision,payload:payload)
            undo[a.id]?.removeLast();redo[a.id,default:[]].append(a.payload)
        }
    }
    public func redoEdit() async {
        guard let a=selected,let payload=redo[a.id]?.last else {return}
        await perform {
            try await service.replacePayload(projectID,assetID:a.id,expectedAssetRevision:a.revision,payload:payload)
            redo[a.id]?.removeLast();undo[a.id,default:[]].append(a.payload)
        }
    }
}
public struct BiologyFileDocument:FileDocument {
    public static var readableContentTypes:[UTType] { [.data] }
    public var data:Data
    public init(data:Data) {self.data=data}
    public init(configuration:ReadConfiguration) throws {data=configuration.file.regularFileContents ?? Data()}
    public func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper {FileWrapper(regularFileWithContents:data)}
}
#endif
