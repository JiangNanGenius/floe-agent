// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartValidationContext {
    func validateSharedAxes(_ facets:[ChartFacet],path:String) throws {
        guard let first=facets.first?.document,
              let x=first.axes.first(where:{$0.id=="x"}),let y=first.axes.first(where:{$0.id=="y"}) else{
            throw ChartIssue(path:path,problem:"shared axes need explicit x and y definitions; numeric/time bounds must be supplied")
        }
        try chartCheck(y.kind == .numeric && y.lower != nil && y.upper != nil,path,"shared y needs an explicit numeric domain")
        if x.kind != .categorical{try chartCheck(x.lower != nil && x.upper != nil,path,"shared numeric/time x needs an explicit domain")}
        var categoryGrid:[ChartCoordinate]?
        for facet in facets {
            let d=facet.document,coordinates:[ChartCoordinate]
            switch d.data{
            case .cartesian(let rows):coordinates=rows.map(\.x)
            case .intervals(let rows):coordinates=rows.map(\.x)
            default:throw ChartIssue(path:path,problem:"shared Cartesian axes apply to Cartesian or interval facets; use independent axes for other families")
            }
            try chartCheck(d.options.timeZone == first.options.timeZone,path,"shared time axes require the same time zone")
            let horizontal=d.type == .bar || d.options.orientation == .horizontal
            let firstHorizontal=first.type == .bar || first.options.orientation == .horizontal
            try chartCheck(horizontal==firstHorizontal,path,"shared axes require the same orientation")
            try chartCheck(d.series.allSatisfy{$0.axisID == nil || $0.axisID == "y"},path,"shared-axis facets assign series to y")
            if x.kind == .categorical{
                var seen:Set<ChartCoordinate> = [];let grid=coordinates.filter{seen.insert($0).inserted}
                if let categoryGrid{try chartCheck(grid==categoryGrid,path,"shared categorical axes require the same ordered categories")}
                else{categoryGrid=grid}
            }
        }
    }
}
