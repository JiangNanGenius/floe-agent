// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartSceneBuilder {
    // x is the independent axis. Series axisID (or y) selects a value axis.
    func valueAxis() -> ChartAxis? {
        let assignments=Set(chart.document.series.compactMap(\.axisID))
        if assignments.count==1,let id=assignments.first{return chart.document.axes.first{$0.id==id}}
        return chart.document.axes.first{$0.id=="y"}
    }
    func valueDomain(_ values:[Double],zero:Bool = false) throws -> ChartAxisDomain {
        let assignments=Set(chart.document.series.compactMap(\.axisID))
        try chartCheck(assignments.count<=1 || chart.document.type == .combo,"axes","multiple value axes require a combo chart")
        return try numericDomain(values,zero:zero,axis:valueAxis())
    }
    func numericDomain(_ values:[Double],zero:Bool,axis:ChartAxis?) throws -> ChartAxisDomain {
        guard let axis else{return try numericDomain(values,zero:zero)}
        try chartCheck(axis.kind == .numeric,"axes."+axis.id,"value axis must be numeric")
        guard let low=axis.lower,let high=axis.upper else{return try numericDomain(values,zero:zero)}
        let domain=ChartAxisDomain.numeric(lower:low,upper:high)
        for value in values {let f=try domain.unitPosition(of:.number(value));try chartCheck((0...1).contains(f),"axes."+axis.id,"declared domain excludes a supplied or derived value; expand it instead of clipping")}
        if zero{try chartCheck(low<=0 && high>=0,"axes."+axis.id,"bar/area baseline is outside the declared domain")}
        return domain
    }
    func resolvedXDomain(_ inferred:ChartAxisDomain,coordinates:[ChartCoordinate]) throws -> ChartAxisDomain {
        guard let axis=chart.document.axes.first(where:{$0.id=="x"}) else{return inferred}
        let domain:ChartAxisDomain
        switch inferred {
        case .numeric:try chartCheck(axis.kind == .numeric,"axes.x","x axis kind does not match numeric coordinates");domain=axis.lower.map{.numeric(lower:$0,upper:axis.upper!)} ?? inferred
        case .temporal:try chartCheck(axis.kind == .temporal,"axes.x","x axis kind does not match time coordinates");domain=axis.lower.map{.temporal(lower:Date(timeIntervalSince1970:$0),upper:Date(timeIntervalSince1970:axis.upper!),timeZone:chart.document.options.timeZone ?? "UTC")} ?? inferred
        case .categorical:try chartCheck(axis.kind == .categorical,"axes.x","x axis kind does not match categories");domain=inferred
        }
        for coordinate in coordinates{let f=try domain.unitPosition(of:coordinate);try chartCheck((0...1).contains(f),"axes.x","declared domain excludes a supplied coordinate; expand it instead of clipping")}
        return domain
    }
}
