#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

/// Pure-logic tests for the small POSIX utilities the app-side shell
/// registry adds (id/cut/locale/basename/dirname/true/false). The handlers
/// stay thin; these tests pin the parsing and formatting rules that the
/// device report (v3) asked to become real commands.
@Suite("FloeApp.ShellCoreUtilities")
struct ShellCoreUtilityTests {

    // MARK: cut

    @Test func cutParsesCharacterRangesWithOpenEnds() throws {
        let spec = try FloeShellCoreUtilities.parseCut(arguments: ["cut", "-c", "1-3,5-"]).get()
        #expect(spec.mode == .characters)
        #expect(spec.ranges == [1...3, 5...Int.max])
    }

    @Test func cutRejectsDecreasingRanges() {
        if case .success = FloeShellCoreUtilities.parseCut(arguments: ["cut", "-c", "5-2"]) {
            Issue.record("decreasing range must fail")
        }
    }

    @Test func cutRequiresSingleMode() {
        if case .success = FloeShellCoreUtilities.parseCut(arguments: ["cut", "-c", "1", "-f", "2"]) {
            Issue.record("mixed -c/-f must fail")
        }
    }

    @Test func cutAppliesFieldSelectionWithDelimiter() throws {
        let spec = try FloeShellCoreUtilities.parseCut(arguments: ["cut", "-d:", "-f", "1,3"]).get()
        let output = FloeShellCoreUtilities.applyCut("a:b:c\nd:e:f\n", spec: spec)
        #expect(output == "a:c\nd:f\n")
    }

    @Test func cutSuppressesLinesWithoutDelimiterOnlyWithFlag() throws {
        let plain = try FloeShellCoreUtilities.parseCut(arguments: ["cut", "-d:", "-f", "2"]).get()
        #expect(FloeShellCoreUtilities.applyCut("no-delimiter\na:b\n", spec: plain) == "no-delimiter\nb\n")
        let suppressed = try FloeShellCoreUtilities.parseCut(arguments: ["cut", "-s", "-d:", "-f", "2"]).get()
        #expect(FloeShellCoreUtilities.applyCut("no-delimiter\na:b\n", spec: suppressed) == "b\n")
    }

    @Test func cutCharacterModeSelectsOncePerPosition() throws {
        let spec = try FloeShellCoreUtilities.parseCut(arguments: ["cut", "-c", "2-4,3-5"]).get()
        #expect(FloeShellCoreUtilities.applyCut("abcdefgh\n", spec: spec) == "bcde\n")
    }

    // MARK: basename / dirname

    @Test func basenameStripsDirectoriesTrailingSlashesAndSuffix() {
        #expect(FloeShellCoreUtilities.basename("/usr/lib/", suffix: nil) == "lib")
        #expect(FloeShellCoreUtilities.basename("notes.txt", suffix: ".txt") == "notes")
        #expect(FloeShellCoreUtilities.basename("notes.txt", suffix: "notes.txt") == "notes.txt")
        #expect(FloeShellCoreUtilities.basename("///", suffix: nil) == "/")
        #expect(FloeShellCoreUtilities.basename("", suffix: nil) == "")
    }

    @Test func dirnameFindsDirectoryPart() {
        #expect(FloeShellCoreUtilities.dirname("/usr/lib/notes.txt") == "/usr/lib")
        #expect(FloeShellCoreUtilities.dirname("notes.txt") == ".")
        #expect(FloeShellCoreUtilities.dirname("/") == "/")
        #expect(FloeShellCoreUtilities.dirname("usr/") == ".")
        #expect(FloeShellCoreUtilities.dirname("/usr/") == "/")
    }

    // MARK: locale

    @Test func localeReportResolvesCategoriesWithLCAllOverride() {
        let environment = ["LANG": "en_US.UTF-8", "LC_TIME": "zh_CN.UTF-8", "LC_ALL": "ja_JP.UTF-8"]
        let report = FloeShellCoreUtilities.localeReport(arguments: ["locale"], environment: environment)
        #expect(report.code == 0)
        #expect(report.text.contains("LC_TIME=ja_JP.UTF-8"))
        #expect(report.text.contains("LANG=en_US.UTF-8"))
    }

    @Test func localeReportRejectsUnknownCategories() {
        let report = FloeShellCoreUtilities.localeReport(arguments: ["locale", "LC_TIME", "BOGUS"], environment: [:])
        #expect(report.code == 1)
        #expect(report.text.contains("unknown category"))
    }

    // MARK: id

    @Test func idReportProducesNumericFallbackWithoutFabricatedNames() {
        let report = FloeShellCoreUtilities.idReport(arguments: ["id", "-u"])
        #expect(report.code == 0)
        #expect(Int(report.text) != nil)
        let full = FloeShellCoreUtilities.idReport(arguments: ["id"])
        #expect(full.text.hasPrefix("uid="))
        #expect(full.text.contains("gid="))
    }

    // MARK: registration

    @Test func utilitiesRegisterOnTheAppSideRegistry() {
        let registry = FloeShellCommandRegistry()
        FloeShellCoreUtilities.register(in: registry)
        for name in ["id", "cut", "locale", "basename", "dirname", "true", "false"] {
            #expect(registry.handler(for: name) != nil, "\(name) must be registered")
        }
    }
}
#endif
