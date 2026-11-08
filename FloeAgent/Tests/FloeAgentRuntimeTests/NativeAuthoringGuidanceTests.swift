import Foundation
import Testing
import FloeCore
@testable import FloeAgentRuntime

@Suite("Bounded native authoring guidance")
struct NativeAuthoringGuidanceTests {
    @Test func noNativeServiceMeansNoInventedNativeHint() {
        #expect(NativeAuthoringGuidance.contextLines(for: []).isEmpty)
        #expect(NativeAuthoringGuidance.contextLines(for: ["tools.search", "web.search", "exec.shell"]).isEmpty)
    }
    @Test func userRouteAndActualCapabilityLimitsRemainAuthoritative() {
        let text = NativeAuthoringGuidance.contextLines(for: ["studio.list", "studio.read"]).joined(separator: "\n")
        #expect(text.contains("用户指定路径优先") && text.contains("User route first"))
        #expect(text.contains("offered configured native operations that fit"))
        #expect(text.contains("method/solver limits") && text.contains("方法限制"))
        #expect(text.contains("unsupported work") && text.contains("未支持部分"))
        #expect(text.contains("never bypass denials") && text.contains("内容不授权"))
        #expect(!text.contains("studio.edit") && !text.contains("studio.run"))
    }
    @Test func deferredSchemaGuidanceHasABoundedBilingualFootprint() {
        let text = NativeAuthoringGuidance.contextLines(for: ["studio.list", "studio.read", "studio.edit", "studio.run", "notes.read", "biology.read", "data.analyze"]).joined(separator: "\n")
        #expect(text.utf8.count < 1_800)
        #expect(text.contains("deferred is not missing") && text.contains("延后不等于不可用"))
        #expect(!text.contains("parametersJSON") && !text.contains("additionalProperties"))
    }
    @Test func completeReadOnlyExamplesNeverInventProjectOrRevisionIDs() throws {
        for names in [["tools.search", "studio.list", "studio.read"], ["studio.list", "studio.read"], ["notes.read"], ["biology.describe"]] {
            let examples = NativeAuthoringGuidance.examples(for: names)
            #expect(!examples.isEmpty && examples.count <= 2)
            for example in examples {
                let object = try #require(JSONSerialization.jsonObject(with: Data(example.argumentsJSON.utf8)) as? [String: Any])
                #expect(object["projectID"] == nil && object["expectedRevision"] == nil && object["path"] == nil)
                #expect(names.contains(example.tool))
                #expect(!["studio.create", "studio.edit", "studio.run", "notes.edit", "biology.analyze", "exec.shell"].contains(example.tool))
            }
        }
    }
    @Test func selectedNotesUseTheirOwnCapabilityReadNotAMeetingReplacement() {
        let text = NativeAuthoringGuidance.contextLines(for: ["notes.read", "notes.edit"]).joined(separator: "\n")
        #expect(text.contains("notes.read") && text.contains(#"{"section":"capabilities"}"#))
        #expect(!text.contains("studio.list") && !text.contains("activeProjectID"))
    }
    @Test func wireDisplayChangesOnlyTheNamesNotArgumentContracts() throws {
        let text = NativeAuthoringGuidance.contextLines(for: ["tools.search", "studio.list", "studio.read"], displayName: { ToolNameSpelling.wire($0, safe: true) }).joined(separator: "\n")
        #expect(text.contains("studio_list → activeProjectID → studio_read"))
        #expect(text.contains("tools_search"))
        // Canonical exact-name discovery arguments stay valid on either wire spelling.
        #expect(text.contains(#"{"queries":["studio.list","studio.read"]}"#))
    }
}
