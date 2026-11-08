// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeAgentRuntime

@Suite("Native content pages remain complete")
struct InlineContentPagePolicyTests {
    @Test func nativePageIdentityDrivesWholeOrOmitWithTheCorrectRetryAdvice() throws {
        #expect(ToolResultPagePolicy.preservesWholePage(toolName: "chat.content.list"))
        #expect(ToolResultPagePolicy.preservesWholePage(toolName: "tools.readResult"))
        #expect(!ToolResultPagePolicy.preservesWholePage(toolName: "mcp.example.chat.content.list"))
        #expect(!ToolResultPagePolicy.preservesWholePage(toolName: "ordinary.read"))
        let bytes = try JSONSerialization.data(withJSONObject: ["contents": [String(repeating: "正文内容", count: 700)],
                                                               "nextCursor": "opaque-owned-position", "hasMore": true])
        let text = String(decoding: bytes, as: UTF8.self)
        let input = ToolResultSelectionInput(callID: "native-page", toolName: "chat.content.list", text: text, ref: nil,
            totalBytes: bytes.count, isPagingPage: ToolResultPagePolicy.preservesWholePage(toolName: "chat.content.list"))
        let complete = try #require(ToolResultPlanner.plan(inputs: [input], budgetBytes: bytes.count + 1_024).items.first)
        #expect(complete.complete && complete.output == text)
        #expect(try JSONSerialization.jsonObject(with: Data(complete.output.utf8)) is [String: Any])
        let omitted = try #require(ToolResultPlanner.plan(inputs: [input], budgetBytes: 1_024).items.first)
        #expect(omitted.pointerOnly && !omitted.excerpted && !omitted.complete)
        #expect(omitted.output.contains("same cursor") && omitted.output.contains("smaller limit/eventLimit"))
        #expect(!omitted.output.contains("tools.readResult page") && !omitted.output.contains("opaque-owned-position"))
    }
}
