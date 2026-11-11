// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Final Chat wire checks, after canonical history/name projection. These do
/// not replace the runtime's lifecycle/authorization checks or repair history.
enum ChatRequestContract {
    struct Violation: Error, Sendable, Equatable {
        enum Code: String, Sendable {
            case parametersNotObject, duplicateToolDefinition, emptyToolName
            case emptyCallID, duplicateCallID, argumentsNotObject
            case unexpectedToolFields, orphanToolResult, missingToolResult
        }
        var code: Code
        /// Only fixed wire keys and numeric indices; never argument values,
        /// tool IDs/names, content, URLs, or the JSON parser's error text.
        var path: String
    }

    static func validate(_ body: ChatRequest) throws {
        var toolNames = Set<String>()
        for (index, tool) in (body.tools ?? []).enumerated() {
            let path = "tools[\(index)].function"
            guard !tool.function.name.isEmpty else {
                throw Violation(code: .emptyToolName, path: path + ".name")
            }
            guard toolNames.insert(tool.function.name).inserted else {
                throw Violation(code: .duplicateToolDefinition, path: path + ".name")
            }
            guard isObject(tool.function.parameters) else {
                throw Violation(code: .parametersNotObject, path: path + ".parameters")
            }
        }

        var allCallIDs = Set<String>()
        var pending: [String: String] = [:]
        for (index, message) in body.messages.enumerated() {
            let path = "messages[\(index)]"
            let calls = message.toolCalls ?? []
            if message.role == "tool" {
                guard calls.isEmpty, let id = message.toolCallID, !id.isEmpty,
                      pending.removeValue(forKey: id) != nil else {
                    throw Violation(code: .orphanToolResult, path: path + ".tool_call_id")
                }
                continue
            }
            if let missing = pending.values.sorted().first {
                throw Violation(code: .missingToolResult, path: missing)
            }
            guard message.toolCallID == nil, calls.isEmpty || message.role == "assistant" else {
                throw Violation(code: .unexpectedToolFields, path: path)
            }
            for (callIndex, call) in calls.enumerated() {
                let callPath = path + ".tool_calls[\(callIndex)]"
                guard !call.id.isEmpty else {
                    throw Violation(code: .emptyCallID, path: callPath + ".id")
                }
                guard allCallIDs.insert(call.id).inserted else {
                    throw Violation(code: .duplicateCallID, path: callPath + ".id")
                }
                guard !call.function.name.isEmpty else {
                    throw Violation(code: .emptyToolName, path: callPath + ".function.name")
                }
                guard isObject(call.function.arguments) else {
                    throw Violation(code: .argumentsNotObject, path: callPath + ".function.arguments")
                }
                pending[call.id] = callPath + ".id"
            }
        }
        if let missing = pending.values.sorted().first {
            throw Violation(code: .missingToolResult, path: missing)
        }
    }

    private static func isObject(_ json: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) is [String: Any]
    }

    /// Bounded structural evidence about the actual emitted body. Empty
    /// assistant text/reasoning-only turns are observations, not guessed
    /// provider restrictions. No transcript or image/argument bytes enter it.
    static func diagnosticSummary(_ body: ChatRequest) -> String {
        var images = 0, calls = 0, results = 0, emptyAssistant = 0, reasoningOnly = 0
        var shapes: [String] = []
        for (index, message) in body.messages.enumerated() {
            let role: String
            switch message.role {
            case "system": role = "s"
            case "user": role = "u"
            case "assistant": role = "a"
            case "tool": role = "t"
            case "developer": role = "d"
            default: role = "other"
            }
            var textBytes = 0, imageCount = 0
            switch message.content {
            case .text(let text): textBytes = text.utf8.count
            case .parts(let parts):
                for part in parts {
                    switch part {
                    case .text(let text): textBytes += text.utf8.count
                    case .imageURL: imageCount += 1
                    }
                }
            case nil: break
            }
            let callCount = message.toolCalls?.count ?? 0
            let reasoningPresent = nonEmptyReasoning(message.reasoningContent) != nil
            if role == "a", callCount == 0, textBytes == 0, imageCount == 0 {
                if reasoningPresent { reasoningOnly += 1 } else { emptyAssistant += 1 }
            }
            images += imageCount
            calls += callCount
            if role == "t" { results += 1 }
            if index < 64 {
                shapes.append("\(index):\(role):textBytes\(textBytes):images\(imageCount):calls\(callCount):reasoning\(reasoningPresent ? 1 : 0)")
            }
        }
        let schemaDigest = (try? ProviderWireEncoder.encode(body.tools ?? [])).map { FloeDigest.sha256Hex($0) } ?? "unencodable"
        return "shape=v1 wireMessages=\(body.messages.count) wireCalls=\(calls) wireResults=\(results) imageParts=\(images) emptyAssistantTurns=\(emptyAssistant) reasoningOnlyTurns=\(reasoningOnly) toolDefinitions=\(body.tools?.count ?? 0) toolDefinitionsSHA256=\(schemaDigest) messageShapes=[\(shapes.joined(separator: ","))] shapesOmitted=\(max(0, body.messages.count - shapes.count)) maxTokens=\(body.maxTokens.map(String.init) ?? "omitted") thinkingPresent=\(body.thinking != nil) reasoningEffortPresent=\(body.reasoningEffort != nil) enableThinkingPresent=\(body.enableThinking != nil)"
    }

    /// Keep the original provider error on its event/details path; persistent
    /// diagnostics accept only known codes and wire-key paths from its body.
    static func rejectionFields(_ message: String) -> String {
        let root = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any]
        let error = (root?["error"] as? [String: Any]) ?? root ?? [:]
        let codes: Set<String> = ["InvalidParameter", "BadRequest", "invalid_request_error", "invalid_parameter", "context_length_exceeded", "rate_limit_exceeded"]
        let rawCode = (error["code"] as? String) ?? (error["type"] as? String) ?? ""
        let code = codes.contains(rawCode) ? rawCode : "other"
        let rawParam = (error["param"] as? String) ?? ""
        let wirePath = #"^(messages|tools|tool_choice|max_tokens|thinking|reasoning_effort|enable_thinking|stream_options|model)(\[[0-9]+\]|\.[A-Za-z_][A-Za-z0-9_]*)*$"#
        let param = rawParam.isEmpty ? "unspecified"
            : (rawParam.utf8.count <= 160 && rawParam.range(of: wirePath, options: .regularExpression) != nil ? rawParam : "redacted")
        return "providerCode=\(code) providerParam=\(param)"
    }
}
