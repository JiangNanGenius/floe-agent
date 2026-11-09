// FloeAgentRuntimeTests — focused regression for the phone.act sensitive
// text-input privacy rule. All payloads are synthetic canaries; no real
// credential ever appears in this file, a checkpoint, a log or an export.

import Foundation
import Testing
import FloeModels
@testable import FloeAgentRuntime

@Suite("Phone sensitive input sanitisation")
struct PhoneSensitiveInputSanitizerTests {

    @Test("sensitiveText is redacted while the dispatch identity is kept")
    func sensitiveTextIsScrubbedWithMetadata() throws {
        let arguments = Data(
            #"{"observationId":"obs-1","action":"setText","nodeRef":"n3","sensitiveText":"CANARY-9f2c-never-persist"}"#
                .utf8
        )
        let scrubbed = String(
            decoding: ToolArgumentSanitizer.redactedArgumentsJSON(arguments, toolName: "phone.act"),
            as: UTF8.self
        )
        #expect(!scrubbed.contains("CANARY-9f2c-never-persist"))
        #expect(scrubbed.contains("[redacted]"))
        #expect(scrubbed.contains("\"nodeRef\":\"n3\""))
        #expect(scrubbed.contains("\"action\":\"setText\""))
        #expect(scrubbed.contains("\"observationId\":\"obs-1\""))
        // The marker that makes an interrupted call non-replayable at resume.
        #expect(ToolArgumentSanitizer.containsSensitiveValues(arguments, toolName: "phone.act"))
    }

    @Test("A mistaken ordinary text aimed at any field is scrubbed the same way")
    func ordinaryPhoneTextIsAlsoScrubbed() throws {
        // The runtime persists the request BEFORE the Android host learns the
        // target node's protection, so phone.act `text` is credential-by-policy.
        let arguments = Data(
            #"{"action":"setText","nodeRef":"n4","text":"CANARY-PLAINTEXT"}"#.utf8
        )
        #expect(ToolArgumentSanitizer.containsSensitiveValues(arguments, toolName: "phone.act"))
        let scrubbed = String(
            decoding: ToolArgumentSanitizer.redactedArgumentsJSON(arguments, toolName: "phone.act"),
            as: UTF8.self
        )
        #expect(!scrubbed.contains("CANARY-PLAINTEXT"))
        #expect(scrubbed.contains("\"nodeRef\":\"n4\""))
    }

    @Test("Live dispatch bytes are never mutated by the persistence copy")
    func sanitizedCallKeepsTheOriginalPayload() throws {
        let arguments = Data(
            #"{"action":"setText","nodeRef":"n1","sensitiveText":"CANARY-LIVE"}"#.utf8
        )
        let call = try ToolCall(
            id: "call_phone_sensitive",
            toolName: "phone.act",
            argumentsJSON: arguments,
            scope: .local
        )
        let copy = ToolArgumentSanitizer.sanitizedForPersistence(call)
        #expect(String(decoding: call.argumentsJSON, as: UTF8.self).contains("CANARY-LIVE"))
        #expect(!String(decoding: copy.argumentsJSON, as: UTF8.self).contains("CANARY-LIVE"))
        #expect(copy.id == call.id)
        #expect(copy.toolName == call.toolName)
    }

    @Test("Non-input phone actions stay persistable and replay-safe metadata only")
    func clickAndNavigationAreUntouched() throws {
        let click = Data(#"{"action":"click","nodeRef":"n2","observationId":"obs-2"}"#.utf8)
        #expect(!ToolArgumentSanitizer.containsSensitiveValues(click, toolName: "phone.act"))
        #expect(
            String(
                decoding: ToolArgumentSanitizer.redactedArgumentsJSON(click, toolName: "phone.act"),
                as: UTF8.self
            ).contains("\"nodeRef\":\"n2\"")
        )
    }

    @Test("The narrow rule never spills into document or file tools")
    func otherToolsKeepOrdinaryTextBehaviour() throws {
        // Same argument shape, different tool: this is document content, not
        // a phone credential, and must persist unchanged.
        let lookalike = Data(#"{"action":"setText","nodeRef":"n1","text":"a-document-fragment"}"#.utf8)
        #expect(!ToolArgumentSanitizer.containsSensitiveValues(lookalike, toolName: "document.createMarkdown"))
        #expect(!ToolArgumentSanitizer.containsSensitiveValues(lookalike, toolName: "workspace.writeFile"))
        let persisted = String(
            decoding: ToolArgumentSanitizer.redactedArgumentsJSON(lookalike, toolName: "workspace.writeFile"),
            as: UTF8.self
        )
        #expect(persisted.contains("a-document-fragment"))
    }

    @Test("Malformed or partial phone arguments are omitted, never leaked")
    func malformedPhoneInputFailsClosed() throws {
        // Truncated mid-value: field order or a partial JSON must not leak.
        let partial = Data(
            #"{"action":"setText","nodeRef":"n3","sensitiveText":"CANARY-PARTIAL"#.utf8
        )
        #expect(ToolArgumentSanitizer.containsSensitiveValues(partial, toolName: "phone.act"))
        let scrubbed = String(
            decoding: ToolArgumentSanitizer.redactedArgumentsJSON(partial, toolName: "phone.act"),
            as: UTF8.self
        )
        #expect(!scrubbed.contains("CANARY-PARTIAL"))
        #expect(scrubbed.contains("_redacted"))

        let partialText = Data(
            #"{"action":"setText","nodeRef":"n3","text":"CANARY-PARTIAL2"#.utf8
        )
        #expect(ToolArgumentSanitizer.containsSensitiveValues(partialText, toolName: "phone.act"))
        #expect(
            !String(
                decoding: ToolArgumentSanitizer.redactedArgumentsJSON(
                    partialText,
                    toolName: "phone.act"
                ),
                as: UTF8.self
            ).contains("CANARY-PARTIAL2")
        )
    }

    @Test("Conservative root-key rule: missing or wrong action still scrubs text")
    func actionAgnosticRootKeysAreScrubbed() throws {
        // A valid object whose action is missing/invalid is still persisted
        // before the dispatcher/host can reject it: the text must not leak.
        let missingAction = Data(#"{"nodeRef":"n3","sensitiveText":"CANARY-NOACTION"}"#.utf8)
        #expect(ToolArgumentSanitizer.containsSensitiveValues(missingAction, toolName: "phone.act"))
        let scrubbedMissing = String(
            decoding: ToolArgumentSanitizer.redactedArgumentsJSON(missingAction, toolName: "phone.act"),
            as: UTF8.self
        )
        #expect(!scrubbedMissing.contains("CANARY-NOACTION"))
        #expect(scrubbedMissing.contains("\"nodeRef\":\"n3\""))

        let wrongAction = Data(#"{"action":"click","nodeRef":"n3","text":"CANARY-WRONG-ACTION"}"#.utf8)
        #expect(ToolArgumentSanitizer.containsSensitiveValues(wrongAction, toolName: "phone.act"))
        #expect(
            !String(
                decoding: ToolArgumentSanitizer.redactedArgumentsJSON(wrongAction, toolName: "phone.act"),
                as: UTF8.self
            ).contains("CANARY-WRONG-ACTION")
        )

        let bothKeys = Data(
            #"{"action":"setText","nodeRef":"n3","text":"CANARY-BOTH-PLAIN","sensitiveText":"CANARY-BOTH-SECRET"}"#
                .utf8
        )
        #expect(ToolArgumentSanitizer.containsSensitiveValues(bothKeys, toolName: "phone.act"))
        let scrubbedBoth = String(
            decoding: ToolArgumentSanitizer.redactedArgumentsJSON(bothKeys, toolName: "phone.act"),
            as: UTF8.self
        )
        #expect(!scrubbedBoth.contains("CANARY-BOTH-PLAIN"))
        #expect(!scrubbedBoth.contains("CANARY-BOTH-SECRET"))

        // Case-insensitive root keys.
        let cased = Data(#"{"action":"setText","nodeRef":"n3","SensitiveText":"CANARY-CASE"}"#.utf8)
        #expect(ToolArgumentSanitizer.containsSensitiveValues(cased, toolName: "phone.act"))
        #expect(
            !String(
                decoding: ToolArgumentSanitizer.redactedArgumentsJSON(cased, toolName: "phone.act"),
                as: UTF8.self
            ).contains("CANARY-CASE")
        )
    }

    @Test("Non-object and any malformed phone.act payload is omitted whole")
    func nonObjectAndMalformedPhoneArgumentsFailClosed() throws {
        let array = Data(#"[{"text":"CANARY-ARRAY"}]"#.utf8)
        #expect(ToolArgumentSanitizer.containsSensitiveValues(array, toolName: "phone.act"))
        let scrubbedArray = String(
            decoding: ToolArgumentSanitizer.redactedArgumentsJSON(array, toolName: "phone.act"),
            as: UTF8.self
        )
        #expect(scrubbedArray.contains("_redacted"))
        #expect(!scrubbedArray.contains("CANARY-ARRAY"))

        // Malformed payload whose credential key is ESCAPED inside the bytes
        // and truncated mid-value: a substring-key detector would miss it,
        // so the whole-payload omission rule must catch it instead.
        let evasive = Data(#"{"note":"x","textish":"\"sensitiveText\": \"CANARY-TRICK"#.utf8)
        #expect(ToolArgumentSanitizer.containsSensitiveValues(evasive, toolName: "phone.act"))
        let scrubbedEvasive = String(
            decoding: ToolArgumentSanitizer.redactedArgumentsJSON(evasive, toolName: "phone.act"),
            as: UTF8.self
        )
        #expect(scrubbedEvasive.contains("_redacted"))
        #expect(!scrubbedEvasive.contains("CANARY-TRICK"))

        // A JSON fragment string is unparseable at the top level: omitted.
        let fragment = Data("\"CANARY-FRAGMENT\"".utf8)
        #expect(ToolArgumentSanitizer.containsSensitiveValues(fragment, toolName: "phone.act"))
        #expect(
            !String(
                decoding: ToolArgumentSanitizer.redactedArgumentsJSON(fragment, toolName: "phone.act"),
                as: UTF8.self
            ).contains("CANARY-FRAGMENT")
        )
    }

    @Test("The legacy phone_act alias is covered like the canonical name")
    func legacyAliasIsNormalised() throws {
        let arguments = Data(#"{"action":"setText","nodeRef":"n3","sensitiveText":"CANARY-ALIAS"}"#.utf8)
        #expect(ToolArgumentSanitizer.containsSensitiveValues(arguments, toolName: "phone_act"))
        #expect(
            !String(
                decoding: ToolArgumentSanitizer.redactedArgumentsJSON(arguments, toolName: "phone_act"),
                as: UTF8.self
            ).contains("CANARY-ALIAS")
        )
    }

    @Test("Browser credential behaviour is preserved beside the phone rule")
    func browserCookieScrubbingStillWorks() throws {
        let json = #"{"headers":{"Authorization":"Bearer CANARY-OLD"},"url":"https://example.test"}"#
        let scrubbed = ToolArgumentSanitizer.redactedArgumentText(json)
        #expect(!scrubbed.contains("CANARY-OLD"))
        #expect(scrubbed.contains("example.test"))
        #expect(ToolArgumentSanitizer.containsSensitiveValues(Data(json.utf8)))
    }
}
