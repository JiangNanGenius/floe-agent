// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ChartPoint: Sendable, Equatable, Codable {
    public var x: Double; public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isFinite: Bool { x.isFinite && y.isFinite }
}
public struct ChartRect: Sendable, Equatable, Codable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x,y,width,height,x+width,y+height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    public func contains(_ point: ChartPoint) -> Bool {
        point.x >= x && point.x <= x+width && point.y >= y && point.y <= y+height
    }
}

public enum ChartAxisDomain: Sendable, Equatable {
    case numeric(lower: Double, upper: Double)
    /// Continuous instants in seconds, never equal-spaced date labels.
    case temporal(lower: Date, upper: Date, timeZone: String)
    case categorical([String])

    public func validate() throws {
        switch self {
        case .numeric(let lower,let upper):
            try chartCheck(lower.isFinite && upper.isFinite && lower < upper,"domain","bounds must be finite and increasing")
        case .temporal(let lower,let upper,let zone):
            try chartCheck(lower.timeIntervalSince1970.isFinite && upper.timeIntervalSince1970.isFinite && lower < upper
                && TimeZone(identifier:zone) != nil,"domain","time bounds or time zone are invalid")
        case .categorical(let labels):
            try chartCheck(!labels.isEmpty && labels.count <= ChartLimits.inputRecords && Set(labels).count == labels.count,"domain","categories must be nonempty, unique and bounded")
            for label in labels { try chartText(label,"domain.categories") }
        }
    }
    public func unitPosition(of coordinate: ChartCoordinate) throws -> Double {
        try validate()
        switch (self,coordinate) {
        case (.numeric(let lower,let upper),.number(let value)):
            try chartFinite(value,"coordinate")
            let span = upper-lower
            let result = span.isFinite ? (value-lower)/span : (value/2-lower/2)/(upper/2-lower/2)
            try chartFinite(result,"coordinate projection"); return result
        case (.temporal(let lower,let upper,let zone),_):
            let value: Date
            switch coordinate {
            case .instant(let text): value = try ChartDates.instant(text)
            case .localDate(let text):
                value = try ChartDates.localDate(text,timeZone:zone)
            default: throw ChartIssue(path:"coordinate",problem:"time domain requires instant or localDate")
            }
            return value.timeIntervalSince(lower)/upper.timeIntervalSince(lower)
        case (.categorical(let labels),.category(let label)):
            guard let index = labels.firstIndex(of:label) else { throw ChartIssue(path:"coordinate",problem:"unknown category") }
            return (Double(index)+0.5)/Double(labels.count)
        default: throw ChartIssue(path:"coordinate",problem:"coordinate kind does not match axis domain")
        }
    }
    public func coordinate(atUnitPosition position: Double) throws -> ChartCoordinate? {
        try validate(); try chartFinite(position,"position")
        switch self {
        case .numeric(let lower,let upper):
            let value = lower*(1-position)+upper*position
            try chartFinite(value,"inverse projection"); return .number(value)
        case .temporal(let lower,let upper,_):
            let seconds = lower.timeIntervalSince1970*(1-position)+upper.timeIntervalSince1970*position
            try chartFinite(seconds,"inverse projection")
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            return .instant(formatter.string(from:Date(timeIntervalSince1970:seconds)))
        case .categorical(let labels):
            guard (0...1).contains(position) else { return nil }
            return .category(labels[min(labels.count-1,Int(position*Double(labels.count)))])
        }
    }
}

public struct ChartCartesianTransform: Sendable, Equatable {
    public let xDomain: ChartAxisDomain
    public let yDomain: ChartAxisDomain
    public let plot: ChartRect
    public init(xDomain: ChartAxisDomain, yDomain: ChartAxisDomain, plot: ChartRect) throws {
        try xDomain.validate(); try yDomain.validate()
        try chartCheck(plot.isValid,"plot","plot rectangle must be finite and positive")
        self.xDomain = xDomain; self.yDomain = yDomain; self.plot = plot
    }
    public func position(x: ChartCoordinate, y: ChartCoordinate) throws -> ChartPoint {
        let point = ChartPoint(x:plot.x + (try xDomain.unitPosition(of:x))*plot.width,
                               y:plot.y + (1 - (try yDomain.unitPosition(of:y)))*plot.height)
        try chartCheck(point.isFinite,"projection","projected point is not finite")
        return point
    }
    public func coordinates(at point: ChartPoint) throws -> (x: ChartCoordinate?,y: ChartCoordinate?) {
        try chartCheck(point.isFinite,"point","must be finite")
        return (try xDomain.coordinate(atUnitPosition:(point.x-plot.x)/plot.width),
                try yDomain.coordinate(atUnitPosition:1-(point.y-plot.y)/plot.height))
    }
}

public enum ChartPathSegment: Sendable, Equatable {
    case move(ChartPoint), line(ChartPoint), cubic(control1: ChartPoint, control2: ChartPoint, end: ChartPoint), close
    var points: [ChartPoint] {
        switch self { case .move(let p),.line(let p): [p]; case .cubic(let a,let b,let c): [a,b,c]; case .close: [] }
    }
}
public enum ChartShape: Sendable, Equatable {
    case point(ChartPoint), polyline([ChartPoint]), polygon([ChartPoint]), rectangle(ChartRect)
    case circle(center: ChartPoint, radius: Double), path([ChartPathSegment]), text(String, frame: ChartRect)
}
public struct ChartPrimitive: Sendable, Equatable {
    public var id: String
    public var sourceIDs: [ChartRecordID]
    public var shape: ChartShape
    /// Semantic tokens; UI chooses actual colors and fonts.
    public var styleToken: String
    public init(id: String, sourceIDs: [ChartRecordID], shape: ChartShape, styleToken: String = "primary") {
        self.id = id; self.sourceIDs = sourceIDs; self.shape = shape; self.styleToken = styleToken
    }
}
public struct ChartHitRegion: Sendable, Equatable {
    public var sourceIDs: [ChartRecordID]
    /// Coarse candidate bounds. Family renderers refine curved/ribbon hits.
    public var bounds: ChartRect
    public init(sourceIDs: [ChartRecordID], bounds: ChartRect) { self.sourceIDs = sourceIDs; self.bounds = bounds }
}
public struct ChartLayout: Sendable, Equatable {
    public let primitives: [ChartPrimitive]
    public let hits: [ChartHitRegion]
    public init(primitives: [ChartPrimitive], hits: [ChartHitRegion], for chart: PreparedChart) throws {
        try chartCheck(primitives.count <= ChartLimits.geometryPrimitives && hits.count <= ChartLimits.geometryPrimitives,"layout","geometry budget exceeded")
        try chartCheck(Set(primitives.map(\.id)).count == primitives.count,"layout","duplicate primitive IDs")
        var vertices = 0; var references = 0
        for primitive in primitives {
            try chartText(primitive.id,"layout.id"); try chartText(primitive.styleToken,"layout.styleToken")
            try chartCheck(primitive.sourceIDs.count <= ChartLimits.geometryReferences-references,"layout.sourceIDs","source reference budget exceeded")
            references += primitive.sourceIDs.count
            try chartCheck(primitive.sourceIDs.allSatisfy(chart.recordIDs.contains),"layout.sourceIDs","unknown record in prepared payload/facet")
            let points: [ChartPoint]
            switch primitive.shape {
            case .point(let p): points = [p]
            case .polyline(let p): try chartCheck(p.count >= 2,"layout","polyline needs two points"); points = p
            case .polygon(let p): try chartCheck(p.count >= 3,"layout","polygon needs three points"); points = p
            case .rectangle(let rect): try chartCheck(rect.isValid,"layout","invalid rectangle"); points = []
            case .circle(let center,let radius):
                try chartCheck(radius.isFinite && radius >= 0 && [center.x+radius,center.y+radius,center.x-radius,center.y-radius].allSatisfy(\.isFinite),"layout","invalid circle")
                points = [center]
            case .path(let path):
                try chartCheck(path.count <= ChartLimits.geometryPrimitives && !path.isEmpty,"layout","invalid path size")
                guard case .move = path.first! else { throw ChartIssue(path:"layout",problem:"path must start with move") }
                points = path.flatMap(\.points)
            case .text(let value,let frame):
                try chartText(value,"layout.text",maximum:320,nonempty:false)
                try chartCheck(frame.isValid,"layout","invalid text frame"); points = []
            }
            vertices += points.count
            try chartCheck(vertices <= ChartLimits.geometryPrimitives && points.allSatisfy(\.isFinite),"layout","non-finite or oversized path vertices")
        }
        for hit in hits {
            try chartCheck(hit.sourceIDs.count <= ChartLimits.geometryReferences-references,"layout.hits","source reference budget exceeded")
            references += hit.sourceIDs.count
            try chartCheck(hit.bounds.isValid && !hit.sourceIDs.isEmpty && hit.sourceIDs.allSatisfy(chart.recordIDs.contains),"layout.hits","invalid hit region or foreign record")
        }
        self.primitives = primitives; self.hits = hits
    }
}
