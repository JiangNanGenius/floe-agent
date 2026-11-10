import Foundation
import Testing
@testable import FloeNativeChartsCore

@Suite("Forty real native scenes")
struct ChartSceneTests {
    @Test("Every chart builds actual data-bearing finite geometry")
    func allFortyScenes() throws {
        for kind in ChartKind.allCases {
            let chart=try ChartValidator.prepare(ChartCoreTests.fixture(kind))
            let scene=try NativeChartSceneBuilder.build(chart)
            #expect(scene.layout.primitives.contains{!$0.sourceIDs.isEmpty && $0.styleToken != "hitOnly"}, "Missing real data geometry for \(kind.rawValue)")
            #expect(!scene.hits.isEmpty)
            #expect(scene.layout.primitives.count<=20_000)
        }
    }
    @Test("R7 box statistics use actual whiskers and retain outliers")
    func boxGolden() throws {
        let box=try ChartStatMath.tukeyBox([0,1,2,3,4,100],id:"golden")
        #expect(box.q1==1.25 && box.median==2.5 && box.q3==3.75)
        #expect(box.lowerWhisker==0 && box.upperWhisker==4 && box.outliers==[100])
    }
    @Test("Violin and density use a real bimodal Gaussian KDE")
    func kdeGolden() throws {
        let samples=[-2.1,-2,-1.9,1.9,2,2.1]
        let density=try ChartStatMath.density(samples,bandwidth:0.2)
        let points=density.series.points
        #expect(points.count==128 && density.bandwidth==0.2)
        let center=points.min{abs($0.x)<abs($1.x)}!.density
        let left=points.filter{$0.x<0}.map(\.density).max()!,right=points.filter{$0.x>0}.map(\.density).max()!
        #expect(left>center*10 && right>center*10)
        let area=zip(points,points.dropFirst()).reduce(0.0){$0+($1.1.x-$1.0.x)*($1.0.density+$1.1.density)/2}
        #expect(abs(area-1)<0.01)
    }
    @Test("Moving averages retain warmup and declared seed")
    func movingAverageGolden() throws {
        #expect(try ChartStatMath.movingAverage([1,2,3,4],method:.sma,period:3)==[nil,nil,2,3])
        let ema=try ChartStatMath.movingAverage([1,2,3,4],method:.ema,period:3,seed:.sma)
        #expect(ema==[nil,nil,2,3])
        #expect(try ChartStatMath.movingAverage([1,2,3],method:.ema,period:3,seed:.firstValue)==[1,1.5,2.25])
    }
    @Test("Pie and donut are distinct native paths; rare plots are not chart substitutions")
    func shapeSemantics() throws {
        let pie=try NativeChartSceneBuilder.build(ChartValidator.prepare(ChartCoreTests.fixture(.pie)))
        let donut=try NativeChartSceneBuilder.build(ChartValidator.prepare(ChartCoreTests.fixture(.donut)))
        #expect(pie.layout.primitives != donut.layout.primitives)
        let violin=try NativeChartSceneBuilder.build(ChartValidator.prepare(ChartCoreTests.fixture(.violin)))
        #expect(violin.layout.primitives.contains{if case .polygon(let p)=$0.shape{return p.count==256};return false})
        let sankey=try NativeChartSceneBuilder.build(ChartValidator.prepare(ChartCoreTests.fixture(.sankey)))
        #expect(sankey.layout.primitives.filter{if case .path=$0.shape{return !$0.sourceIDs.isEmpty};return false}.count>=2)
        let chord=try NativeChartSceneBuilder.build(ChartValidator.prepare(ChartCoreTests.fixture(.chord)))
        #expect(chord.layout.primitives.filter{if case .path=$0.shape{return true};return false}.count>=3)
    }
    @Test("Filtered singleton areas and confidence intervals retain genuine points and bounds")
    func singletonAndZero() throws {
        for kind in [ChartKind.area,.confidenceBand] {
            let source=try ChartValidator.prepare(ChartCoreTests.fixture(kind)),first=ChartDisplayFilter.options(for:source)[0].id
            let snapshot=try #require(ChartDisplayFilter.apply([first],to:source))
            let scene=try snapshot.scene()
            #expect(!scene.hits.isEmpty)
            #expect(!scene.layout.primitives.contains{if case .polygon(let points)=$0.shape{return points.count<3};return false})
        }
        var source=ChartCoreTests.fixture(.percentStackedBar)
        source.data = .cartesian([.init(id:"zero",x:.category("A"),y:0)])
        source.options.orientation = .horizontal
        let scene=try NativeChartSceneBuilder.build(ChartValidator.prepare(source))
        #expect(scene.hits.contains{$0.readout.fields.contains{$0.value.contains("Undefined")}})
    }
    @Test("Unequal histogram widths use density area rather than equal-height counts")
    func histogramDensity() throws {
        let d=ChartDocument(type:.histogram,data:.bins([.init(id:"a",lower:0,upper:1,count:2),.init(id:"b",lower:1,upper:3,count:2)]),options:.init(histogramMeasure:.density))
        let scene=try NativeChartSceneBuilder.build(ChartValidator.prepare(d))
        let densities=scene.hits.compactMap{$0.readout.fields.first{$0.name=="density"}.flatMap{Double($0.value)}}
        #expect(densities==[0.5,0.25])
        #expect(densities[0]*1+densities[1]*2==1)
    }
    @Test("Explicit axes and shared facets retain domains without clipping")
    func declaredAndSharedAxes() throws {
        let axes:[ChartAxis]=[.init(id:"x",kind:.numeric,lower:0,upper:100),.init(id:"y",kind:.numeric,lower:0,upper:100)]
        let a=ChartDocument(type:.line,data:.cartesian([.init(id:"a",x:.number(10),y:10)]),axes:axes)
        let b=ChartDocument(type:.line,data:.cartesian([.init(id:"b",x:.number(90),y:90)]),axes:axes)
        let shared=ChartDocument(type:.smallMultiples,data:.facets([.init(id:"a",document:a),.init(id:"b",document:b)]),options:.init(sharedAxes:true))
        let scene=try NativeChartSceneBuilder.build(ChartValidator.prepare(shared),width:1280,height:960)
        #expect(scene.hits.count==2)
        var clipped=a;clipped.axes[1].upper=5
        #expect(throws:ChartIssue.self){try NativeChartSceneBuilder.build(ChartValidator.prepare(clipped))}
        var falseShared=shared
        if case .facets(var facets)=falseShared.data{for i in facets.indices{facets[i].document.axes=[]};falseShared.data = .facets(facets)}
        #expect(throws:ChartIssue.self){try ChartValidator.prepare(falseShared)}
        let date=try ChartDates.localDate("2026-11-08",timeZone:"America/New_York")
        #expect(try ChartDates.instant("2026-11-08T05:00:00Z")==date)
    }
    @Test("Price-volume filtering retains original moving-average time context")
    func financialFilterContext() throws {
        let chart=try ChartValidator.prepare(ChartCoreTests.fixture(.priceVolume)),option=ChartDisplayFilter.options(for:chart).last!
        let snapshot=try #require(ChartDisplayFilter.apply([option.id],to:chart))
        #expect(snapshot.chart.document==chart.document)
        let scene=try snapshot.scene()
        #expect(scene.hits.contains{$0.readout.title.hasPrefix("SMA")})
    }

    @Test("Numeric bar endpoints retain real spacing and visible finite column widths")
    func numericBarMargins() throws {
        let scene=try NativeChartSceneBuilder.build(ChartValidator.prepare(ChartCoreTests.fixture(.column)))
        let rects=scene.layout.primitives.compactMap{primitive -> ChartRect? in if !primitive.sourceIDs.isEmpty,case .rectangle(let rect)=primitive.shape{return rect};return nil}
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy{$0.x>=64 && $0.x+$0.width<=scene.frame.width-60 && $0.width<=64})
    }

}
