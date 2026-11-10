// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeNativeChartsCore

public enum NativeChartLanguage: Sendable {
    case english, simplifiedChinese
    public static var current:Self {Locale.current.language.languageCode?.identifier == "zh" ? .simplifiedChinese:.english}
    public func text(_ english:String,_ chinese:String)->String{self == .simplifiedChinese ? chinese:english}
    public func title(for kind:ChartKind)->String {
        let names:[(String,String)] = [
            ("Line","折线图"),("Columns","柱形图"),("Bars","条形图"),("Grouped bars","分组柱形图"),("Stacked bars","堆叠柱形图"),("Percent stacked bars","百分比堆叠柱形图"),("Area","面积图"),("Stacked area","堆叠面积图"),("Percent stacked area","百分比堆叠面积图"),("Line and columns","折线与柱形组合图"),("Small multiples","小多图"),("Pie","饼图"),("Donut","环形图"),("Histogram","直方图"),("Box plot","箱线图"),("Violin","小提琴图"),("Density","密度图"),("Error bars","误差棒图"),("Confidence band","置信区间带"),("Candlestick","K线图"),("OHLC","OHLC图"),("Volume","成交量图"),("Price, volume and moving averages","价量与均线"),("Scatter","散点图"),("Bubble","气泡图"),("Heatmap","热力图"),("Radar","雷达图"),("Polar","极坐标图"),("Parallel coordinates","平行坐标图"),("Treemap","矩形树图"),("Sunburst","旭日图"),("Network","关系网络图"),("Tree","树状层级图"),("Waterfall","瀑布图"),("Funnel","漏斗图"),("Sankey","桑基图"),("Chord","弦图"),("Timeline","时间线"),("Gantt","甘特图"),("Calendar heatmap","日历热力图")]
        let index=(Int(ChartCatalog.descriptor(for:kind).requirementID.dropFirst(2)) ?? 1)-1
        return text(names[index].0,names[index].1)
    }
    func field(_ key:String)->String {
        guard self == .simplifiedChinese else{return key}
        let values=["value":"数值","x":"X","y":"Y","size":"大小","series":"系列","percent":"百分比","open":"开盘","high":"最高","low":"最低","close":"收盘","volume":"成交量","start":"开始","end":"结束","progress":"进度","flow":"流量","incoming":"流入","outgoing":"流出","weight":"权重","parent":"上级","density":"密度","lower":"下界","upper":"上界","estimate":"估计值","count":"频数","probability":"概率","row":"行","column":"列","records":"记录数","angle":"角度","radius":"半径","range":"范围","depth":"层级","method":"方法","samples":"采样点","lowerWhisker":"下须","q1":"下四分位","median":"中位数","q3":"上四分位","upperWhisker":"上须"]
        return values[key] ?? key
    }
}
