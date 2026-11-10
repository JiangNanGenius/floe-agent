// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartSceneBuilder {
    mutating func schedule() throws {
        switch chart.document.data {
        case .events(let events):
            let xs=events.flatMap{[ChartCoordinate.instant($0.time)]+($0.end.map{[.instant($0)]} ?? [])}
            let domain=try xDomain(xs),rows=ChartAxisDomain.categorical(events.map(\.id))
            let t=try ChartCartesianTransform(xDomain:domain,yDomain:rows,plot:plot);try axes(t)
            for (i,event) in events.enumerated(){let a=try t.position(x:.instant(event.time),y:.category(event.id)),ref=source(event.id);if let end=event.end {let b=try t.position(x:.instant(end),y:.category(event.id));add(.polyline([a,b]),style:"series.\(i)",sources:[ref])};markPoint(a,radius:5,style:"series.\(i)",sources:[ref],readout:.init(title:event.label,fields:[.init("start",event.time)]+(event.end.map{[.init("end",$0)]} ?? [])));text(event.label,x:a.x+8,y:a.y-20,width:min(180,plot.width/2))}
        case .tasks(let tasks):
            let t=try ChartCartesianTransform(xDomain:xDomain(tasks.flatMap{[.instant($0.start),.instant($0.end)]}),yDomain:.categorical(tasks.map(\.id)),plot:plot);try axes(t)
            let height=min(30,plot.height/Double(tasks.count)*0.55)
            var frames:[String:(ChartPoint,ChartPoint)] = [:]
            for (i,task) in tasks.enumerated(){let a=try t.position(x:.instant(task.start),y:.category(task.id)),b=try t.position(x:.instant(task.end),y:.category(task.id)),ref=source(task.id),style="series.\(i)";frames[task.id]=(a,b)
                let detail=ChartReadout(title:task.label,fields:[.init("start",task.start),.init("end",task.end),.init("progress",task.progress.map{number($0*100)+"%"} ?? "—")])
                if task.milestone==true{let points=[ChartPoint(x:a.x,y:a.y-7),.init(x:a.x+7,y:a.y),.init(x:a.x,y:a.y+7),.init(x:a.x-7,y:a.y)];add(.polygon(points),style:style,sources:[ref],bounds:bounding(points),readout:detail)}
                else {bar(.init(x:a.x,y:a.y-height/2,width:b.x-a.x,height:height),style:style+".soft",sources:[ref],readout:detail);if let progress=task.progress,progress>0{bar(.init(x:a.x,y:a.y-height/2,width:(b.x-a.x)*progress,height:height/3),style:style,sources:[ref],readout:detail)}}
                text(task.label,x:plot.x+3,y:a.y-height/2-18,width:min(180,plot.width/2))
            }
            for task in tasks {for dependency in task.dependsOn ?? [] {let a=frames[dependency]!.1,b=frames[task.id]!.0,mid=(a.x+b.x)/2;add(.polyline([a,.init(x:mid,y:a.y),.init(x:mid,y:b.y),b]),style:"edge",sources:[source(dependency),source(task.id)]);arrow(at:b,from:.init(x:mid,y:b.y),style:"edge")}}
        case .calendar(let entries):try calendar(entries)
        default:throw ChartIssue(path:"layout",problem:"schedule payload mismatch")
        }
    }
    mutating func calendar(_ entries:[CalendarValue]) throws {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:chart.document.options.timeZone ?? "UTC")!;calendar.firstWeekday=chart.document.options.weekStart ?? 1
        var groups:[String:[CalendarValue]] = [:],dates:[String:Date] = [:]
        for entry in entries {
            let date:Date
            switch entry.day {case .instant(let text):date=try ChartDates.instant(text);case .localDate(let text):date=try ChartDates.localDate(text,timeZone:calendar.timeZone.identifier);default:throw ChartIssue(path:"calendar",problem:"date coordinate expected")}
            let parts=calendar.dateComponents([.year,.month,.day],from:date),key=String(format:"%04d-%02d-%02d",parts.year!,parts.month!,parts.day!)
            groups[key,default:[]].append(entry);dates[key]=date
        }
        let first=dates.values.min()!,last=dates.values.max()!,yearA=calendar.component(.year,from:first),yearB=calendar.component(.year,from:last)
        try chartCheck(yearB-yearA<=15,"calendar","calendar export is limited to16 years; select a narrower range")
        var values:[String:Double] = [:]
        for (key,rows) in groups {let value:Double;switch chart.document.options.aggregation ?? .last {case .sum:value=rows.reduce(0){$0+$1.value};case .mean:value=rows.reduce(0){$0+$1.value/Double(rows.count)};case .count:value=Double(rows.count);case .last:value=rows.last!.value};try chartFinite(value,"calendar.aggregate");values[key]=value}
        let low=values.values.min()!,high=values.values.max()!,yearHeight=plot.height/Double(yearB-yearA+1),cell=min(plot.width/54,max(1,(yearHeight-22)/8))
        for year in yearA...yearB {
            var date=calendar.date(from:DateComponents(year:year,month:1,day:1))!,week=0
            let yearY=plot.y+Double(year-yearA)*yearHeight
            text(String(year),x:plot.x-48,y:yearY,width:46)
            let days=["Su","Mo","Tu","We","Th","Fr","Sa"]
            for day in 0..<7{text(days[(calendar.firstWeekday-1+day)%7],x:plot.x-24,y:yearY+22+Double(day)*cell,width:22,height:cell)}
            while calendar.component(.year,from:date)==year {
                let weekday=(calendar.component(.weekday,from:date)-calendar.firstWeekday+7)%7
                if weekday==0 && calendar.component(.day,from:date)>1{week+=1}
                let parts=calendar.dateComponents([.year,.month,.day],from:date),key=String(format:"%04d-%02d-%02d",parts.year!,parts.month!,parts.day!)
                let rect=ChartRect(x:plot.x+Double(week)*cell,y:yearY+22+Double(weekday)*cell,width:max(0.5,cell-1),height:max(0.5,cell-1))
                if calendar.component(.day,from:date)==1{text(String(calendar.component(.month,from:date)),x:rect.x,y:yearY,width:40,height:20)}
                if let value=values[key],let rows=groups[key]{let fraction=high==low ? 0.5:(value-low)/(high-low);bar(rect,style:"heat.\(min(9,max(0,Int(fraction*9))))",sources:rows.map{source($0.id)},readout:.init(title:key,fields:[.init("value",number(value)),.init("records",String(rows.count))]))}
                else {add(.rectangle(rect),style:"missing")}
                guard let next=calendar.date(byAdding:.day,value:1,to:date),next>date else{throw ChartIssue(path:"calendar",problem:"calendar progression failed")};date=next
            }
        }
        notes.append("Calendar: \(calendar.timeZone.identifier); missing days are not zero; aggregation=\((chart.document.options.aggregation ?? .last).rawValue).")
    }
}
