import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxUtilities
@testable import FloeMacToolbox

@MainActor
@Suite("Mac text utilities", .serialized)
struct MacTextUtilityTests {
    @Test func jsonFormatCompactAndSortUseTheExistingCore() throws {
        let model = MacTextUtilityModel()
        model.input = "{\"b\":2,\"a\":[1,true,null],\"quoted\":\"[ { \\\" } ]\"}"
        model.perform(.formatJSON)
        #expect(!model.failed)
        #expect(model.output.contains("\n"))
        let pretty = model.output

        model.perform(.compactJSON)
        #expect(!model.output.contains("\n"))
        #expect(model.output.contains("\"a\""))

        model.perform(.sortJSON)
        let sorted = model.output
        #expect(sorted.range(of: "\"a\"")!.lowerBound < sorted.range(of: "\"b\"")!.lowerBound)
        #expect(try ToolboxJSON.format(pretty, style: .sorted) == sorted)
    }

    @Test func editingInputClearsObsoleteOutputAndFailure() {
        let model = MacTextUtilityModel()
        model.input = "Hello 世界"
        model.perform(.base64Encode)
        let encoded = model.output
        #expect(!encoded.isEmpty)
        #expect(model.lastAction == .base64Encode)
        model.input = encoded
        #expect(model.output.isEmpty && model.lastAction == nil && !model.failed)
        model.perform(.base64Decode)
        #expect(model.output == "Hello 世界")
        model.input = "{broken JSON"
        model.perform(.formatJSON)
        #expect(model.failed && model.output.isEmpty)
        #expect(model.input == "{broken JSON")
    }

    @Test func base64AndURLComponentRoundTripsAndRejectInvalidPayloads() throws {
        let value = "中文 / a+b?x=1&y=2 🧭"
        #expect(try ToolboxTextEncoding.base64Decode(ToolboxTextEncoding.base64Encode(value)) == value)
        let escaped = try ToolboxTextEncoding.urlEncode(value)
        #expect(!escaped.contains("/") && escaped.contains("%"))
        #expect(try ToolboxTextEncoding.urlDecode(escaped) == value)
        #expect(throws: ToolboxError.self) { try ToolboxTextEncoding.base64Decode("invalid!!") }
        #expect(throws: ToolboxError.self) { try ToolboxTextEncoding.base64Decode("/w==") }
        #expect(throws: ToolboxError.self) { try ToolboxTextEncoding.urlDecode("%FF%Z1") }
    }

    @Test func jsonBoundsAndSyntaxErrorsAreReported() {
        let model = MacTextUtilityModel()
        model.input = String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)
        model.perform(.formatJSON)
        #expect(model.failed && model.output.isEmpty)
        model.input = #"{"a":1}"#
        model.perform(.compactJSON)
        #expect(model.output == #"{"a":1}"#)
    }

    @Test func qrLinksOpenOnlyAbsoluteHTTPURLs() {
        #expect(MacQRLink.destination(for: "https://example.test/a?b=1#c")?.absoluteString
                == "https://example.test/a?b=1#c")
        #expect(MacQRLink.destination(for: "  http://example.test/path  ") != nil)
        #expect(MacQRLink.destination(for: "example.test/path") == nil)
        #expect(MacQRLink.destination(for: "file:///etc/passwd") == nil)
        #expect(MacQRLink.destination(for: "https://exa mple.test") == nil)
        #expect(MacQRLink.destination(for: "https://example.test/\u{0000}") == nil)
    }

    @Test func catalogExposesOnlyTheReviewedToolsAndTracksRemainingGaps() {
        let utilities = MacToolboxTool.firstMacBatch.map(\.rawValue)
        let media = MacToolboxTool.mediaBatch.map(\.rawValue)
        let visible = utilities + media
        let declared = MacToolboxTool.allCases.map(\.rawValue)
        let baseline = Set(ToolboxTool.allCases.map(\.rawValue))

        #expect(utilities == ["hash", "json", "encoding", "qr", "calculator"])
        #expect(media == ["magnifier", "scanner"])
        #expect(Set(visible).count == 7)
        #expect(Set(declared) == Set(visible + ["timer"]))
        #expect(declared.count == 8)
        #expect(!visible.contains("timer"))
        #expect(!visible.contains("sound"))
        #expect(baseline.count == 31)
        #expect(Set(visible).isSubset(of: baseline))
        #expect(baseline.subtracting(visible) == Set([
            "terminal", "vnc", "browser", "ping", "traceroute", "dns", "port",
            "lan", "wifi", "roaming", "serialAssistant", "http", "webSocket", "mqtt",
            "level", "motion", "compass", "ruler", "measure", "location",
            "photoMeasure", "barometer", "sound", "timer"
        ]))
    }

    @Test func directoryRetainsAllToolsAndOnlyEnablesImplementedEntries() {
        let all = ToolboxTool.allCases
        #expect(all.count == 31)
        #expect(Set(all.map(\.rawValue)).count == 31)
        #expect(MacToolboxAvailability.available == Set([.hash, .json, .encoding, .calculator, .qr,
            .ruler, .photoMeasure, .location, .timer, .magnifier, .browser, .sound, .scanner,
            .http, .webSocket, .mqtt, .serialAssistant, .terminal, .vnc,
            .ping, .traceroute, .dns, .port, .lan, .wifi, .roaming]))
        #expect(MacToolboxAvailability.available.isSubset(of: Set(all)))
        for group in ToolboxGroup.allCases {
            #expect(!all.filter { $0.group == group }.isEmpty)
        }
    }
}
