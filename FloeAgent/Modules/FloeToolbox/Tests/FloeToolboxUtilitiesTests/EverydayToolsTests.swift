import Foundation
import Testing
import FloeToolboxCore
@testable import FloeToolboxUtilities

private func eval(_ expression: String, _ mode: EverydayCalculator.AngleMode = .degrees) throws -> Double {
    try EverydayCalculator.evaluate(expression, angleMode: mode)
}

// MARK: - Calculator precedence and functions

@Test func calculatorHonorsPrecedenceParenthesesAndRightAssociativePower() throws {
    #expect(try eval("2+3*4") == 14)
    #expect(try eval("(2+3)*4") == 20)
    #expect(try eval("10/4") == 2.5)
    #expect(try eval("2^3^2") == 512)
    #expect(try eval("(2^3)^2") == 64)
    #expect(try eval("100-20-5") == 75)
    #expect(try eval("100/10/2") == 5)
}

@Test func calculatorUnaryMinusBindsLooserThanPower() throws {
    #expect(try eval("-2^2") == -4)
    #expect(try eval("2^-2") == 0.25)
    #expect(try eval("(-2)^2") == 4)
    #expect(try eval("--5") == 5)
    #expect(try eval("-(3+4)") == -7)
    #expect(try eval("2*-3") == -6)
}

@Test func calculatorTrigonometryRespectsAngleMode() throws {
    #expect(abs(try eval("sin(30)") - 0.5) < 1e-12)
    #expect(abs(try eval("cos(60)") - 0.5) < 1e-12)
    #expect(abs(try eval("tan(45)") - 1) < 1e-12)
    #expect(abs(try eval("sin(90)") - 1) < 1e-12)
    #expect(abs(try eval("sin(1.5707963267948966)", .radians) - 1) < 1e-9)
    #expect(abs(try eval("asin(0.5)") - 30) < 1e-9)
    #expect(abs(try eval("acos(0.5)") - 60) < 1e-9)
    #expect(abs(try eval("atan(1)") - 45) < 1e-9)
    #expect(abs(try eval("asin(1)", .radians) - Double.pi / 2) < 1e-12)
}

@Test func calculatorRootsLogarithmsAndConstants() throws {
    #expect(abs(try eval("sqrt(2)") - 1.4142135623730951) < 1e-12)
    #expect(try eval("sqrt(16)") == 4)
    #expect(try eval("cbrt(27)") == 3)
    #expect(try eval("log(1000)") == 3)
    #expect(abs(try eval("ln(e)") - 1) < 1e-12)
    #expect(abs(try eval("exp(0)") - 1) < 1e-12)
    #expect(abs(try eval("pi") - Double.pi) < 1e-15)
    #expect(try eval("2*pi*0") == 0)
    #expect(abs(try eval("sqrt(2)^2") - 2) < 1e-12)
    #expect(try eval("2e3") == 2000)
    #expect(try eval("1.5e-2") == 0.015)
}

@Test func calculatorRejectsInvalidSyntaxEmptyAndAmbiguousInput() throws {
    #expect(throws: ToolboxError.self) { try eval("") }
    #expect(throws: ToolboxError.self) { try eval("2+") }
    #expect(throws: ToolboxError.self) { try eval("((2)") }
    #expect(throws: ToolboxError.self) { try eval("5..2") }
    #expect(throws: ToolboxError.self) { try eval("abc") }
    #expect(throws: ToolboxError.self) { try eval("1,5") }
    #expect(throws: ToolboxError.self) { try eval("2 3") }
    #expect(throws: ToolboxError.self) { try eval("sin()") }
    #expect(throws: ToolboxError.self) { try eval("pi(2)") }
    #expect(throws: ToolboxError.self) { try eval("(2") }
}

@Test func calculatorRejectsDivisionByZeroDomainViolationsAndNonFiniteResults() throws {
    #expect(throws: ToolboxError.self) { try eval("1/0") }
    #expect(throws: ToolboxError.self) { try eval("sqrt(-1)") }
    #expect(throws: ToolboxError.self) { try eval("log(0)") }
    #expect(throws: ToolboxError.self) { try eval("ln(-5)") }
    #expect(throws: ToolboxError.self) { try eval("asin(2)") }
    #expect(throws: ToolboxError.self) { try eval("(-4)^0.5") }
    #expect(throws: ToolboxError.self) { try eval("tan(90)") }
    #expect(throws: ToolboxError.self) { try eval("exp(10000)") }
    #expect(throws: ToolboxError.self) { try eval("1e308*10") }
    #expect(throws: ToolboxError.self) { try eval("1e309") }
    #expect(throws: ToolboxError.self) { try eval("1e400") }
}

// MARK: - Number text

@Test func numberTextFormatsLocalizedAndScientificValues() {
    let posix = Locale(identifier: "en_US_POSIX")
    #expect(EverydayNumberText.calculatorString(for: 0.1 + 0.2, locale: posix) == "0.3")
    #expect(EverydayNumberText.calculatorString(for: 1.0 / 3.0, locale: posix).hasPrefix("0.3333333333"))
    #expect(EverydayNumberText.calculatorString(for: -0.0, locale: posix) == "0")
    #expect(EverydayNumberText.calculatorString(for: 4, locale: posix) == "4")
    #expect(EverydayNumberText.calculatorString(for: 1e-7, locale: posix) == "1e-7")
    #expect(EverydayNumberText.calculatorString(for: 2.5e16, locale: posix) == "2.5e16")
    #expect(EverydayNumberText.calculatorString(for: 1152921504606846976, locale: posix) == "1.1529215e18")
    #expect(EverydayNumberText.calculatorString(for: 1125899906842624, locale: posix) == "1125899906842624")
    let german = Locale(identifier: "de_DE")
    #expect(EverydayNumberText.calculatorString(for: 1.5, locale: german) == "1,5")
    #expect(EverydayNumberText.calculatorString(for: .infinity, locale: posix) == "Error")
}

@Test func canonicalInputLocalizesSeparatorsAndTypographicOperators() {
    #expect(EverydayNumberText.canonical("1,5+2", locale: Locale(identifier: "de_DE")) == "1.5+2")
    #expect(EverydayNumberText.canonical("1.5+2", locale: Locale(identifier: "en_US_POSIX")) == "1.5+2")
    #expect(EverydayNumberText.canonical("2\u{2212}3\u{00D7}4\u{00F7}2") == "2-3*4/2")
}

// MARK: - History store

@Test func historyPersistsBoundedEntriesAndClears() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("everyday-tools-tests/\(UUID().uuidString)/history.json")
    let store = EverydayCalculatorHistoryStore(url: url, maximumCount: 3)
    for index in 0..<5 {
        _ = try await store.add(.init(expression: "\(index)+1", result: "\(index + 1)"))
    }
    let values = try await store.load()
    #expect(values.count == 3)
    #expect(values.first?.expression == "4+1")
    try await store.removeAll()
    #expect(try await store.load().isEmpty)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func historyRejectsOversizedEntries() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("everyday-tools-tests/\(UUID().uuidString)/history.json")
    let store = EverydayCalculatorHistoryStore(url: url)
    await #expect(throws: ToolboxError.self) {
        _ = try await store.add(.init(expression: String(repeating: "1", count: 2048), result: "2"))
    }
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

// MARK: - Unit conversion

@Test func unitConversionsCoverAllCoreCategories() throws {
    let length = EverydayUnitConverter.units(for: .length)
    let m = length.first { $0.id == "m" }!, km = length.first { $0.id == "km" }!
    #expect(try EverydayUnitConverter.convert(2.5, from: km, to: m) == 2500)

    let area = EverydayUnitConverter.units(for: .area)
    #expect(try EverydayUnitConverter.convert(1, from: area.first { $0.id == "km2" }!, to: area.first { $0.id == "m2" }!) == 1_000_000)

    let volume = EverydayUnitConverter.units(for: .volume)
    #expect(try EverydayUnitConverter.convert(1, from: volume.first { $0.id == "l" }!, to: volume.first { $0.id == "m3" }!) == 0.001)

    let pressure = EverydayUnitConverter.units(for: .pressure)
    #expect(try EverydayUnitConverter.convert(1, from: pressure.first { $0.id == "bar" }!, to: pressure.first { $0.id == "pa" }!) == 100_000)
    #expect(abs(try EverydayUnitConverter.convert(1, from: pressure.first { $0.id == "atm" }!, to: pressure.first { $0.id == "psi" }!) - 14.6959) < 0.001)

    let mass = EverydayUnitConverter.units(for: .mass)
    #expect(try EverydayUnitConverter.convert(1, from: mass.first { $0.id == "kg" }!, to: mass.first { $0.id == "g" }!) == 1000)

    let speed = EverydayUnitConverter.units(for: .speed)
    #expect(abs(try EverydayUnitConverter.convert(1, from: speed.first { $0.id == "ms" }!, to: speed.first { $0.id == "kmh" }!) - 3.6) < 1e-12)
}

@Test func temperatureConversionIsAffineAndRoundtrips() throws {
    let units = EverydayUnitConverter.units(for: .temperature)
    let c = units.first { $0.id == "c" }!, f = units.first { $0.id == "f" }!, k = units.first { $0.id == "k" }!
    #expect(abs(try EverydayUnitConverter.convert(100, from: c, to: f) - 212) < 1e-9)
    #expect(abs(try EverydayUnitConverter.convert(32, from: f, to: c) - 0) < 1e-9)
    #expect(abs(try EverydayUnitConverter.convert(300, from: k, to: f) - 80.33) < 0.01)
    #expect(abs(try EverydayUnitConverter.convert(-40, from: c, to: f) - (-40)) < 1e-9)
    let roundtrip = try EverydayUnitConverter.convert(try EverydayUnitConverter.convert(37, from: c, to: f), from: f, to: c)
    #expect(abs(roundtrip - 37) < 1e-9)
}

@Test func unitConversionRejectsIncompatibleUnitsAndInvalidValues() throws {
    let length = EverydayUnitConverter.units(for: .length)
    let temperature = EverydayUnitConverter.units(for: .temperature)
    let m = length.first { $0.id == "m" }!, celsius = temperature.first { $0.id == "c" }!, kelvin = temperature.first { $0.id == "k" }!
    #expect(throws: ToolboxError.self) { try EverydayUnitConverter.convert(1, from: m, to: celsius) }
    #expect(throws: ToolboxError.self) { try EverydayUnitConverter.convert(.nan, from: m, to: m) }
    #expect(throws: ToolboxError.self) { try EverydayUnitConverter.convert(.infinity, from: m, to: m) }
    #expect(throws: ToolboxError.self) { try EverydayUnitConverter.convert(-500, from: celsius, to: kelvin) }
    #expect(throws: ToolboxError.self) { try EverydayUnitConverter.convert(-1000, from: kelvin, to: celsius) }
}

// MARK: - Ruler calibration and geometry

@Test func calibrationDerivesPointsPerMillimeterFromKnownReference() throws {
    let calibration = try EverydayRulerGeometry.calibrate(knownMillimeters: 85.60, measuredPoints: 322.0, nativeScale: 2, viewportKey: "a")
    #expect(abs(calibration.pointsPerMillimeter - 322.0 / 85.60) < 1e-12)
    #expect(try EverydayRulerGeometry.millimeters(for: 322.0, using: calibration) == 85.60)
    #expect(try EverydayRulerGeometry.points(forMillimeters: 42.8, using: calibration) == 161.0)
    #expect(try EverydayRulerGeometry.distanceMillimeters(from: .init(x: 0, y: 0), to: .init(x: 161, y: 0), using: calibration) == 42.8)
}

@Test func calibrationRejectsInvalidMeasurements() throws {
    #expect(throws: ToolboxError.self) { try EverydayRulerGeometry.calibrate(knownMillimeters: 0, measuredPoints: 100, nativeScale: 2, viewportKey: "a") }
    #expect(throws: ToolboxError.self) { try EverydayRulerGeometry.calibrate(knownMillimeters: 85.6, measuredPoints: 0, nativeScale: 2, viewportKey: "a") }
    #expect(throws: ToolboxError.self) { try EverydayRulerGeometry.calibrate(knownMillimeters: 85.6, measuredPoints: .nan, nativeScale: 2, viewportKey: "a") }
    #expect(throws: ToolboxError.self) { try EverydayRulerGeometry.calibrate(knownMillimeters: 85.6, measuredPoints: 100, nativeScale: 0, viewportKey: "a") }
    let calibration = try EverydayRulerGeometry.calibrate(knownMillimeters: 85.60, measuredPoints: 322.0, nativeScale: 2, viewportKey: "a")
    #expect(throws: ToolboxError.self) { try EverydayRulerGeometry.millimeters(for: .infinity, using: calibration) }
}

@Test func calibrationCompatibilityBindsScaleAndViewport() throws {
    let calibration = try EverydayRulerGeometry.calibrate(knownMillimeters: 85.60, measuredPoints: 322.0, nativeScale: 2, viewportKey: "1024x768")
    #expect(calibration.isCompatible(nativeScale: 2, viewportKey: "1024x768"))
    #expect(!calibration.isCompatible(nativeScale: 3, viewportKey: "1024x768"))
    #expect(!calibration.isCompatible(nativeScale: 2, viewportKey: "768x1024"))
    #expect(calibration.isCompatible(nativeScale: 2.005, viewportKey: "1024x768"))
}

@Test func angleGeometryReportsFiniteRangeAndRejectsDegenerateRays() throws {
    #expect(abs(try EverydayRulerGeometry.angleDegrees(vertex: .init(x: 0, y: 0), first: .init(x: 1, y: 0), second: .init(x: 0, y: 1)) - 90) < 1e-9)
    #expect(abs(try EverydayRulerGeometry.angleDegrees(vertex: .init(x: 2, y: 2), first: .init(x: 2, y: 0), second: .init(x: 4, y: 2)) - 90) < 1e-9)
    #expect(try EverydayRulerGeometry.angleDegrees(vertex: .init(x: 0, y: 0), first: .init(x: 1, y: 1), second: .init(x: 2, y: 2)) < 1e-9)
    #expect(abs(try EverydayRulerGeometry.angleDegrees(vertex: .init(x: 0, y: 0), first: .init(x: 1, y: 0), second: .init(x: -1, y: 0)) - 180) < 1e-9)
    #expect(throws: ToolboxError.self) { try EverydayRulerGeometry.angleDegrees(vertex: .init(x: 0, y: 0), first: .init(x: 0, y: 0), second: .init(x: 1, y: 0)) }
    #expect(throws: ToolboxError.self) { try EverydayRulerGeometry.angleDegrees(vertex: .init(x: CGFloat.nan, y: 0), first: .init(x: 1, y: 0), second: .init(x: 0, y: 1)) }
    #expect(throws: ToolboxError.self) { try EverydayRulerGeometry.distanceMillimeters(from: .init(x: CGFloat.infinity, y: 0), to: .init(x: 0, y: 0), using: try EverydayRulerGeometry.calibrate(knownMillimeters: 85.6, measuredPoints: 300, nativeScale: 2, viewportKey: "a")) }
}

@Test func calibrationStorePersistsAndClears() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("everyday-tools-tests/\(UUID().uuidString)/calibration.json")
    let store = EverydayRulerCalibrationStore(url: url)
    #expect(try await store.load() == nil)
    let calibration = try EverydayRulerGeometry.calibrate(knownMillimeters: 85.60, measuredPoints: 322.0, nativeScale: 2, viewportKey: "a")
    try await store.save(calibration)
    #expect(try await store.load() == calibration)
    try await store.clear()
    #expect(try await store.load() == nil)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test func corruptHistoryAndCalibrationFilesThrowAndAreNeverOverwritten() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("everyday-tools-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let historyURL = dir.appendingPathComponent("history.json")
    try Data("not json".utf8).write(to: historyURL)
    let history = EverydayCalculatorHistoryStore(url: historyURL)
    await #expect(throws: ToolboxError.corruptStore) { _ = try await history.load() }
    // Adding on top of a corrupt archive fails closed and preserves the file.
    await #expect(throws: ToolboxError.self) { _ = try await history.add(.init(expression: "1+1", result: "2")) }
    #expect(String(data: try Data(contentsOf: historyURL), encoding: .utf8) == "not json")

    let calibrationURL = dir.appendingPathComponent("calibration.json")
    try Data("garbage".utf8).write(to: calibrationURL)
    let calibration = EverydayRulerCalibrationStore(url: calibrationURL)
    await #expect(throws: ToolboxError.corruptStore) { _ = try await calibration.load() }
    #expect(String(data: try Data(contentsOf: calibrationURL), encoding: .utf8) == "garbage")
    try? FileManager.default.removeItem(at: dir)
}
