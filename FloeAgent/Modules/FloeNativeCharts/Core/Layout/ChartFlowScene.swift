// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartSceneBuilder {
    mutating func sankey(_ flow:FlowData) throws {
        let ids=flow.nodes.map(\.id),lookup=Dictionary(uniqueKeysWithValues:flow.nodes.map{($0.id,$0.label)})
        var degree=Dictionary(uniqueKeysWithValues:ids.map{($0,0)}),targets:[String:[String]] = [:],levels=Dictionary(uniqueKeysWithValues:ids.map{($0,0)})
        var incoming:[String:Double] = [:],outgoing:[String:Double] = [:]
        for link in flow.links {degree[link.target,default:0]+=1;targets[link.source,default:[]].append(link.target);incoming[link.target,default:0]+=link.value;outgoing[link.source,default:0]+=link.value}
        var queue=ids.filter{degree[$0]==0},cursor=0
        while cursor<queue.count {let id=queue[cursor];cursor+=1;for next in targets[id] ?? [] {levels[next]=max(levels[next]!,levels[id]!+1);degree[next,default:0]-=1;if degree[next]==0{queue.append(next)}}}
        let groups=Dictionary(grouping:ids,by:{levels[$0]!}),maxLevel=levels.values.max() ?? 0,maxNodes=groups.values.map(\.count).max() ?? 1
        let gap=min(10,plot.height/Double(maxNodes)*0.2)
        let weights=Dictionary(uniqueKeysWithValues:ids.map{($0,max(incoming[$0,default:0],outgoing[$0,default:0]))})
        let maxTotal=groups.values.map{group in group.reduce(0){$0+weights[$1]!}}.max()!
        let scale=max(0,(plot.height-gap*Double(maxNodes-1)-Double(maxNodes)*0.5)/maxTotal),nodeWidth=min(18,max(2,plot.width/Double(maxLevel+1)*0.18))
        var frames:[String:ChartRect] = [:]
        for level in groups.keys.sorted() {
            let values=groups[level]!,heights=values.map{max(0.5,weights[$0]!*scale)},total=heights.reduce(0,+)+gap*Double(values.count-1)
            var y=plot.y+(plot.height-total)/2
            for (id,height) in zip(values,heights){let x=plot.x+Double(level)/Double(max(1,maxLevel))*(plot.width-nodeWidth);frames[id] = .init(x:x,y:y,width:nodeWidth,height:height);y+=height+gap}
        }
        var usedOut:[String:Double] = [:],usedIn:[String:Double] = [:]
        for (i,link) in flow.links.enumerated() where link.value>0 {
            let a=frames[link.source]!,b=frames[link.target]!,height=link.value*scale
            let y0=a.y+usedOut[link.source,default:0],y1=b.y+usedIn[link.target,default:0],mid=(a.x+a.width+b.x)/2
            usedOut[link.source,default:0]+=height;usedIn[link.target,default:0]+=height
            let path:[ChartPathSegment]=[.move(.init(x:a.x+a.width,y:y0)),.cubic(control1:.init(x:mid,y:y0),control2:.init(x:mid,y:y1),end:.init(x:b.x,y:y1)),.line(.init(x:b.x,y:y1+height)),.cubic(control1:.init(x:mid,y:y1+height),control2:.init(x:mid,y:y0+height),end:.init(x:a.x+a.width,y:y0+height)),.close]
            add(.path(path),style:"series.\(i).soft",sources:[source(link.id,collection:"links")],bounds:.init(x:a.x+a.width,y:min(y0,y1),width:max(1,b.x-a.x-a.width),height:max(1,abs(y1-y0)+height)),readout:.init(title:(lookup[link.source] ?? link.source)+" → "+(lookup[link.target] ?? link.target),fields:[.init("flow",number(link.value))]))
        }
        for (i,node) in flow.nodes.enumerated(){let rect=frames[node.id]!;bar(rect,style:"series.\(i)",sources:[source(node.id,collection:"nodes")],readout:valueReadout(node.label,[("incoming",incoming[node.id,default:0]),("outgoing",outgoing[node.id,default:0])]));text(node.label,x:rect.x+(levels[node.id]==maxLevel ? -94:rect.width+4),y:rect.y+rect.height/2-8,width:90)}
        if !chart.warnings.isEmpty{notes.append("Node imbalance is retained; ribbon thickness represents the original flow values.")}
    }
    mutating func chord(_ matrix:ChordMatrix) throws {
        let n=matrix.nodes.count,center=ChartPoint(x:frame.width/2,y:frame.height/2+8),radius=min(plot.width,plot.height)*0.46,inner=radius*0.9
        var weights=Array(repeating:0.0,count:n)
        for i in 0..<n {for j in 0..<n {weights[i]+=matrix.values[i][j];if matrix.directed{weights[i]+=matrix.values[j][i]}}}
        let total=weights.reduce(0,+);try chartCheck(total.isFinite && total>0,"layout.chord","chord weight sum overflow")
        let pad=min(0.04,Double.pi/Double(max(1,n))*0.15),available=2*Double.pi-pad*Double(n)
        var starts=Array(repeating:0.0,count:n),ends=starts,offsets=starts,cursor = -Double.pi/2
        for i in 0..<n {starts[i]=cursor;ends[i]=cursor+available*weights[i]/total;offsets[i]=starts[i];cursor=ends[i]+pad
            if weights[i]>0{add(.path(sector(center:center,inner:inner,outer:radius,start:starts[i],end:ends[i])),style:"series.\(i)",sources:[source(matrix.nodes[i].id,collection:"nodes")],bounds:.init(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2),readout:valueReadout(matrix.nodes[i].label,[("incidentWeight",weights[i])]))}
            let a=(starts[i]+ends[i])/2;text(matrix.nodes[i].label,x:center.x+(radius+12)*cos(a)-32,y:center.y+(radius+12)*sin(a)-8,width:90)
        }
        func point(_ angle:Double)->ChartPoint{.init(x:center.x+inner*cos(angle),y:center.y+inner*sin(angle))}
        for i in 0..<n {for j in 0..<n where matrix.directed || j>=i {
            let value=matrix.values[i][j];if value<=0{continue}
            let amountI=available*value/total,amountJ=available*value/total
            let a0=offsets[i],a1=a0+amountI;offsets[i]=a1
            let b0:Double,b1:Double
            if i==j && matrix.directed {b0=a1;b1=b0+amountJ;offsets[i]=b1}
            else if i==j {b0=(a0+a1)/2;b1=a1}
            else{b0=offsets[j];b1=b0+amountJ;offsets[j]=b1}
            let sourceEnd=i==j && !matrix.directed ? (a0+a1)/2:a1
            var path:[ChartPathSegment]=[.move(point(a0))];path+=arc(center:center,radius:inner,start:a0,end:sourceEnd)
            path.append(.cubic(control1:center,control2:center,end:point(b0)));path+=arc(center:center,radius:inner,start:b0,end:b1)
            path.append(.cubic(control1:center,control2:center,end:point(a0)));path.append(.close)
            let refs=[source(matrix.nodes[i].id,collection:"nodes"),source(matrix.nodes[j].id,collection:"nodes")]
            add(.path(path),style:"series.\(i).soft",sources:refs,bounds:.init(x:center.x-inner,y:center.y-inner,width:inner*2,height:inner*2),readout:.init(title:matrix.nodes[i].label+(matrix.directed ? " → ":" ↔ ")+matrix.nodes[j].label,fields:[.init("value",number(value))]))
            if matrix.directed {let middle=(b0+b1)/2,tip=point(middle);arrow(at:tip,from:center,style:"series.\(i)")}
        }}
        notes.append(matrix.directed ? "Directed ribbons; arcs allocate incoming and outgoing magnitude.":"Undirected symmetric matrix; each pair is drawn once.")
    }
}
