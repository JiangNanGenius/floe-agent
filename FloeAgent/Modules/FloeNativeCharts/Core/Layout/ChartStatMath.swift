// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ChartStatMath {
    public static func quantileR7(_ values:[Double],probability:Double) throws -> Double {
        try chartCheck(!values.isEmpty && values.count<=2000 && values.allSatisfy(\.isFinite) && (0...1).contains(probability),"statistics","invalid quantile input")
        let sorted=values.sorted(),h=Double(values.count-1)*probability,i=Int(floor(h)),f=h-Double(i)
        if i==sorted.count-1 { return sorted[i] }
        let value=sorted[i]*(1-f)+sorted[i+1]*f;try chartFinite(value,"statistics.quantile");return value
    }
    public static func tukeyBox(_ values:[Double],id:String) throws -> BoxSummary {
        let q1=try quantileR7(values,probability:0.25),median=try quantileR7(values,probability:0.5),q3=try quantileR7(values,probability:0.75)
        let iqr=q3-q1,low=q1-1.5*iqr,high=q3+1.5*iqr
        try chartCheck([iqr,low,high].allSatisfy(\.isFinite),"statistics.box","IQR range overflow")
        let inside=values.filter { $0>=low && $0<=high }
        return .init(id:id,lowerWhisker:inside.min()!,q1:q1,median:median,q3:q3,upperWhisker:inside.max()!,outliers:values.filter { $0<low || $0>high })
    }
    public static func density(_ values:[Double],bandwidth supplied:Double? = nil,id:String = "density") throws -> (series:DensitySeries,bandwidth:Double) {
        try chartCheck(!values.isEmpty && values.count<=2000 && values.allSatisfy(\.isFinite),"statistics.density","invalid samples")
        let h:Double
        if let supplied { h=supplied }
        else {
            try chartCheck(values.count>=2,"statistics.bandwidth","one sample requires explicit bandwidth")
            let mean=values.reduce(0) { $0+$1/Double(values.count) }
            let deltas=values.map { $0-mean },scale=deltas.map(abs).max()!
            try chartCheck(scale.isFinite && scale>0,"statistics.bandwidth","constant samples require explicit bandwidth")
            let sd=scale*sqrt(deltas.reduce(0) { $0+pow($1/scale,2) }/Double(values.count-1))
            h=sd*pow(Double(values.count),-0.2)
        }
        try chartCheck(h.isFinite && h>0,"statistics.bandwidth","bandwidth must be finite and positive")
        let low=values.min()!-3*h,high=values.max()!+3*h
        try chartCheck(low.isFinite && high.isFinite && low<high,"statistics.density","density support overflow")
        let points=(0..<ChartLimits.densityGrid).map { i -> DensityPoint in
            let f=Double(i)/Double(ChartLimits.densityGrid-1),x=low*(1-f)+high*f
            let sum=values.reduce(0.0) { sum,v in let z=(x-v)/h;return sum+exp(-z*z/2) }
            return .init(x:x,density:sum/Double(values.count)/h/sqrt(2*Double.pi))
        }
        try chartCheck(points.allSatisfy { $0.density.isFinite },"statistics.density","density overflow")
        return (.init(id:id,points:points),h)
    }
    public static func movingAverage(_ values:[Double],method:MovingAverageMethod,period:Int,seed:MovingAverageSeed? = nil) throws -> [Double?] {
        try chartCheck(values.count<=2000 && values.allSatisfy(\.isFinite) && (1...2000).contains(period),"movingAverage","invalid prices or period")
        var result=Array<Double?>(repeating:nil,count:values.count)
        if method == .sma {
            if values.count<period { return result }
            for i in (period-1)..<values.count {
                let mean=values[(i-period+1)...i].reduce(0) { $0+$1/Double(period) }
                try chartFinite(mean,"movingAverage");result[i]=mean
            }
        } else {
            try chartCheck(seed != nil,"movingAverage.seed","EMA seed must be explicit")
            guard !values.isEmpty else { return result }
            let start:Int;var previous:Double
            if seed == .firstValue { start=0;previous=values[0] }
            else { if values.count<period{return result};start=period-1;previous=values.prefix(period).reduce(0){$0+$1/Double(period)} }
            result[start]=previous
            if start+1<values.count {
                let alpha=2/Double(period+1)
                for i in (start+1)..<values.count { previous=alpha*values[i]+(1-alpha)*previous;try chartFinite(previous,"movingAverage");result[i]=previous }
            }
        }
        return result
    }
}
