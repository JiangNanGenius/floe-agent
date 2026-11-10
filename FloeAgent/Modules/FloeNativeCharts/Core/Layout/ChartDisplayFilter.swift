// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ChartFilterKey: Hashable, Sendable {
    case series(String), record(String), node(String), facet(String), matrixRow(ChartCoordinate)
}
public struct ChartFilterOption: Identifiable, Sendable, Equatable {
    public var id:ChartFilterKey
    public var label:String
    public init(id:ChartFilterKey,label:String){self.id=id;self.label=label}
}
public struct ChartDisplaySnapshot: Sendable {
    public let chart:PreparedChart
    public let source:PreparedChart
    public let visibleRecordIDs:Set<ChartRecordID>?
    public let isFiltered:Bool
    public func scene(width:Double = 960,height:Double = 640,title:String? = nil) throws -> NativeChartScene {
        let scene=try NativeChartSceneBuilder.build(chart,width:width,height:height,title:title)
        var primitives=scene.layout.primitives,hits=scene.hits
        if let visibleRecordIDs {
            primitives=primitives.filter{$0.sourceIDs.isEmpty || !$0.sourceIDs.allSatisfy{!visibleRecordIDs.contains($0)}}
            let ids=Set(primitives.map(\.id));hits=hits.filter{ids.contains($0.primitiveID)}
        }
        let layout=try ChartLayout(primitives:primitives,hits:hits.map{.init(sourceIDs:$0.sourceIDs,bounds:$0.bounds)},for:chart)
        let note=isFiltered ? ["Filtered view; original source data is retained."]:[]
        return .init(frame:scene.frame,layout:layout,hits:hits,legend:scene.legend,notes:scene.notes+note)
    }
}

public enum ChartDisplayFilter {
    public static func options(for chart:PreparedChart)->[ChartFilterOption] {
        func row(_ id:String,_ label:String)->ChartFilterOption{.init(id:.record(id),label:label)}
        switch chart.document.data {
        case .cartesian(let values):
            var seen:Set<String> = [];let groups=values.map{$0.seriesID ?? ""}.filter{seen.insert($0).inserted}
            if groups.count>1{return groups.map{id in .init(id:.series(id),label:chart.document.series.first{$0.id==id}?.name ?? id)}}
            return values.map{row($0.id,$0.label ?? label($0.x))}
        case .parts(let values):return values.map{row($0.id,$0.label)}
        case .samples(let groups):return groups.map{.init(id:.series($0.id),label:$0.label ?? $0.id)}
        case .bins(let values):return values.map{row($0.id,"\($0.lower)…\($0.upper)")}
        case .boxSummary(let values):return values.map{row($0.id,$0.label ?? $0.id)}
        case .density(let groups):return groups.map{.init(id:.series($0.id),label:$0.id)}
        case .intervals(let values):return values.map{row($0.id,label($0.x))}
        case .ohlc(let values):return values.map{row($0.id,$0.time)}
        case .volume(let values):return values.map{row($0.id,$0.time)}
        case .matrix(let values):var seen:Set<ChartCoordinate> = [];return values.filter{seen.insert($0.row).inserted}.map{.init(id:.matrixRow($0.row),label:label($0.row))}
        case .dimensions(let data):return data.records.map{row($0.id,$0.label ?? $0.id)}
        case .polar(let values):return values.map{row($0.id,String($0.angle))}
        case .hierarchy(let nodes):let parents=Set(nodes.compactMap(\.parentID));return nodes.filter{!parents.contains($0.id)}.map{.init(id:.node($0.id),label:$0.label)}
        case .graph(let data):return data.nodes.map{.init(id:.node($0.id),label:$0.label)}
        case .flow(let data):return data.nodes.map{.init(id:.node($0.id),label:$0.label)}
        case .flowMatrix(let data):return data.nodes.map{.init(id:.node($0.id),label:$0.label)}
        case .waterfall(let values):return values.map{row($0.id,$0.label)}
        case .stages(let values):return values.map{row($0.id,$0.label)}
        case .events(let values):return values.map{row($0.id,$0.label)}
        case .tasks(let values):return values.map{row($0.id,$0.label)}
        case .calendar(let values):return values.map{row($0.id,label($0.day))}
        case .facets(let values):return values.map{.init(id:.facet($0.id),label:$0.document.title ?? $0.id)}
        }
    }
    public static func apply(_ selected:Set<ChartFilterKey>?,to source:PreparedChart)->ChartDisplaySnapshot? {
        let options=options(for:source),all=Set(options.map(\.id)),chosen=selected ?? all
        guard !chosen.isEmpty else{return nil}
        if chosen==all{return .init(chart:source,source:source,visibleRecordIDs:nil,isFiltered:false)}
        var d=source.document;var mask:Set<ChartRecordID>?
        func row(_ id:String)->Bool{chosen.contains(.record(id))}
        switch d.data {
        case .cartesian(let values):
            let seriesMode=options.contains{if case .series=$0.id{return true};return false}
            let rows=values.filter{seriesMode ? chosen.contains(.series($0.seriesID ?? "")):row($0.id)}
            guard !rows.isEmpty else{return nil};d.data = .cartesian(rows)
            let ids=Set(rows.compactMap(\.seriesID));if !d.series.isEmpty{d.series=d.series.filter{ids.contains($0.id) || (ids.isEmpty && d.series.count==1)}}
        case .parts(let values):let v=values.filter{row($0.id)};guard v.contains(where:{$0.value>0}) else{return nil};d.data = .parts(v)
        case .samples(let values):let v=values.filter{chosen.contains(.series($0.id))};guard !v.isEmpty else{return nil};d.data = .samples(v)
        case .bins(let values):let v=values.filter{row($0.id)};guard v.contains(where:{$0.count>0}) else{return nil};d.data = .bins(v)
        case .boxSummary(let values):let v=values.filter{row($0.id)};guard !v.isEmpty else{return nil};d.data = .boxSummary(v)
        case .density(let values):let v=values.filter{chosen.contains(.series($0.id))};guard !v.isEmpty else{return nil};d.data = .density(v)
        case .intervals(let values):let v=values.filter{row($0.id)};guard !v.isEmpty else{return nil};d.data = .intervals(v)
        case .ohlc(let values):
            let v=values.filter{row($0.id)};guard !v.isEmpty else{return nil}
            if d.type == .priceVolume{mask=Set(source.recordIDs.filter{row($0.id)})}else{d.data = .ohlc(v)}
        case .volume(let values):let v=values.filter{row($0.id)};guard !v.isEmpty else{return nil};d.data = .volume(v)
        case .matrix(let values):let v=values.filter{chosen.contains(.matrixRow($0.row))};guard !v.isEmpty else{return nil};d.data = .matrix(v)
        case .dimensions(var data):data.records=data.records.filter{row($0.id)};guard !data.records.isEmpty else{return nil};d.data = .dimensions(data)
        case .polar(let values):let v=values.filter{row($0.id)};guard !v.isEmpty else{return nil};d.data = .polar(v)
        case .hierarchy(let nodes):
            let byID=Dictionary(uniqueKeysWithValues:nodes.map{($0.id,$0)});var retained:Set<String> = []
            for node in nodes where chosen.contains(.node(node.id)){var cursor:String?=node.id;while let id=cursor{retained.insert(id);cursor=byID[id]?.parentID}}
            guard !retained.isEmpty else{return nil}
            let parents=Set(nodes.compactMap(\.parentID));let v=nodes.filter{retained.contains($0.id)}.map{node in var copy=node;if parents.contains(node.id){copy.value=nil};return copy}
            if d.type != .tree && !v.contains(where:{!parents.contains($0.id) && ($0.value ?? 0)>0}){return nil};d.data = .hierarchy(v)
        case .graph(var data):data.nodes=data.nodes.filter{chosen.contains(.node($0.id))};let ids=Set(data.nodes.map(\.id));data.edges=data.edges.filter{ids.contains($0.source) && ids.contains($0.target)};guard !data.nodes.isEmpty else{return nil};d.data = .graph(data)
        case .flow(var data):data.nodes=data.nodes.filter{chosen.contains(.node($0.id))};let ids=Set(data.nodes.map(\.id));data.links=data.links.filter{ids.contains($0.source) && ids.contains($0.target)};guard data.links.contains(where:{$0.value>0}) else{return nil};d.data = .flow(data)
        case .flowMatrix(let data):let indexes=data.nodes.indices.filter{chosen.contains(.node(data.nodes[$0].id))};let values=indexes.map{i in indexes.map{data.values[i][$0]}};guard values.flatMap({$0}).contains(where:{$0>0}) else{return nil};d.data = .flowMatrix(.init(nodes:indexes.map{data.nodes[$0]},values:values,directed:data.directed))
        case .waterfall:mask=Set(source.recordIDs.filter{row($0.id)}) // Retain the original cumulative context.
        case .stages(let values):let v=values.filter{row($0.id)};guard v.contains(where:{$0.value>0}) else{return nil};d.data = .stages(v)
        case .events(let values):let v=values.filter{row($0.id)};guard !v.isEmpty else{return nil};d.data = .events(v)
        case .tasks(let values):let v=values.filter{row($0.id)};let ids=Set(v.map(\.id));guard !v.isEmpty else{return nil};d.data = .tasks(v.map{task in var copy=task;copy.dependsOn=task.dependsOn?.filter{ids.contains($0)};return copy})
        case .calendar(let values):let v=values.filter{row($0.id)};guard !v.isEmpty else{return nil};d.data = .calendar(v)
        case .facets(let values):let v=values.filter{chosen.contains(.facet($0.id))};guard !v.isEmpty else{return nil};d.data = .facets(v)
        }
        // This is an ephemeral display derivation, never a new stored document.
        // A filtered combo may contain one mark; parent weights are recomputed
        // from retained leaves. Source data/authority/identity remain separate.
        let view=PreparedChart(document:d,descriptor:source.descriptor,recordIDs:source.recordIDs,inputRecordCount:source.inputRecordCount,warnings:source.warnings)
        return .init(chart:view,source:source,visibleRecordIDs:mask,isFiltered:true)
    }
    static func label(_ coordinate:ChartCoordinate)->String{switch coordinate{case .number(let v):String(v);case .category(let v),.instant(let v),.localDate(let v):v}}
}
