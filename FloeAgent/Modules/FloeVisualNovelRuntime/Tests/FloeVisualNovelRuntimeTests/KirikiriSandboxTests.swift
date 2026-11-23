// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeVisualNovelRuntime

struct KirikiriSandboxTests {
    private func makeDirectories() throws -> (source: URL, saves: URL, work: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-vn-tests-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("game-src", isDirectory: true)
        let saves = base.appendingPathComponent("saves", isDirectory: true)
        let work = base.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("System.title = ...".utf8).write(to: source.appendingPathComponent("startup.tjs"))
        try Data("xp3".utf8).write(to: source.appendingPathComponent("data.xp3"))
        return (source, saves, work)
    }

    @Test func stagingIsolatesGameContentAndLinksPersistentSaves() throws {
        let dirs = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: dirs.work.deletingLastPathComponent()) }
        let sandbox = try KirikiriSandboxBuilder.stage(
            gameRoot: dirs.source, savesDirectory: dirs.saves, workDirectory: dirs.work)
        // Game content is visible inside the sandbox.
        let startup = sandbox.gameRoot.appendingPathComponent("startup.tjs")
        let xp3 = sandbox.gameRoot.appendingPathComponent("data.xp3")
        #expect(FileManager.default.fileExists(atPath: startup.path))
        #expect(FileManager.default.fileExists(atPath: xp3.path))
        try Data("changed".utf8).write(to: startup)
        #expect(try Data(contentsOf: dirs.source.appendingPathComponent("startup.tjs")) == Data("System.title = ...".utf8))
        // savedata resolves to the persistent save directory.
        let savedata = sandbox.gameRoot.appendingPathComponent("savedata")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: savedata.path)
        #expect(URL(fileURLWithPath: destination).standardizedFileURL
            == dirs.saves.standardizedFileURL)
        try sandbox.dispose()
        #expect(!FileManager.default.fileExists(atPath: dirs.work.path))
    }

    @Test func importedSymlinksCannotEscapeTheRunDirectory() throws {
        let dirs = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: dirs.work.deletingLastPathComponent()) }
        let outside = dirs.work.deletingLastPathComponent().appendingPathComponent("other-game.sav")
        try Data("separate".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: dirs.source.appendingPathComponent("other.sav"),
                                                     withDestinationURL: outside)
        #expect(throws: VisualNovelRuntimeError.self) {
            try KirikiriSandboxBuilder.stage(gameRoot: dirs.source, savesDirectory: dirs.saves, workDirectory: dirs.work)
        }
        #expect(!FileManager.default.fileExists(atPath: dirs.work.path))
    }

    @Test func fallbackFontOnlyFillsTheStagedGameMissingItsOwnFont() throws {
        let dirs = try makeDirectories()
        let base = dirs.work.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let bundled = base.appendingPathComponent("bundled.ttf")
        try Data("bundled font".utf8).write(to: bundled)
        let first = try KirikiriSandboxBuilder.stage(
            gameRoot: dirs.source, savesDirectory: dirs.saves, workDirectory: dirs.work, fallbackFont: bundled)
        #expect(try Data(contentsOf: first.gameRoot.appendingPathComponent("default.ttf")) == Data("bundled font".utf8))
        #expect(!FileManager.default.fileExists(atPath: dirs.source.appendingPathComponent("default.ttf").path))
        try first.dispose()

        let provided = dirs.source.appendingPathComponent("default.otf")
        try Data("game font".utf8).write(to: provided)
        let second = try KirikiriSandboxBuilder.stage(
            gameRoot: dirs.source, savesDirectory: dirs.saves, workDirectory: dirs.work, fallbackFont: bundled)
        #expect(try Data(contentsOf: second.gameRoot.appendingPathComponent("default.otf")) == Data("game font".utf8))
        #expect(!FileManager.default.fileExists(atPath: second.gameRoot.appendingPathComponent("default.ttf").path))
    }

    @Test func savesSurviveRestaging() throws {
        // Reopening a game must see the saves the previous run wrote.
        let dirs = try makeDirectories()
        let first = try KirikiriSandboxBuilder.stage(
            gameRoot: dirs.source, savesDirectory: dirs.saves, workDirectory: dirs.work)
        let saveFile = dirs.saves.appendingPathComponent("global.sav")
        try Data("save-bytes".utf8).write(to: saveFile)
        try first.dispose()

        let secondWork = dirs.work.deletingLastPathComponent()
            .appendingPathComponent("work-2", isDirectory: true)
        let second = try KirikiriSandboxBuilder.stage(
            gameRoot: dirs.source, savesDirectory: dirs.saves, workDirectory: secondWork)
        let visible = second.gameRoot.appendingPathComponent("savedata/global.sav")
        let bytes = try Data(contentsOf: visible)
        #expect(String(decoding: bytes, as: UTF8.self) == "save-bytes")
        try second.dispose()
        try FileManager.default.removeItem(at: dirs.work.deletingLastPathComponent())
    }

    @Test func stagingRejectsMissingRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-vn-tests-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: VisualNovelRuntimeError.self) {
            try KirikiriSandboxBuilder.stage(
                gameRoot: base.appendingPathComponent("nope", isDirectory: true),
                savesDirectory: base.appendingPathComponent("saves"),
                workDirectory: base.appendingPathComponent("work"))
        }
    }
}
