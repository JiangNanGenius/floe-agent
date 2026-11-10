// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartSceneBuilder {
    mutating func relationships() throws {
        switch chart.document.data {
        case .hierarchy(let nodes):try hierarchy(nodes)
        case .graph(let graph):try network(graph)
        case .flow(let flow):try sankey(flow)
        case .flowMatrix(let matrix):try chord(matrix)
        case .waterfall(let steps):try waterfall(steps)
        case .stages(let stages):
            let maxValue=stages.map(\.value).max()!,height=plot.height/Double(stages.count)
            for (i,stage) in stages.enumerated() {
                let half=plot.width*0.42*stage.value/maxValue,next=plot.width*0.42*(i+1<stages.count ? stages[i+1].value:stage.value)/maxValue
                let y=plot.y+Double(i)*height,cx=plot.x+plot.width/2
                let points=[ChartPoint(x:cx-half,y:y),.init(x:cx+half,y:y),.init(x:cx+next,y:y+height*0.9),.init(x:cx-next,y:y+height*0.9)]
                add(.polygon(points),style:"series.\(i).soft",sources:[source(stage.id)],bounds:bounding(points),readout:valueReadout(stage.label,[("value",stage.value)]))
                text(stage.label+" · "+number(stage.value),x:cx-70,y:y+height*0.35,width:180)
            }
        default:throw ChartIssue(path:"layout",problem:"relationship payload mismatch")
        }
    }
    mutating func hierarchy(_ nodes:[HierarchyNode]) throws {
        let children=Dictionary(grouping:nodes.filter{$0.parentID != nil},by:{$0.parentID!}),lookup=Dictionary(uniqueKeysWithValues:nodes.map{($0.id,$0)})
        let roots=nodes.filter{$0.parentID == nil};var weights:[String:Double] = [:],depths:[String:Int] = [:]
        func weight(_ node:HierarchyNode)->Double {if let values=children[node.id],!values.isEmpty{return values.reduce(0){$0+weight($1)}};return node.value ?? 1}
        func visit(_ node:HierarchyNode,_ depth:Int){weights[node.id]=weight(node);depths[node.id]=depth;for child in children[node.id] ?? [] {visit(child,depth+1)}}
        for root in roots {visit(root,0)}
        let depth=(depths.values.max() ?? 0)+1
        if chart.document.type == .tree {
            var leafIndex=0.0,centers:[String:Double] = [:]
            func place(_ node:HierarchyNode)->Double {
                if let values=children[node.id],!values.isEmpty {let positions=values.map(place),x=positions.reduce(0,+)/Double(positions.count);centers[node.id]=x;return x}
                defer{leafIndex+=1};centers[node.id]=leafIndex;return leafIndex
            }
            for root in roots {_=place(root)}
            func point(_ id:String)->ChartPoint {.init(x:plot.x+(centers[id]!+0.5)/max(1,leafIndex)*plot.width,y:plot.y+(Double(depths[id]!)+0.5)/Double(depth)*plot.height)}
            for node in nodes {
                if let parent=node.parentID {let a=point(parent),b=point(node.id);add(.path([.move(a),.cubic(control1:.init(x:a.x,y:(a.y+b.y)/2),control2:.init(x:b.x,y:(a.y+b.y)/2),end:b)]),style:"edge",sources:[source(parent,collection:"nodes"),source(node.id,collection:"nodes")])}
            }
            for (i,node) in nodes.enumerated() {let p=point(node.id),rect=ChartRect(x:p.x-32,y:p.y-12,width:64,height:24);bar(rect,style:"series.\(i).soft",sources:[source(node.id,collection:"nodes")],readout:.init(title:node.label,fields:[.init("parent",node.parentID.flatMap{lookup[$0]?.label} ?? "Root")]));text(node.label,x:rect.x+3,y:rect.y+3,width:58,height:18)}
            return
        }
        let sum=roots.reduce(0){$0+weights[$1.id]!}
        if chart.document.type == .treemap {
            func boxes(_ siblings:[HierarchyNode],_ rect:ChartRect,_ vertical:Bool)->[(HierarchyNode,ChartRect)] {
                let total=siblings.reduce(0){$0+weights[$1.id]!};var offset=0.0;var result:[(HierarchyNode,ChartRect)] = []
                for node in siblings where weights[node.id]!>0 {
                    let f=weights[node.id]!/total,r=vertical ? ChartRect(x:rect.x+offset*rect.width,y:rect.y,width:f*rect.width,height:rect.height):ChartRect(x:rect.x,y:rect.y+offset*rect.height,width:rect.width,height:f*rect.height)
                    result.append((node,r));offset+=f
                }
                return result
            }
            var queue=boxes(roots,plot,plot.width>=plot.height)
            while !queue.isEmpty {
                let (node,rect)=queue.removeFirst(),style="series.\((nodes.firstIndex{$0.id==node.id} ?? 0))"
                bar(rect,style:style+".soft",sources:[source(node.id,collection:"nodes")],readout:valueReadout(node.label,[("value",weights[node.id]!)]))
                if let sub=children[node.id],!sub.isEmpty{queue += boxes(sub,rect,rect.width>=rect.height)}
                else if rect.width>42 && rect.height>22{text(node.label,x:rect.x+4,y:rect.y+4,width:rect.width-8,height:min(40,rect.height-8))}
            }
        } else {
            legend += nodes.enumerated().map{.init(id:$0.element.id,label:$0.element.label,styleToken:"series.\($0.offset)")}
            let center=ChartPoint(x:frame.width/2,y:frame.height/2+10),radius=min(plot.width,plot.height)/2
            var queue:[(HierarchyNode,Double,Double)] = [],angle = -Double.pi/2
            for node in roots {let end=angle+weights[node.id]!/sum*2*Double.pi;queue.append((node,angle,end));angle=end}
            while !queue.isEmpty {
                let (node,start,end)=queue.removeFirst(),level=depths[node.id]!,inner=radius*Double(level)/Double(depth),outer=radius*Double(level+1)/Double(depth)
                if weights[node.id]! <= 0 {continue}
                if end>start {add(.path(sector(center:center,inner:inner,outer:outer,start:start,end:end)),style:"series.\(nodes.firstIndex{$0.id==node.id} ?? 0).soft",sources:[source(node.id,collection:"nodes")],bounds:.init(x:center.x-outer,y:center.y-outer,width:outer*2,height:outer*2),readout:valueReadout(node.label,[("value",weights[node.id]!),("depth",Double(level))]))}
                var cursor=start
                for child in children[node.id] ?? [] {let next=cursor+(end-start)*weights[child.id]!/weights[node.id]!;queue.append((child,cursor,next));cursor=next}
            }
        }
    }
    mutating func network(_ graph:GraphData) throws {
        let center=ChartPoint(x:frame.width/2,y:frame.height/2+10),r=min(plot.width,plot.height)*0.42,n=graph.nodes.count
        var positions:[String:ChartPoint] = [:]
        for (i,node) in graph.nodes.enumerated(){let angle = -Double.pi/2+2*Double.pi*Double(i)/Double(n);positions[node.id]=n==1 ? center:.init(x:center.x+r*cos(angle),y:center.y+r*sin(angle))}
        let maxWeight=max(graph.edges.map{abs($0.weight ?? 1)}.max() ?? 1,1e-12)
        for edge in graph.edges {
            let a=positions[edge.source]!,b=positions[edge.target]!,width=0.7+3.3*sqrt(abs(edge.weight ?? 1)/maxWeight),style="edge.\(number(width))"
            let ref=source(edge.id,collection:"edges"),readout=ChartReadout(title:edge.source+" → "+edge.target,fields:edge.weight.map{[.init("weight",number($0))]} ?? [])
            if edge.source==edge.target {add(.circle(center:.init(x:a.x+12,y:a.y-12),radius:16),style:"edge.outline",sources:[ref],bounds:.init(x:a.x-4,y:a.y-28,width:32,height:32),readout:readout)}
            else {
                let dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy),start=ChartPoint(x:a.x+dx/length*13,y:a.y+dy/length*13),end=ChartPoint(x:b.x-dx/length*13,y:b.y-dy/length*13)
                add(.polyline([start,end]),style:style,sources:[ref],bounds:bounding([start,end]),readout:readout)
                if graph.directed {arrow(at:end,from:start,style:"edge")}
                if let weight=edge.weight{text(number(weight),x:(a.x+b.x)/2,y:(a.y+b.y)/2,width:54)}
            }
        }
        for (i,node) in graph.nodes.enumerated(){let p=positions[node.id]!;markPoint(p,radius:12,style:"series.\(i)",sources:[source(node.id,collection:"nodes")],readout:.init(title:node.label,fields:[.init("id",node.id)]));text(node.label,x:p.x+14,y:p.y-8,width:110)}
    }
    mutating func arrow(at tip:ChartPoint,from base:ChartPoint,style:String){let angle=atan2(tip.y-base.y,tip.x-base.x);add(.polygon([tip,.init(x:tip.x-8*cos(angle-0.45),y:tip.y-8*sin(angle-0.45)),.init(x:tip.x-8*cos(angle+0.45),y:tip.y-8*sin(angle+0.45))]),style:style)}
    mutating func waterfall(_ steps:[WaterfallStep]) throws {
        var running=chart.document.options.baseline ?? 0,values:[(Double,Double)] = []
        for step in steps {if step.kind == .delta{values.append((running,running+step.value));running+=step.value}else{values.append((0,step.value))}}
        let t=try ChartCartesianTransform(xDomain:.categorical(steps.map(\.id)),yDomain:numericDomain(values.flatMap{[$0.0,$0.1]},zero:true),plot:plot);try axes(t)
        let width=plot.width/Double(steps.count)*0.65
        for (i,step) in steps.enumerated(){let a=try t.position(x:.category(step.id),y:.number(values[i].0)),b=try t.position(x:.category(step.id),y:.number(values[i].1));bar(.init(x:a.x-width/2,y:min(a.y,b.y),width:width,height:abs(a.y-b.y)),style:step.kind == .delta ? (step.value>=0 ? "positive":"negative"):"series.0",sources:[source(step.id)],readout:valueReadout(step.label,[("value",step.value),("start",values[i].0),("end",values[i].1)]));if i+1<steps.count {let next=try t.position(x:.category(steps[i+1].id),y:.number(values[i].1));line(.init(x:b.x+width/2,y:b.y),.init(x:next.x-width/2,y:b.y),style:"grid")}}
    }
}
