// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ChartRecordID: Hashable, Sendable, Codable {
    public let facetPath: [String]
    public let collection: String
    public let id: String
    public init(facetPath: [String] = [], collection: String = "rows", id: String) {
        self.facetPath = facetPath; self.collection = collection; self.id = id
    }
}

public struct PreparedChart: Sendable, Equatable {
    public let document: ChartDocument
    public let descriptor: ChartDescriptor
    public let recordIDs: Set<ChartRecordID>
    public let inputRecordCount: Int
    public let warnings: [ChartIssue]
}

public enum ChartValidator {
    /// Pure, cancellable preparation. It preserves every supplied value and ordering.
    public static func prepare(_ document: ChartDocument) throws -> PreparedChart {
        var context = ChartValidationContext()
        try context.validate(document, path: "chart", facets: [])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(document).count <= ChartLimits.documentBytes else {
            throw ChartIssue(path: "chart", problem: "document exceeds 1 MiB")
        }
        return PreparedChart(document: document, descriptor: ChartCatalog.descriptor(for: document.type),
            recordIDs: context.ids, inputRecordCount: context.count, warnings: context.warnings)
    }
}

func chartCheck(_ condition: Bool, _ path: String, _ problem: String) throws {
    try Task.checkCancellation()
    if !condition { throw ChartIssue(path: path, problem: problem) }
}
func chartFinite(_ value: Double, _ path: String) throws {
    try chartCheck(value.isFinite, path, "must be finite")
}
func chartText(_ value: String, _ path: String, maximum: Int = 100, nonempty: Bool = true) throws {
    try chartCheck((!nonempty || !value.isEmpty) && value.count <= maximum
        && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }, path, "invalid or oversized text")
}
func chartNearlyEqual(_ a: Double, _ b: Double) -> Bool {
    a == b || abs(a - b) <= max(1, max(abs(a), abs(b))) * 1e-9
}

struct ChartValidationContext {
    var count = 0
    var seriesCount = 0
    var ids: Set<ChartRecordID> = []
    var warnings: [ChartIssue] = []
    mutating func consume(_ amount: Int, at path: String) throws {
        try chartCheck(amount >= 0 && amount <= ChartLimits.inputRecords - count, path,
                       "total input exceeds 2000 records/samples (including facets)")
        count += amount
        try Task.checkCancellation()
    }
    mutating func identify(_ values: [String], collection: String = "rows", path: String, facets: [String]) throws {
        try chartCheck(Set(values).count == values.count, path, "record IDs must be unique")
        for (index, id) in values.enumerated() {
            try chartText(id, "\(path)[\(index)].id")
            ids.insert(.init(facetPath: facets, collection: collection, id: id))
        }
    }
    mutating func validate(_ document: ChartDocument, path: String, facets: [String]) throws {
        try Task.checkCancellation()
        try chartCheck(document.schemaVersion == 2, path + ".schemaVersion", "only version 2 is accepted here")
        try chartCheck(facets.count <= 1, path, "nested small multiples are not supported")
        if let value = document.title { try chartText(value, path + ".title", maximum: 160, nonempty: false) }
        if let value = document.subtitle { try chartText(value, path + ".subtitle", maximum: 320, nonempty: false) }
        let descriptor = ChartCatalog.descriptor(for: document.type)
        try chartCheck(descriptor.dataKinds.contains(document.data.kind), path + ".data.kind", "incompatible with \(document.type.rawValue)")
        try chartCheck(document.axes.count <= 4, path + ".axes", "at most four axes")
        try chartCheck(Set(document.axes.map(\.id)).count == document.axes.count, path + ".axes", "duplicate axis ID")
        for axis in document.axes {
            try chartText(axis.id, path + ".axes.id")
            if let value = axis.title { try chartText(value, path + ".axes.title", maximum: 160, nonempty: false) }
            if let value = axis.unit { try chartText(value, path + ".axes.unit", maximum: 64, nonempty: false) }
            try chartCheck((axis.lower == nil) == (axis.upper == nil), path + ".axes.domain", "lower and upper must appear together")
            if let lower = axis.lower, let upper = axis.upper {
                try chartCheck(axis.kind != .categorical && lower.isFinite && upper.isFinite && lower < upper,
                               path + ".axes.domain", "numeric/time domain must be finite and increasing")
            }
        }
        try chartCheck(document.series.count <= ChartLimits.series, path + ".series", "at most 16 series")
        let knownSeries = Set(document.series.map(\.id))
        try chartCheck(knownSeries.count == document.series.count, path + ".series", "duplicate series ID")
        for series in document.series {
            try chartText(series.id, path + ".series.id"); try chartText(series.name, path + ".series.name")
            if let axis = series.axisID {
                try chartCheck(document.axes.contains { $0.id == axis }, path + ".series.axisID", "unknown axis")
            }
            try chartCheck(series.mark == nil || document.type == .combo, path + ".series.mark", "marks are only declared for combo charts")
        }
        if document.type == .combo {
            try chartCheck(document.series.contains { $0.mark == .line }
                && document.series.contains { $0.mark == .bar || $0.mark == .column }
                && document.series.allSatisfy { $0.axisID != nil }, path + ".series", "combo requires line and bar/column series with axis assignment")
        }
        try validateOptions(document, path: path)
        if let provenance = document.provenance {
            if let ref = provenance.sourceReference { try chartText(ref, path + ".provenance.sourceReference", maximum: 256) }
            if let method = provenance.method { try chartText(method, path + ".provenance.method", maximum: 320) }
        }
        let actualSeries = try validatePayload(document, path: path, facets: facets)
        seriesCount += max(document.series.count, actualSeries)
        try chartCheck(seriesCount <= ChartLimits.series, path + ".series", "total series exceeds 16, including facets")
    }
    func validateOptions(_ d: ChartDocument, path: String) throws {
        let o = d.options
        func applicable(_ exists: Bool, _ allowed: [ChartKind], _ key: String) throws {
            try chartCheck(!exists || allowed.contains(d.type), path + ".options." + key, "not applicable to this chart type")
        }
        try applicable(o.orientation != nil, [.column,.bar,.groupedBar,.stackedBar,.percentStackedBar], "orientation")
        try applicable(o.baseline != nil, [.line,.column,.bar,.groupedBar,.stackedBar,.area,.waterfall], "baseline")
        if let baseline = o.baseline { try chartFinite(baseline, path + ".options.baseline") }
        try applicable(o.binEdges != nil || o.binCount != nil || o.histogramMeasure != nil, [.histogram], "bins")
        try chartCheck(o.binEdges == nil || o.binCount == nil, path + ".options", "use binEdges or binCount, not both")
        if let edges = o.binEdges {
            try chartCheck((2...201).contains(edges.count) && edges.allSatisfy(\.isFinite)
                && zip(edges,edges.dropFirst()).allSatisfy { $0.0 < $0.1 }, path + ".options.binEdges", "need 2...201 finite increasing edges")
        }
        if let bins = o.binCount { try chartCheck((1...200).contains(bins), path + ".options.binCount", "must be 1...200") }
        try applicable(o.bandwidth != nil || o.densityNormalized != nil, [.violin,.density], "density")
        if let bandwidth = o.bandwidth { try chartCheck(bandwidth.isFinite && bandwidth > 0, path + ".options.bandwidth", "must be finite and positive") }
        try applicable(o.confidenceLevel != nil || o.intervalMeaning != nil, [.errorBars,.confidenceBand], "interval")
        if let level = o.confidenceLevel { try chartCheck(level.isFinite && level > 0 && level < 1, path + ".options.confidenceLevel", "must be between 0 and 1") }
        if let method = o.method { try chartText(method, path + ".options.method", maximum: 320) }
        if d.type == .errorBars { try chartCheck(o.intervalMeaning != nil, path + ".options.intervalMeaning", "declare standardDeviation, standardError, confidence or custom") }
        if d.type == .confidenceBand || o.intervalMeaning == .confidence {
            try chartCheck(o.confidenceLevel != nil && o.method?.isEmpty == false, path + ".options", "confidence requires a level and method; bounds alone are not confidence")
        }
        try applicable(o.movingAverages != nil, [.priceVolume], "movingAverages")
        if d.type == .priceVolume {
            try chartCheck(o.movingAverages?.isEmpty == false, path + ".options.movingAverages", "declare SMA/EMA periods")
        }
        if let averages = o.movingAverages {
            try chartCheck(averages.count <= 8, path + ".options.movingAverages", "at most 8 moving averages")
            for ma in averages {
                try chartCheck((1...2000).contains(ma.period), path + ".options.movingAverages.period", "must be 1...2000")
                try chartCheck(ma.method != .ema || ma.seed != nil, path + ".options.movingAverages.seed", "EMA seed must be explicit")
            }
        }
        try applicable(o.angleUnit != nil || o.clockwise != nil || o.zeroAngle != nil, [.polar,.radar], "angle")
        if d.type == .polar { try chartCheck(o.angleUnit != nil, path + ".options.angleUnit", "declare degrees or radians") }
        if let angle = o.zeroAngle { try chartFinite(angle, path + ".options.zeroAngle") }
        try applicable(o.holeRatio != nil, [.donut], "holeRatio")
        if let hole = o.holeRatio { try chartCheck(hole.isFinite && hole > 0 && hole < 1, path + ".options.holeRatio", "must be between 0 and 1") }
        if let zone = o.timeZone { try chartCheck(TimeZone(identifier: zone) != nil, path + ".options.timeZone", "unknown IANA time zone") }
        try applicable(o.weekStart != nil || o.aggregation != nil, [.calendarHeatmap], "calendar")
        if let week = o.weekStart { try chartCheck((1...7).contains(week), path + ".options.weekStart", "weekday must be 1...7 (Sunday=1)") }
        try applicable(o.sharedAxes != nil, [.smallMultiples], "sharedAxes")
    }
    func coordinate(_ value: ChartCoordinate, path: String) throws {
        switch value {
        case .number(let x): try chartFinite(x,path)
        case .category(let text): try chartText(text,path)
        case .instant(let value): _ = try ChartDates.instant(value, path: path)
        case .localDate(let value): _ = try ChartDates.localDate(value, path: path)
        }
    }
    func series(_ id: String?, document: ChartDocument, path: String) throws {
        if let id { try chartText(id,path) }
        if !document.series.isEmpty {
            try chartCheck(id.map { value in document.series.contains { $0.id == value } } ?? (document.series.count == 1),
                           path, "unknown or ambiguous series ID")
        }
    }
}

public enum ChartDates {
    public static func instant(_ text: String, path: String = "time") throws -> Date {
        try chartCheck(text.utf8.count <= 64 && text.range(of: #"T.*(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
                       path, "timestamp needs ISO8601 time and explicit UTC offset")
        _ = try localDate(String(text.prefix(10)), path: path)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw ChartIssue(path: path, problem: "invalid ISO8601 timestamp") }
        return date
    }
    public static func localDate(_ text: String, timeZone: String) throws -> Date {
        let utc = try localDate(text)
        guard let zone = TimeZone(identifier:timeZone) else { throw ChartIssue(path:"date.timeZone",problem:"unknown time zone") }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let components = calendar.dateComponents([.year,.month,.day],from:utc)
        calendar.timeZone = zone
        guard let result = calendar.date(from:components), calendar.dateComponents([.year,.month,.day],from:result) == components else {
            throw ChartIssue(path:"date",problem:"local date does not exist in this time zone")
        }
        return result
    }
    public static func localDate(_ text: String, path: String = "date") throws -> Date {
        try chartCheck(text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, path, "date must be YYYY-MM-DD")
        let parts = text.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let result = calendar.date(from: components) else {
            throw ChartIssue(path: path, problem: "invalid Gregorian calendar date")
        }
        let actual = calendar.dateComponents([.year,.month,.day], from: result)
        guard actual.year == parts[0] && actual.month == parts[1] && actual.day == parts[2] else {
            throw ChartIssue(path: path, problem: "invalid Gregorian calendar date")
        }
        return result
    }
}
