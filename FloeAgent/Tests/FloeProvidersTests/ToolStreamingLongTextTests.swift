// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders

@Suite("Native tool arguments with long text")
struct ToolStreamingLongTextTests {
    @Test func thousandsOfSmallChineseDeltasMakeOneExactNativeToolCall() throws {
        let text = String(repeating:"水墨青山与海风",count:10_000) + "\nEscaped quote: \" and emoji 🎨"
        let expected = try JSONSerialization.data(withJSONObject:["content":text],options:[.sortedKeys])
        let characters = Array(String(decoding:expected,as:UTF8.self))
        var aggregator = ToolCallAggregator()
        var emitted:[ToolCall] = []
        let header = ChatChunk(choices:[.init(index:0,delta:.init(toolCalls:[
            .init(index:0,id:"long-owned-call",type:"function",function:.init(name:"workspace.writeFile",arguments:""))]))])
        _ = WireTranslator.translate(header,aggregator:&aggregator)
        var count = 0
        for offset in stride(from:0,to:characters.count,by:12) {
            let fragment = String(characters[offset..<min(offset+12,characters.count)])
            let chunk = ChatChunk(choices:[.init(index:0,delta:.init(toolCalls:[
                .init(index:nil,id:"",function:.init(name:" ",arguments:fragment))]))])
            let events = WireTranslator.translate(chunk,aggregator:&aggregator)
            emitted += events.compactMap { if case .toolRequest(let call) = $0 { call } else { nil } }
            #expect(!events.contains { if case .error = $0 { true } else { false } })
            count += 1
        }
        #expect(count > 5_000 && emitted.isEmpty && aggregator.hasCalls)
        let finished = WireTranslator.translate(.init(choices:[.init(index:0,delta:.init(),finishReason:"tool_calls")]),aggregator:&aggregator)
        emitted += finished.compactMap { if case .toolRequest(let call) = $0 { call } else { nil } }
        let call = try #require(emitted.first)
        #expect(emitted.count == 1 && call.id == "long-owned-call" && call.toolName == "workspace.writeFile")
        #expect(call.argumentsJSON == expected)
        #expect(try JSONSerialization.jsonObject(with:call.argumentsJSON) as? [String:String] == ["content":text])
        #expect(!aggregator.hasCalls)
    }

    @Test func partialDiscardTruncationAndIdentitySemanticsArePreserved() throws {
        var cancelled = ToolCallAggregator()
        cancelled.consume(.init(index:0,id:"cancelled",function:.init(name:"contract.write",arguments:#"{"content":"partial"#)))
        cancelled.reset()
        #expect(!cancelled.hasCalls && cancelled.aggregatedCalls().isEmpty)
        var empty = ToolCallAggregator()
        empty.consume(.init(index:0))
        #expect(empty.hasCalls && empty.aggregatedCalls().isEmpty)
        empty.consume(.init(index:0,function:.init(name:"contract.write",arguments:"{}")))
        // This layer must not manufacture an identity; the existing runtime
        // validation still owns rejection of a never-supplied call ID.
        #expect(empty.aggregatedCalls().first?.id == "")
        var ambiguous = ToolCallAggregator()
        ambiguous.consume(.init(index:0,id:"a",function:.init(name:"contract.write",arguments:"{")))
        ambiguous.consume(.init(index:1,id:"b",function:.init(name:"contract.write",arguments:"[")))
        #expect(ambiguous.consume(.init(function:.init(arguments:"unattributable"))) == .ambiguousIndex)
        #expect(ambiguous.aggregatedCalls().map(\.argumentsJSON) == ["{","["])
        let provider = ProviderProfile(kind:.custom,wireProtocol:.openAIChatCompletions,baseURL:URL(string:"https://contract.invalid/v1")!)
        let model = ModelProfile(providerID:provider.id,remoteModelID:"synthetic",displayName:"Synthetic",limits:.init(contextTokens:8192,maxOutputTokens:1024),capabilities:[.text,.tools])
        let request = ProviderStreamRequest(provider:provider,model:model,messages:[],
            toolSchemas:[.init(name:"contract.write",description:"Owned fixture",parametersJSON:#"{"type":"object"}"#)],allToolNames:["contract.write"])
        var truncated = ChatCompletionStreamBoundary(request:request)
        let partial = ChatChunk(choices:[.init(index:0,delta:.init(toolCalls:[.init(index:0,id:"partial",function:.init(name:"contract.write",arguments:#"{"content":"unfinished"#))]))])
        let pending = truncated.consume(partial)
        let tail = truncated.finish()
        #expect(!pending.contains { if case .toolRequest = $0 { true } else { false } })
        #expect(!tail.contains { if case .toolRequest = $0 { true } else { false } })
        #expect(tail.contains { if case .error(let error) = $0 { error.kind == .malformedToolArguments } else { false } })
    }
}
