// FloeAgentRuntimeTests — Native-first media routing policy.
//
// Acceptance scope: high-cost image/video/audio/PDF work must not be silently
// routed into the TinyEMU Linux interpreter, while an explicit script request
// or a genuinely unsupported operation still reaches it. The gate is
// operation-aware: merely offering some native media tool (for example OCR)
// never proves the requested operation (for example video encoding) is
// covered. These tests pin the shared policy, the discovery arbitration, the
// availability-aware guidance and the prompt layer. Device/model behaviour
// stays a separate acceptance gate and is not claimed here.

import Foundation
import Testing
import FloeTools
@testable import FloeAgentRuntime

@Suite("Native-first media routing")
struct NativeMediaRoutingTests {
    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "test \(name)",
            parametersJSON: #"{"type":"object","properties":{}}"#,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    // MARK: - Shared policy (FloeTools)

    @Test func mediaIntentIsRecognizedInBothLanguages() {
        #expect(ToolRoutingPolicy.intent(forTask: "把这段视频转成 GIF") == .nativeMedia)
        #expect(ToolRoutingPolicy.intent(forTask: "extract frames from this clip") == .nativeMedia)
        #expect(ToolRoutingPolicy.intent(forTask: "识别这张图片里的文字") == .nativeMedia)
        #expect(ToolRoutingPolicy.concernsNativeMedia("压缩 PDF 后发给我"))
    }

    @Test func explicitScriptRequestOutranksMediaIntent() {
        #expect(ToolRoutingPolicy.intent(forTask: "写一个 Python 脚本批量处理这些图片") == .scripted)
        #expect(ToolRoutingPolicy.intent(forTask: "convert the video with ffmpeg on the command line") == .scripted)
    }

    @Test func asciiMediaTermsDoNotMatchInsideLongerWords() {
        // "mov" must not fire on "remove"; no other media term is present.
        #expect(ToolRoutingPolicy.intent(forTask: "remove the temporary build files") == .general)
        #expect(ToolRoutingPolicy.intent(forTask: "更新 README 并提交") == .general)
    }

    @Test func matchedNativeToolsRequireTheRequestedOperation() {
        // The operation is named and offered: coverage is real.
        let covered = ToolRoutingPolicy.decision(
            forTask: "把这个视频转码成 mp4",
            offeredToolNames: ["video.transcode", "exec.shell"]
        )
        #expect(covered.matchedNativeTools == ["video.transcode"])
        #expect(covered.prefersNativeTools)

        // An unrelated native media tool (OCR) says nothing about the
        // requested video operation.
        let unrelated = ToolRoutingPolicy.decision(
            forTask: "把这个视频转码成 mp4",
            offeredToolNames: ["image.ocr", "exec.shell", "exec.localPython"]
        )
        #expect(unrelated.intent == .nativeMedia)
        #expect(unrelated.nativeMediaTools == ["image.ocr"])
        #expect(unrelated.matchedNativeTools.isEmpty)
        #expect(!unrelated.prefersNativeTools)

        // A video-prefixed tool whose operation is not the requested one
        // (super resolution offered, transcode requested) is not coverage.
        let wrongOperation = ToolRoutingPolicy.decision(
            forTask: "把这个视频转码成 mp4",
            offeredToolNames: ["video.superResolution", "exec.shell"]
        )
        #expect(wrongOperation.matchedNativeTools.isEmpty)
        #expect(!wrongOperation.prefersNativeTools)

        // Generation names a configured model route, not on-device GPU work;
        // the decision still prefers the native route over the guest.
        let generation = ToolRoutingPolicy.decision(
            forTask: "生成一段视频",
            offeredToolNames: ["video.generate", "exec.shell"]
        )
        #expect(generation.matchedNativeTools == ["video.generate"])
        #expect(generation.prefersNativeTools)
    }

    @Test func explicitScriptRequestKeepsTheInterpreterRoute() {
        let scripted = ToolRoutingPolicy.decision(
            forTask: "用脚本处理视频",
            offeredToolNames: ["video.transcode", "exec.shell"]
        )
        #expect(scripted.intent == .scripted)
        #expect(!scripted.prefersNativeTools)
    }

    @Test func interpreterGroupsAreDerivedFromOfferedTools() {
        let groups = ToolRoutingPolicy.interpreterGroups(among: ["exec.shell", "shell.open", "exec.localPython", "clipboard.read"])
        #expect(groups == ["shell", "python"])
        #expect(ToolRoutingPolicy.isNativeMediaTool("document.pdf.merge"))
        #expect(ToolRoutingPolicy.isNativeMediaTool("canvas.generate"))
        #expect(!ToolRoutingPolicy.isNativeMediaTool("workspace.readFile"))
        #expect(!ToolRoutingPolicy.isNativeMediaTool("git.commit"))
    }

    @Test func disabledToolsAreNeverInvented() {
        // The ceiling holds no media capability at all: the decision must not
        // fabricate one, and discovery must stay empty.
        let offered = ["workspace.readFile"].map(descriptor)
        let decision = ToolRoutingPolicy.decision(forTask: "视频转码", offeredToolNames: offered.map(\.name))
        #expect(decision.nativeMediaTools.isEmpty)
        #expect(decision.matchedNativeTools.isEmpty)
        #expect(!decision.prefersNativeTools)
        #expect(ToolDiscovery.matches(query: "视频转码", descriptors: offered).isEmpty)
        let index = ToolDiscovery.index(offered)
        #expect(!index.contains("Native-first routing"))
        #expect(!index.contains("exec.shell"))
    }

    // MARK: - Discovery arbitration

    @Test func coveredMediaTaskKeepsTheInterpreterOutOfTheAutomaticSet() {
        let available = ["exec.shell", "exec.localPython", "video.transcode", "video.edit"].map(descriptor)
        let found = ToolDiscovery.matches(query: "把这个视频转码成 mp4", descriptors: available).map(\.name)
        #expect(found.contains("video.transcode"))
        #expect(!found.contains("exec.shell"))
        #expect(!found.contains("exec.localPython"))
    }

    @Test func unrelatedNativeToolKeepsTheInterpreterFallback() {
        let available = ["image.ocr", "exec.shell", "exec.localPython"].map(descriptor)
        let found = ToolDiscovery.matches(query: "把这个视频转码成 mp4", descriptors: available).map(\.name)
        // OCR does not cover video encoding: the guest route stays discoverable
        // and the unrelated native tool is not offered as coverage.
        #expect(found == ["exec.shell", "exec.localPython"])
    }

    @Test func explicitInterpreterRequestIsAlwaysReturned() {
        let available = ["video.transcode", "exec.shell"].map(descriptor)
        // Exact name wins even for a media task.
        #expect(ToolDiscovery.matches(query: "用 exec.shell 把这个视频转码", descriptors: available).map(\.name) == ["exec.shell"])
        // A scripted request keeps the interpreter route without spelling the
        // exact tool name.
        let scripted = ToolDiscovery.matches(query: "用 shell 命令把这个视频转码", descriptors: available).map(\.name)
        #expect(scripted.contains("exec.shell"))
        #expect(scripted.contains("video.transcode"))
    }

    @Test func missingNativeCapabilityKeepsTheInterpreterFallback() {
        let available = ["exec.shell", "exec.localPython", "workspace.readFile"].map(descriptor)
        let found = ToolDiscovery.matches(query: "批量处理视频", descriptors: available).map(\.name)
        #expect(found.contains("exec.shell"))
        #expect(found.contains("exec.localPython"))
    }

    @Test func mixedTaskPrefersMatchedNativeAndKeepsOtherGroups() {
        let available = ["exec.shell", "video.transcode", "document.pdf.inspect", "image.ocr"].map(descriptor)
        let found = ToolDiscovery.matches(query: "把这个视频转码，然后从 PDF 里提取页面", descriptors: available).map(\.name)
        #expect(found.first.map(ToolRoutingPolicy.isNativeMediaTool) == true)
        #expect(found.contains("video.transcode"))
        #expect(found.contains("document.pdf.inspect"))
        #expect(!found.contains("exec.shell"))
    }

    @Test func nonMediaDiscoveryIsUnchanged() {
        let available = ["exec.shell", "workspace.readFile"].map(descriptor)
        let shell = ToolDiscovery.matches(query: "linux 里跑一下这个命令", descriptors: available).map(\.name)
        #expect(shell == ["exec.shell"])
        let workspace = ToolDiscovery.matches(query: "workspace", descriptors: available).map(\.name)
        #expect(workspace == ["workspace.readFile"])
    }

    // MARK: - Availability-aware guidance

    @Test func guidanceNamesOnlyOfferedToolsAndDescribesRealBackends() {
        let index = ToolDiscovery.index(["video.transcode", "exec.shell"].map(descriptor))
        #expect(index.contains("Native-first routing"))
        #expect(index.contains("video.transcode"))
        #expect(index.contains("exec.shell"))
        // Never mention an interpreter entry that this run does not offer.
        #expect(!index.contains("exec.localPython"))
        #expect(!index.contains("media.capabilities"))
        // Native includes configured model routes; no on-device GPU promise is
        // made from a name prefix alone.
        #expect(index.contains("configured model route"))
        #expect(index.contains("never through the emulated guest"))
        #expect(!index.contains("Media rule"))

        let pythonOnly = ToolDiscovery.index(["video.transcode", "exec.localPython"].map(descriptor))
        #expect(pythonOnly.contains("exec.localPython"))
        #expect(!pythonOnly.contains("exec.shell"))
    }

    @Test func guidancePointsAtMediaCapabilitiesOnlyWhenOffered() {
        let index = ToolDiscovery.index(["video.transcode", "media.capabilities", "exec.shell"].map(descriptor))
        #expect(index.contains("media.capabilities"))
        #expect(index.contains("does not prove the requested operation"))
    }

    @Test func guidanceWithoutNativeToolsStatesTheFallback() {
        let index = ToolDiscovery.index([descriptor("exec.shell")])
        #expect(index.contains("Media rule"))
        #expect(!index.contains("Native-first routing"))
        // environment.prepareLinux alone is not an execution fallback.
        let prepareOnly = ToolDiscovery.index([descriptor("environment.prepareLinux")])
        #expect(!prepareOnly.contains("Media rule"))
    }

    // MARK: - Prompt layer

    @Test func promptCarriesCapabilityRoutingInCloudAndLocalContracts() {
        let cloud = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx", toolsAvailable: true)
        let routing = cloud.range(of: "# Capability routing")
        let mode = cloud.range(of: "# Chat mode")
        #expect(routing != nil && mode != nil)
        #expect(routing!.lowerBound < mode!.lowerBound)
        #expect(cloud.contains("do not request the global tool directory"))
        #expect(cloud.contains("never present a scripted or emulated approximation"))

        let local = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx", compactForLocal: true)
        #expect(local.contains("Route by capability"))
        #expect(local.utf8.count < 8_000)
    }
}
