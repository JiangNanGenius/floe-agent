// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameInstrumentation

private let autoloadLine = "FloeDeveloper=\"*res://floe_developer.gd\""

private func parse(_ data: Data) throws -> GodotProjectFile {
    try GodotProjectFile.parse(data, maximumBytes: 1_048_576)
}

private func parsedError(_ body: () throws -> Void) -> GameDeveloperInstrumentationError? {
    do {
        try body()
        return nil
    } catch let error as GameDeveloperInstrumentationError {
        return error
    } catch {
        return nil
    }
}

@Test func godotPatchAppendsAValidAutoloadSection() throws {
    let input = Data("config_version=5\n\n[application]\nconfig/name=\"Fixture\"\n".utf8)
    let file = try parse(input)
    #expect(file.changed)
    #expect(file.autoloadValue == nil)
    #expect(file.lineEnding == .lf)
    let patched = try #require(file.patchedData)
    let text = String(decoding: patched, as: UTF8.self)
    #expect(text.hasPrefix(String(decoding: input, as: UTF8.self)))
    #expect(text.contains("[autoload]"))
    #expect(text.contains(autoloadLine))
    #expect(text.hasSuffix("\n"))
    let verified = try parse(patched)
    #expect(verified.autoloadValue == "*res://floe_developer.gd")
    #expect(!verified.changed)
}

@Test func godotPatchPreservesOtherAutoloadsAndSectionOrder() throws {
    let input = Data("""
    config_version=5

    [autoload]

    Existing="*res://existing.gd"

    [rendering]
    renderer/rendering_method="gl_compatibility"
    """.utf8)
    let file = try parse(input)
    let patched = try #require(file.patchedData)
    let text = String(decoding: patched, as: UTF8.self)
    #expect(text.contains("Existing=\"*res://existing.gd\""))
    #expect(text.contains(autoloadLine))
    let existing = try #require(text.range(of: "Existing="))
    let floe = try #require(text.range(of: "FloeDeveloper="))
    let rendering = try #require(text.range(of: "[rendering]"))
    #expect(existing.lowerBound < floe.lowerBound)
    #expect(floe.lowerBound < rendering.lowerBound)
    #expect(text.components(separatedBy: "FloeDeveloper=").count == 2)
}

@Test func godotPatchPreservesBOMAndCRLF() throws {
    let input = InstrumentationFixture.godotProject(
        autoloads: ["Existing=\"*res://existing.gd\""],
        lineEnding: "\r\n", bom: true)
    let file = try parse(input)
    #expect(file.hadBOM)
    #expect(file.lineEnding == .crlf)
    let patched = try #require(file.patchedData)
    #expect(patched.starts(with: Data([0xEF, 0xBB, 0xBF])))
    let text = String(decoding: patched, as: UTF8.self)
    #expect(text.contains(autoloadLine + "\r\n"))
    #expect(text.contains("Existing=\"*res://existing.gd\"\r\n"))
    #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    // Both a new section and an unterminated existing section retain every
    // original byte and add only CRLF line separators.
    let noSection = InstrumentationFixture.godotProject(lineEnding: "\r\n", bom: true)
    let unterminated = Data(input.dropLast(2))
    for variant in [noSection, unterminated] {
        let result = try parse(variant)
        let output = try #require(result.patchedData)
        let value = String(decoding: output, as: UTF8.self)
        #expect(!value.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(output.starts(with: Data([0xEF, 0xBB, 0xBF])))
        #expect(try parse(output).patchedData == nil)
    }
}

@Test func godotExactAutoloadIsIdempotent() throws {
    let input = InstrumentationFixture.godotProject(autoloads: [autoloadLine])
    let file = try parse(input)
    #expect(!file.changed)
    #expect(file.patchedData == nil)
    #expect(file.autoloadValue == "*res://floe_developer.gd")
}

@Test func godotConflictingAutoloadIsRejected() throws {
    let input = InstrumentationFixture.godotProject(
        autoloads: ["FloeDeveloper=\"*res://other.gd\""])
    let error = parsedError { _ = try parse(input) }
    guard let error else { Issue.record("expected conflictingAutoload"); return }
    guard case .conflictingAutoload(let key, _) = error else {
        Issue.record("expected conflictingAutoload, got \(error)")
        return
    }
    #expect(key == "FloeDeveloper")
}

@Test func godotDuplicateAutoloadKeyIsRejected() throws {
    let input = InstrumentationFixture.godotProject(
        autoloads: [autoloadLine, autoloadLine])
    let error = parsedError { _ = try parse(input) }
    guard let error else { Issue.record("expected conflictingAutoload"); return }
    guard case .conflictingAutoload(let key, let detail) = error else {
        Issue.record("expected conflictingAutoload, got \(error)")
        return
    }
    #expect(key == "FloeDeveloper")
    #expect(detail.contains("more than once"))
}

@Test func godot3ConfigVersionIsRejected() throws {
    let input = InstrumentationFixture.godotProject(configVersion: 4)
    let error = parsedError { _ = try parse(input) }
    guard let error else { Issue.record("expected unsupportedEngineVersion"); return }
    guard case .unsupportedEngineVersion(.godot, let detail) = error else {
        Issue.record("expected unsupportedEngineVersion, got \(error)")
        return
    }
    #expect(detail.contains("config_version=4"))
}

@Test func godotMissingConfigVersionIsRejected() throws {
    let input = Data("[application]\nconfig/name=\"Fixture\"\n".utf8)
    let error = parsedError { _ = try parse(input) }
    guard let error else { Issue.record("expected unsupportedEngineVersion"); return }
    guard case .unsupportedEngineVersion(.godot, _) = error else {
        Issue.record("expected unsupportedEngineVersion, got \(error)")
        return
    }
}

@Test func godotLoneCarriageReturnIsRejected() throws {
    let input = Data("config_version=5\rfoo=1\n".utf8)
    let error = parsedError { _ = try parse(input) }
    guard let error else { Issue.record("expected invalidProjectFile"); return }
    guard case .invalidProjectFile(_) = error else {
        Issue.record("expected invalidProjectFile, got \(error)")
        return
    }
}

@Test func godotPatchAddsATrailingNewlineWhenMissing() throws {
    let input = Data("config_version=5".utf8)
    let file = try parse(input)
    let patched = try #require(file.patchedData)
    #expect(patched.last == 0x0A)
    let verified = try parse(patched)
    #expect(verified.autoloadValue == "*res://floe_developer.gd")
}

@Test func godotPatchHandlesAutoloadSectionAtEOFWithoutNewline() throws {
    let input = Data("config_version=5\n\n[autoload]\nOther=\"*res://other.gd\"".utf8)
    let file = try parse(input)
    let patched = try #require(file.patchedData)
    let text = String(decoding: patched, as: UTF8.self)
    #expect(text.contains("Other=\"*res://other.gd\"\n"))
    #expect(text.contains(autoloadLine))
    #expect(text.hasSuffix("\n"))
}

@Test func godotDuplicateAutoloadSectionIsRejected() throws {
    let input = Data("""
    config_version=5

    [autoload]
    A="*res://a.gd"

    [autoload]
    B="*res://b.gd"
    """.utf8)
    let error = parsedError { _ = try parse(input) }
    guard let error else { Issue.record("expected invalidProjectFile"); return }
    guard case .invalidProjectFile(let detail) = error else {
        Issue.record("expected invalidProjectFile, got \(error)")
        return
    }
    #expect(detail.contains("duplicate [autoload]"))
}
