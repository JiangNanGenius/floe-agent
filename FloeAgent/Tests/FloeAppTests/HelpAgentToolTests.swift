// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeTools
#if !HELP_TOOL_QUALIFICATION
@testable import FloeApp
#endif

@MainActor
@Suite("FloeApp.HelpAgentTools", .serialized)
struct HelpAgentToolTests {
    private func context(name: String, runID: UUID = UUID(), conversationID: UUID? = UUID(),
                         callID: String = "help-test-call", temporary: Bool = false,
                         cancellation: CancellationToken = CancellationToken()) -> ToolContext {
        ToolContext(runID: runID, toolCallID: callID, cancellation: cancellation,
            conversationID: conversationID,
            callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: runID, callID: callID, toolName: name),
            temporaryReadOnly: temporary)
    }

    private func output(_ result: ToolExecutionOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data((result.capturedOutput ?? result.summary).utf8)) as? [String: Any])
    }

    private func citation(_ object: [String: Any]) throws -> String {
        let citation = try #require(object["citation"] as? [String: Any])
        return try #require(citation["reference"] as? String)
    }

    private func library(_ center: HelpContentCenter) -> HelpToolLibraryAccess {
        HelpToolLibraryAccess(prepare: { await center.prepare() },
            snapshot: { try center.snapshot(language: $0) },
            snapshotForReference: { try center.snapshot(for: $0) })
    }

    @Test("Registered tools expose real read and main-only presentation metadata")
    func compiledMetadata() throws {
        let fixture = try HelpToolFixture()
        let registry = ToolRunnerRegistry()
        registerHelpAgentTools(center: fixture.center, presentation: HelpPresentationCoordinator(), registry: registry)
        #expect(registry.allDescriptors.map(\.name) == ["help.present", "help.read", "help.search"])
        for name in ["help.search", "help.read"] {
            let descriptor = try #require(registry.descriptor(named: name))
            #expect(ToolCatalog.descriptor(named: name)?.authorizationIdentity == descriptor.authorizationIdentity)
            #expect(descriptor.effect == .readOnly)
            #expect(!descriptor.isSideEffecting)
            #expect(!descriptor.requiresHostScope)
            #expect(descriptor.executionBoundary == .any)
            #expect(CapabilityExecutionRouter.decision(for: name).backend == .nativeApple)
            #expect(descriptor.effect.isAllowedInPlanMode)
            #expect(TemporaryChatToolPolicy.readOnlyDescriptor(descriptor) == nil)
        }
        let present = try #require(registry.descriptor(named: "help.present"))
        #expect(present.effect == .internalState)
        #expect(present.riskLabels == [.controlsGUI])
        #expect(!present.isSideEffecting)
        #expect(present.executionBoundary == .mainRunOnly)
        #expect(CapabilityExecutionRouter.decision(for: present.name).backend == .nativeApple)
        #expect(!present.effect.isAllowedInPlanMode)
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(present) == nil)
    }

    @Test("First tool search waits for installed content and returns real localized settings paths")
    func searchPreparesAndUsesInstalledVersion() async throws {
        let fixture = try HelpToolFixture(installedVersion: "2.0.0")
        let registry = ToolRunnerRegistry()
        let coordinator = HelpPresentationCoordinator()
        registerHelpAgentTools(center: fixture.center, presentation: coordinator, registry: registry)
        let runner = try #require(registry.runner(named: "help.search"))
        let data = Data(#"{"query":"回车键","language":"zh-Hans","limit":3}"#.utf8)
        let result = try await runner.run(data, context(name: "help.search"))
        let object = try output(result)
        let snapshot = try #require(object["snapshot"] as? [String: Any])
        #expect(snapshot["version"] as? String == "2.0.0")
        #expect(fixture.initialLoadCount == 1)
        #expect(fixture.center.isPrepared)
        let results = try #require(object["results"] as? [[String: Any]])
        let keyboard = try #require(results.first { entry in
            ((entry["citation"] as? [String: Any])?["identity"] as? [String: Any])?["articleID"] as? String == "input.keyboard"
        })
        let reference = try HelpReferenceLink.reference(from: citation(keyboard))
        #expect(reference.version == "2.0.0")
        #expect(reference.language == .simplifiedChinese)
        let settings = try #require(keyboard["settings"] as? [[String: Any]])
        let target = try #require(settings.first?["target"] as? [String: Any])
        #expect(target["path"] as? [String] == ["设置", "通用", "实体键盘", "回车键"])
        #expect(settings.first?["valuesRead"] as? Bool == false)
        #expect(settings.first?["navigation"] as? String == "userTapOnly")
        #expect(settings.count == 1)
        #expect(coordinator.presentation == nil)
    }

    @Test("Read paging and old citations keep the same immutable source after an update")
    func readExactVersionAndContinuation() async throws {
        let fixture = try HelpToolFixture()
        await fixture.center.prepare()
        let oldSnapshot = try fixture.center.snapshot(language: .english)
        let reference = try oldSnapshot.reference(articleID: "input.keyboard", sectionID: "steps")
        let link = try HelpReferenceLink.url(for: reference).absoluteString
        fixture.installed = HelpContentPackage(version: "2.0.0", files: try HelpToolFixture.files(version: "2.0.0"))
        fixture.center.reload()
        #expect(fixture.center.selectedVersion == "2.0.0")
        let tool = HelpReadTool(library: library(fixture.center))
        var joined = ""
        var offset = 0
        repeat {
            let result = try await tool.execute(.init(reference: link, offset: offset, maximumCharacters: 23), context: context(name: "help.read"))
            let object = try output(result)
            joined += try #require(object["text"] as? String)
            let identity = try #require(object["snapshot"] as? [String: Any])
            #expect(identity["version"] as? String == oldSnapshot.manifest.version)
            #expect(identity["sourceRevision"] as? String == String(repeating: "a", count: 40))
            guard let next = object["nextOffset"] as? Int else {
                #expect(object["isTruncated"] as? Bool == false)
                break
            }
            #expect(next > offset)
            offset = next
            #expect(offset < 2_000)
            if offset >= 2_000 { break }
        } while true
        #expect(joined == (try oldSnapshot.read(reference).text))
        #expect(joined.contains(oldSnapshot.manifest.version))
        #expect(!joined.contains("2.0.0"))
        let unavailable = try HelpReferenceLink.url(for: HelpReference(version: "9.0.0", language: .english, articleID: "input.keyboard")).absoluteString
        await #expect(throws: (any Error).self) {
            try await tool.execute(.init(reference: unavailable), context: context(name: "help.read"))
        }
    }

    @Test("Strict decoders refuse model-provided paths, setting values and owner identities")
    func rejectsUnknownArguments() throws {
        let fixture = try HelpToolFixture()
        let access = library(fixture.center)
        let presenter = HelpToolPresentationAccess(present: { reference, _, _, _ in
            .init(status: "unavailable", reference: reference, explanation: "No host.")
        }, cancel: { _, _, _ in })
        let tools = [AnyAgentTool(HelpSearchTool(library: access)), AnyAgentTool(HelpReadTool(library: access)),
                     AnyAgentTool(HelpPresentTool(library: access, presentation: presenter))]
        let payloads = [
            #"{"query":"keyboard","language":"en","path":"/private/settings"}"#,
            #"{"reference":"file:///private/settings","value":true}"#,
            #"{"reference":"floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en","runID":"model-owner"}"#
        ]
        for (tool, payload) in zip(tools, payloads) {
            #expect(throws: (any Error).self) { try tool.validateArguments(Data(payload.utf8)) }
        }
        #expect(throws: (any Error).self) {
            try tools[1].validateArguments(Data(#"{"reference":"https://example.test/help"}"#.utf8))
        }
    }

    @Test("Temporary chat and pre-cancelled calls do not cross the callable boundary")
    func ceilingAndCancellation() async throws {
        let fixture = try HelpToolFixture()
        let search = HelpSearchTool(library: library(fixture.center))
        await #expect(throws: (any Error).self) {
            try await search.execute(.init(query: "keyboard", language: .english), context: context(name: "help.search", temporary: true))
        }
        let token = CancellationToken()
        token.cancel()
        await #expect(throws: (any Error).self) {
            try await search.execute(.init(query: "keyboard", language: .english), context: context(name: "help.search", cancellation: token))
        }
        #expect(!fixture.center.isPrepared)
    }

    @Test("Presentation requires the exact main tool origin and derives all ownership from context")
    func presentationOwnerAndReceipts() async throws {
        let fixture = try HelpToolFixture()
        let coordinator = HelpPresentationCoordinator(appearanceTimeout: .milliseconds(100))
        let registry = ToolRunnerRegistry()
        registerHelpAgentTools(center: fixture.center, presentation: coordinator, registry: registry)
        let runner = try #require(registry.runner(named: "help.present"))
        let link = try HelpReferenceLink.url(for: HelpReference(version: HelpBundleMetadata.bundledVersion, language: .english, articleID: "input.keyboard")).absoluteString
        let payload = try JSONSerialization.data(withJSONObject: ["reference": link])
        let main = context(name: "help.present")
        var forged = main
        forged.callOrigin = nil
        await #expect(throws: (any Error).self) { try await runner.run(payload, forged) }
        forged.callOrigin = ToolCallOrigin(kind: .delegatedChild, runID: main.runID, callID: main.toolCallID!, toolName: "help.present")
        await #expect(throws: (any Error).self) { try await runner.run(payload, forged) }
        forged.callOrigin = ToolCallOrigin(kind: .mainRunDelegate, runID: main.runID, callID: main.toolCallID!, toolName: "wrapper.tool")
        await #expect(throws: (any Error).self) { try await runner.run(payload, forged) }
        #expect(!fixture.center.isPrepared)

        let deferred = try output(await runner.run(payload, main))
        #expect(deferred["status"] as? String == "deferred")
        #expect(coordinator.presentation == nil)

        let hostID = coordinator.registerHost(sceneID: "scene-help-test", currentConversationID: main.conversationID,
            currentRunID: main.runID, isActive: true)
        let visibleContext = context(name: "help.present", runID: main.runID,
            conversationID: main.conversationID, callID: "help-visible-call")
        let call = Task { try await runner.run(payload, visibleContext) }
        let request = try await waitForPresentation(coordinator)
        #expect(request.owner.runID == main.runID)
        #expect(request.owner.conversationID == main.conversationID)
        #expect(request.owner.requestID == visibleContext.toolCallID)
        #expect(request.sceneID == "scene-help-test")
        #expect(!request.isVisible)
        coordinator.confirmVisible(presentationID: request.id, hostID: hostID)
        let presented = try output(await call.value)
        #expect(presented["status"] as? String == "presented")
        coordinator.dismiss(presentationID: request.id, hostID: hostID)
    }

    @Test("Cancelling the runtime token retires an opening help request")
    func runtimeCancellationStopsPendingPresentation() async throws {
        let fixture = try HelpToolFixture()
        let coordinator = HelpPresentationCoordinator(appearanceTimeout: .seconds(2))
        let registry = ToolRunnerRegistry()
        registerHelpAgentTools(center: fixture.center, presentation: coordinator, registry: registry)
        let runner = try #require(registry.runner(named: "help.present"))
        let token = CancellationToken()
        let main = context(name: "help.present", cancellation: token)
        let hostID = coordinator.registerHost(sceneID: "current-scene", currentConversationID: main.conversationID,
            currentRunID: main.runID, isActive: true)
        let reference = HelpReference(version: HelpBundleMetadata.bundledVersion, language: .english, articleID: "input.keyboard")
        let payload = try JSONSerialization.data(withJSONObject: ["reference": HelpReferenceLink.url(for: reference).absoluteString])
        let call = Task { try await runner.run(payload, main) }
        let request = try await waitForPresentation(coordinator)
        token.cancel()
        await #expect(throws: (any Error).self) { try await call.value }
        #expect(coordinator.presentation == nil)
        coordinator.confirmVisible(presentationID: request.id, hostID: hostID)
        #expect(coordinator.presentation == nil)
        let late = await coordinator.present(reference: reference, owner: request.owner)
        #expect(late.status == "cancelled")
    }

    private func waitForPresentation(_ coordinator: HelpPresentationCoordinator) async throws -> HelpPresentation {
        for _ in 0..<500 {
            if let request = coordinator.presentation { return request }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw HelpContentError.unavailable
    }
}

/// A complete in-memory declarative package, verified by the production library.
@MainActor
private final class HelpToolFixture {
    var installed: HelpContentPackage?
    var initialLoadCount = 0
    let bundled: [String: Data]
    let initialInstalled: HelpContentPackage?
    lazy var center = HelpContentCenter(bundledFiles: { [bundled] in bundled },
        installedPackage: { [unowned self] in installed },
        awaitInitialLoad: { [unowned self] in
            initialLoadCount += 1
            installed = initialInstalled
        }, compareVersions: { left, right in left.compare(right, options: .numeric) },
        digest: { FloeDigest.sha256Hex($0) })

    init(installedVersion: String? = nil) throws {
        bundled = try Self.files(version: HelpBundleMetadata.bundledVersion)
        initialInstalled = try installedVersion.map { HelpContentPackage(version: $0, files: try Self.files(version: $0)) }
    }

    nonisolated static func files(version: String) throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var files: [String: Data] = [:]
        for language in HelpLanguage.allCases {
            let zh = language == .simplifiedChinese
            let title = zh ? "回车键" : "Return Key"
            let text = zh
                ? "指南版本 \(version)。打开设置、通用、实体键盘、回车键，选择发送。按住 Shift 并按回车仍可换行。"
                : "Guide version \(version). Open Settings, General, Hardware Keyboard, Return Key, then choose Send. Shift and Return still inserts a newline."
            let article = HelpArticle(id: "input.keyboard", title: title,
                summary: zh ? "设置实体键盘回车键" : "Configure the hardware keyboard return key",
                htmlPath: "help/\(language.rawValue)/input.keyboard.html",
                sections: [.init(id: "steps", title: title, level: 2, text: text)],
                keywords: ["keyboard", "回车键"], settingIDs: ["general.hardwareReturn"])
            let index = HelpIndex(locale: language,
                categories: [.init(id: "start", title: zh ? "开始使用" : "Get started",
                    entries: [.init(articleID: article.id, sectionID: "steps", title: title)])], articles: [article])
            files["help/index.\(language.rawValue).json"] = try encoder.encode(index)
            files[article.htmlPath] = Data("<!doctype html><html lang=\"\(language.rawValue)\"><head><meta charset=\"utf-8\"><title>\(title)</title></head><body><h1>\(title)</h1><h2 id=\"steps\">\(title)</h2><p>\(text)</p></body></html>".utf8)
        }
        files["index.md"] = Data("# Help\nPublic product help.".utf8)
        files["index.zh-Hans.md"] = Data("# 帮助\n公开产品指南。".utf8)
        let manifest = HelpPackageManifest(version: version, sourceRevision: String(repeating: "a", count: 40),
            title: ["en": "Floe guides", "zh-Hans": "Floe 指南"],
            indexPaths: ["en": "help/index.en.json", "zh-Hans": "help/index.zh-Hans.json"],
            resources: files.keys.sorted().map { path in
                let data = files[path]!
                let mime = path.hasSuffix(".json") ? "application/json" : path.hasSuffix(".html") ? "text/html" : "text/markdown"
                return HelpResourceDescriptor(path: path, mimeType: mime, byteCount: data.count, sha256: FloeDigest.sha256Hex(data))
            })
        files[HelpBundleMetadata.manifestPath] = try encoder.encode(manifest)
        files["content.json"] = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "id": HelpBundleMetadata.packageID, "version": version, "kind": "help",
            "minimumAppVersion": "1.7.0", "sourceRevision": String(repeating: "a", count: 40),
            "containsScripts": false, "requiredCapabilities": [], "dependencies": [],
            "documents": ["en": "index.md", "zh-Hans": "index.zh-Hans.md"],
            "helpManifest": HelpBundleMetadata.manifestPath
        ], options: [.sortedKeys])
        return files
    }
}
