// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Charts
import FloeBiologyCore

struct BiologyResultView:View {
    let run:BiologyRun
    let source:BiologyAsset?
    private func label(_ key:String)->String {
        let map:[String:String]=[
            "length":"字符数","GC_percent":"GC 比例（%）","aminoAcids":"氨基酸数","stops":"终止密码子","score":"比对得分","identity_percent":"一致性（%）",
            "atoms":"原子数","polymerAtoms":"聚合物原子数","residues":"残基数","chains":"链数","geometricGyration_A":"几何回转半径（Å）","distance_A":"距离（Å）","contacts":"接触对数",
            "objects":"对象数","threshold":"阈值","minimum":"最小值","maximum":"最大值","mean":"平均值","pixels":"像素数",
            "genes":"基因数","cells":"细胞数","zeroCells":"空细胞数","steps":"步数","finalTime":"结束时间","completeORFs":"完整阅读框数","clusters":"聚类数"
        ]
        let english:[String:String]=["length":"Length","GC_percent":"GC content (%)","aminoAcids":"Amino acids","stops":"Stop codons","score":"Alignment score","identity_percent":"Identity (%)","atoms":"Atoms","polymerAtoms":"Polymer atoms","residues":"Residues","chains":"Chains","geometricGyration_A":"Geometric radius (Å)","distance_A":"Distance (Å)","contacts":"Contacts","objects":"Objects","threshold":"Threshold","minimum":"Minimum","maximum":"Maximum","mean":"Mean","pixels":"Pixels","genes":"Genes","cells":"Cells","zeroCells":"Empty cells","steps":"Steps","finalTime":"End time","completeORFs":"Complete ORFs","clusters":"Clusters"]
        if key.hasPrefix("final_"){return biologyText("Final ","终值 · ")+String(key.dropFirst(6))}
        return biologyText(english[key] ?? key.replacingOccurrences(of:"_",with:" "),map[key] ?? key)
    }
    private func numeric(_ value:Double)->String {String(format:"%.6g",value)}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text(BiologyLabels.method(run.method)).font(.title3.weight(.semibold)).padding(.bottom,4)
                if let source,source.revision != run.assetRevision {
                    Label(biologyText("Result belongs to an earlier input revision.","结果对应较早的数据版本。"),systemImage:"clock.arrow.circlepath").foregroundStyle(.orange)
                }
                if let result=run.result {
                    VStack(spacing:0) {
                    ForEach(result.metrics.keys.sorted(),id:\.self){key in
                        LabeledContent{Text(numeric(result.metrics[key]!)).foregroundStyle(.primary).fontWeight(.medium).monospacedDigit()}label:{Text(label(key))}
                            .accessibilityElement(children:.combine)
                            .accessibilityLabel(label(key)).accessibilityValue(numeric(result.metrics[key]!))
                            .accessibilityIdentifier("biology.metric."+key).padding(.vertical,11)
                        if key != result.metrics.keys.sorted().last{Divider()}
                    }
                    }.padding(.horizontal,16).biologyCanvas()
                    if result.details["textEncoding"]=="base64 PNG",let bytes=Data(base64Encoded:result.text),let image=UIImage(data:bytes) {
                        Image(uiImage:image).resizable().interpolation(.none).scaledToFit().frame(maxHeight:400)
                            .accessibilityLabel(biologyText("Measured object overlay","测量对象叠加图"))
                    } else if !result.text.isEmpty {
                        DisclosureGroup(biologyText("Output text","输出文本")) {
                            Text(String(result.text.prefix(200_000))).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                            if result.text.count>200_000 {Text(biologyText("Export to retain the full output.","导出可保留完整输出。")).font(.caption)}
                        }
                    }
                    if !result.rows.isEmpty {
                        if result.columns.first=="time",result.columns.count>1 {
                            if let source,case .biochemicalNetwork(let network)=source.payload {
                                BiologyTimeCoursePlot(result:result,timeUnit:network.timeUnit,amountUnit:network.amountUnit)
                            }else{BiologyTimeCoursePlot(result:result,timeUnit:biologyText("Time","时间"),amountUnit:biologyText("Value","数值"))}
                        }
                        if result.columns.prefix(2)==["PC1","PC2"] || result.columns.prefix(2)==["UMAP1","UMAP2"] {
                            Chart(Array(result.rows.enumerated()),id:\.offset){_,row in
                                if row.count>=2 {PointMark(x:.value(result.columns[0],row[0]),y:.value(result.columns[1],row[1]))}
                            }.chartXAxisLabel(result.columns[0]).chartYAxisLabel(result.columns[1]).foregroundStyle(.teal).frame(height:260).padding(16).biologyCanvas()
                        }
                        ScrollView(.horizontal) {
                            Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:8) {
                                GridRow {
                                    Text(biologyText("Item","项目")).bold()
                                    ForEach(Array(result.columns.enumerated()),id:\.offset){_,name in Text(label(name)).fontWeight(.semibold).lineLimit(2)}
                                }
                                ForEach(Array(result.rows.prefix(100).enumerated()),id:\.offset){i,row in
                                    GridRow {
                                        Text(result.rowNames.indices.contains(i) ? result.rowNames[i]:String(i+1))
                                        ForEach(Array(row.enumerated()),id:\.offset){_,value in Text(numeric(value)).monospacedDigit()}
                                    }
                                }
                            }.font(.subheadline).padding(16).biologyCanvas()
                        }
                        if result.rows.count>100 {Text(biologyText("Showing the first 100 rows. Export includes the complete table.","显示前 100 行，导出包含完整表格。")).font(.caption).foregroundStyle(.secondary)}
                    }
                    DisclosureGroup(biologyText("Method and provenance","方法与来源")) {
                        LabeledContent(biologyText("Execution location","执行位置"),value:run.environmentID)
                        LabeledContent(biologyText("Engine","引擎"),value:run.engineVersion)
                        LabeledContent(biologyText("Input revision","输入版本"),value:String(run.assetRevision))
                        Text(run.inputDigest).font(.caption.monospaced()).textSelection(.enabled)
                        ForEach(result.details.keys.sorted(),id:\.self){key in LabeledContent(key,value:result.details[key]!).font(.caption)}
                    }
                } else if run.isActive {ProgressView(biologyText("Calculating…","正在计算…"))}
                else if let error=run.error {Text(error).foregroundStyle(.red)}
                else {Text(run.status.rawValue)}
            }.padding(BiologyStyle.spacing).frame(maxWidth:BiologyStyle.contentWidth).frame(maxWidth:.infinity,alignment:.top)
        }.background(BiologyStyle.background).accessibilityIdentifier("biology.resultView")
    }
}
struct BiologyTimeCoursePlot:View {
    let result:BiologyAnalysisResult
    let timeUnit:String
    let amountUnit:String
    private var series:[String]{Array(result.columns.dropFirst().prefix(12))}
    private var sampleIndices:[Int] {
        guard !result.rows.isEmpty else{return []}
        let budget=max(2,6000/max(1,series.count)),step=max(1,Int(ceil(Double(result.rows.count)/Double(budget))))
        var indices=Array(Swift.stride(from:0,to:result.rows.count,by:step))
        if indices.last != result.rows.count-1{indices.append(result.rows.count-1)}
        return indices
    }
    var body:some View {
        let samples=sampleIndices,series=series
        VStack(alignment:.leading,spacing:16){
            Text(biologyText("Time course","时间过程")).font(.headline)
            Chart {
                ForEach(Array(series.enumerated()),id:\.offset){column,name in
                    ForEach(samples,id:\.self){index in
                        let row=result.rows[index]
                        if row.count>column+1{LineMark(x:.value("Time",row[0]),y:.value("Amount",row[column+1])).foregroundStyle(by:.value("Species",name))}
                    }
                }
            }.chartXAxisLabel(timeUnit).chartYAxisLabel(amountUnit).chartLegend(position:.bottom,alignment:.leading).frame(height:240)
            if series.count<result.columns.count-1 || samples.count<result.rows.count {
                Text(biologyText("Chart preview: up to 12 series with sampled time points. Export includes the full results.","曲线预览最多显示 12 条曲线并按需抽样时间点，导出包含完整结果。")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).biologyCanvas().accessibilityIdentifier("biology.timeCoursePlot")
    }
}
struct BiologySequenceEditor:View {
    let model:BiologyWorkbenchModel
    let asset:BiologyAsset
    let recordIndex:Int
    @Environment(\.dismiss) private var dismiss
    @State private var start=1
    @State private var end=1
    @State private var draft=""
    @State private var loadedStart=0
    @State private var loadedEnd=0
    @State private var error:String?
    @State private var saving=false
    private var record:SequenceRecord? {if case .sequence(let records)=asset.payload,records.indices.contains(recordIndex){return records[recordIndex]};return nil}
    var body:some View {
        NavigationStack {
            Form {
                if let record {
                    Section(biologyText("Edit range · 1-based inclusive","编辑范围 · 从 1 开始的闭区间")) {
                        HStack(alignment:.top,spacing:16){
                            TextField(biologyText("Start","起点"),value:$start,format:.number).keyboardType(.numberPad).biologyNamedInput(biologyText("Start","起点"))
                            TextField(biologyText("End","终点"),value:$end,format:.number).keyboardType(.numberPad).biologyNamedInput(biologyText("End","终点"))
                        }
                        Button(biologyText("Load range","加载范围")){load(record)}.frame(minHeight:44)
                    }
                    Section {
                        Button(biologyText("Clear replacement","清空替换内容"),role:.destructive){draft=""}.frame(minHeight:44).accessibilityIdentifier("biology.clearSequenceDraft")
                        TextEditor(text:$draft).font(.system(.body,design:.monospaced)).frame(minHeight:240).biologyInputSurface().autocorrectionDisabled().textInputAutocapitalization(.characters).accessibilityIdentifier("biology.sequenceDraft")
                    } footer:{Text(biologyText("Edit up to 20,000 symbols per range. Overlapping annotations and quality measurements are invalidated; originals are retained.","每次可编辑最多 20,000 个字符。相交注释和测量质量值会失效，原件保留。"))}
                    if let error {Text(error).foregroundStyle(.red)}
                }
            }
            .textFieldStyle(.roundedBorder).buttonStyle(BiologyControlButtonStyle(expands:true)).navigationTitle(biologyText("Edit sequence","编辑序列")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(biologyText("Cancel","取消")){dismiss()}.disabled(saving)}
                ToolbarItem(placement:.confirmationAction){Button(biologyText("Save","保存")){Task{await save()}}.disabled(saving).accessibilityIdentifier("biology.saveSequence")}
            }
            .task {if let record {end=min(record.sequence.count,20_000);load(record)}}
            .interactiveDismissDisabled(saving)
        }
    }
    private func load(_ record:SequenceRecord) {
        guard start>=1,end>=start,end<=record.sequence.count,end-start<20_000 else {error=biologyText("Choose a valid range of up to 20,000 symbols.","请选择最多 20,000 个字符的有效范围。");return}
        loadedStart=start-1;loadedEnd=end
        let chars=Array(record.sequence);draft=String(chars[loadedStart..<loadedEnd]);error=nil
    }
    private func save() async {
        saving=true;defer{saving=false}
        do {
            try await model.service.editSequence(model.projectID,assetID:asset.id,expectedAssetRevision:asset.revision,record:recordIndex,start:loadedStart,end:loadedEnd,replacement:draft)
            model.rememberUndo(asset)
            await model.refresh();dismiss()
        } catch {self.error=error.localizedDescription}
    }
}
struct BiologyAnnotationEditor:View {
    let model:BiologyWorkbenchModel
    let asset:BiologyAsset
    let recordIndex:Int
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var start=1
    @State private var end=1
    @State private var reverse=false
    @State private var error:String?
    var body:some View {
        NavigationStack {
            Form {
                TextField(biologyText("Feature name","注释名称"),text:$name).biologyNamedInput(biologyText("Feature name","注释名称"))
                HStack(alignment:.top,spacing:16){
                    TextField(biologyText("Start · 1-based","起点 · 从 1 开始"),value:$start,format:.number).biologyNamedInput(biologyText("Start · 1-based","起点 · 从 1 开始"))
                    TextField(biologyText("End · inclusive","终点 · 包含"),value:$end,format:.number).biologyNamedInput(biologyText("End · inclusive","终点 · 包含"))
                }
                Toggle(biologyText("Reverse strand","反向链"),isOn:$reverse)
                if let error {Text(error).foregroundStyle(.red)}
            }.textFieldStyle(.roundedBorder).buttonStyle(BiologyControlButtonStyle(expands:true)).navigationTitle(biologyText("Add annotation","添加注释")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(biologyText("Cancel","取消")){dismiss()}}
                ToolbarItem(placement:.confirmationAction){Button(biologyText("Save","保存")){Task{
                    do {
                        guard case .sequence(var records)=asset.payload,records.indices.contains(recordIndex),!name.isEmpty,start>0,end>=start,end<=records[recordIndex].sequence.count else {throw BiologyError.invalid(biologyText("Check the feature name and range.","请检查注释名称和范围。"))}
                        records[recordIndex].annotations.append(.init(name:name,start:start-1,end:end,strand:reverse ? -1:1))
                        try await model.savePayload(.sequence(records),for:asset);dismiss()
                    }catch{self.error=error.localizedDescription}
                }}}
            }
        }
    }
}
struct BiologyNetworkEditor:View {
    let model:BiologyWorkbenchModel
    let asset:BiologyAsset
    @Environment(\.dismiss) private var dismiss
    @State private var network:BiochemicalNetwork
    @State private var json=""
    @State private var error:String?
    init(model:BiologyWorkbenchModel,asset:BiologyAsset,network:BiochemicalNetwork) {self.model=model;self.asset=asset;_network=State(initialValue:network)}
    var body:some View {
        NavigationStack {
            Form {
                Section(biologyText("Initial amounts","初始量")) {
                    ForEach(network.species.indices,id:\.self){i in TextField(network.species[i].id,value:$network.species[i].initialAmount,format:.number).accessibilityIdentifier("biology.species."+network.species[i].id).biologyNamedInput(network.species[i].id)}
                    Button(biologyText("Add species","添加物种")) {
                        var n=network.species.count+1;while network.species.contains(where:{$0.id=="S\(n)"}){n+=1}
                        network.species.append(.init(id:"S\(n)",initialAmount:0))
                    }
                }
                Section(biologyText("Reaction rates","反应速率")) {
                    ForEach(network.reactions.indices,id:\.self){i in TextField(network.reactions[i].id,value:$network.reactions[i].rateConstant,format:.number).accessibilityIdentifier("biology.rate."+network.reactions[i].id).biologyNamedInput(network.reactions[i].id)}
                }
                Section(biologyText("Units","单位")) {
                    TextField(biologyText("Time unit","时间单位"),text:$network.timeUnit).biologyNamedInput(biologyText("Time unit","时间单位"))
                    TextField(biologyText("Amount unit","量的单位"),text:$network.amountUnit).biologyNamedInput(biologyText("Amount unit","量的单位"))
                }
                DisclosureGroup(biologyText("Edit complete model","编辑完整模型")) {
                    Button(biologyText("Load current model","载入当前模型")) {
                        do{let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];json=String(decoding:try e.encode(network),as:UTF8.self)}catch{self.error=error.localizedDescription}
                    }
                    TextEditor(text:$json).font(.system(.caption,design:.monospaced)).frame(minHeight:240).biologyInputSurface().autocorrectionDisabled()
                    Button(biologyText("Validate and apply model","校验并应用模型")) {
                        do {let value=try JSONDecoder().decode(BiochemicalNetwork.self,from:Data(json.utf8));try value.validate();network=value;error=nil}
                        catch{self.error=error.localizedDescription}
                    }
                }
                if let error {Text(error).foregroundStyle(.red)}
            }.textFieldStyle(.roundedBorder).buttonStyle(BiologyControlButtonStyle(expands:true)).navigationTitle(biologyText("Edit network","编辑网络")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(biologyText("Cancel","取消")){dismiss()}}
                ToolbarItem(placement:.confirmationAction){Button(biologyText("Save","保存")){Task{
                    do{try network.validate();try await model.savePayload(.biochemicalNetwork(network),for:asset);dismiss()}
                    catch{self.error=error.localizedDescription}
                }}.accessibilityIdentifier("biology.saveNetwork")}
            }
        }
    }
}
#endif
