// FloeExecutionTests — static contracts for the bundled Linux cleanup script
// and its service payload. No guest, job, network or host cleanup is started.

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeExecution

@Suite("Linux cache cleanup script contracts")
struct LinuxCacheCleanupScriptContractTests {
    @Test("Script is fixed-root, model-free and never sweeps generic home/tmp trees")
    func scriptBoundary() {
        let source = LinuxCacheCleanupScript.source
        #expect(source.hasPrefix("#!/bin/sh\n"))
        #expect(source.contains("FLOE_LINUX_CLEANUP_V1"))
        #expect(source.contains("/floe/env/cache/pip"))
        #expect(source.contains("/floe/env/cache/npm"))
        #expect(source.contains("/var/tmp/floe-runtime"))
        #expect(source.contains("apt-get clean"))
        #expect(source.contains("cleanup_already_running"))
        #expect(source.contains("skipped-busy"))
        #expect(source.contains("skipped-symlink"))
        #expect(source.contains("find \"$_root\" -type l"))
        #expect(!source.contains("rm -rf \"$HOME/.cache\""))
        #expect(!source.contains("find \"$HOME/.cache\""))
        #expect(!source.contains("huggingface"))
        #expect(!source.contains("torch"))
        #expect(!source.contains("pip install"))
        #expect(!source.contains("npm install"))
        #expect(!source.contains("apt-get remove"))
        #expect(!source.contains("dpkg --purge"))
        #expect(!source.contains("rm -rf / "))
        #expect(!source.contains("curl "))
        #expect(!source.contains("wget "))
    }

    @Test("Native payload carries the script and validated env only: no command/path argument")
    func payloadShape() throws {
        let data = try LinuxCacheCleanupService.makePayload(
            script: LinuxCacheCleanupScript.source,
            mode: "clean",
            categories: [.apt, .npm]
        )
        let raw = try JSONSerialization.jsonObject(with: data)
        let object = try #require(raw as? [String: Any])
        #expect(object["command"] == nil)
        #expect(object["cwd"] == nil)
        #expect(object["args"] == nil)
        #expect(object["script"] as? String == LinuxCacheCleanupScript.source)
        let env = try #require(object["env"] as? [String: String])
        #expect(env["FLOE_CLEANUP_SCHEMA"] == LinuxCacheCleanupScript.schema)
        #expect(env["FLOE_CLEANUP_NATIVE"] == "1")
        #expect(env["FLOE_CLEANUP_MODE"] == "clean")
        #expect(env["FLOE_CLEANUP_CATEGORIES"] == "apt,npm")
        #expect(object["maxOutputBytes"] as? Int == 262_144)
        #expect(object["timeoutPolicy"] as? String == "advisory")
    }

    @Test("Category validation refuses unknown, duplicate and non-canonical order")
    func categoryValidation() {
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["npm", "apt"]) == [.apt, .npm])
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["apt", "apt"]) == nil)
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["../Documents"]) == nil)
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["scratch"]) == nil)
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["apt", "scratch"]) == nil)
        #expect(LinuxCacheCleanupCategory.allKnown == [.apt, .pip, .npm])
        #expect(LinuxCacheCleanupCategory.defaultSafe == [.apt, .pip, .npm])
        #expect(!LinuxCacheCleanupCategory.scratch.isDefaultSafe)
    }

    @Test("Parser reports actual cleanup, busy skip, guest df and partial evidence")
    func parsesResult() throws {
        let output = """
        FLOE_LINUX_CLEANUP_V1
        schema=floe.linux-cache-cleanup.v1
        mode=clean
        df_path=/floe/env
        df_available_before_bytes=1000000
        category=apt status=cleaned bytes_before=500000 bytes_after=100000 note=package_manager_lock_held
        category=pip status=skipped-busy bytes_before=900000 bytes_after=900000 note=cache_in_use
        df_available_after_bytes=1400000
        cancelled=0
        summary cleaned_categories=1 skipped_categories=1 failed_categories=0
        """
        let receipt = try #require(LinuxCacheCleanupScriptResult.parse(output))
        #expect(receipt.state == "completed")
        #expect(receipt.mode == "clean")
        #expect(receipt.dfAvailableBeforeBytes == 1_000_000)
        #expect(receipt.dfAvailableAfterBytes == 1_400_000)
        #expect(receipt.categoryResults.count == 2)
        #expect(receipt.categoryResults[0].status == "cleaned")
        #expect(receipt.categoryResults[1].status == "skipped-busy")
        #expect(!receipt.partial)
        #expect(receipt.modelSummary.contains("not iPad physical space"))
    }

    @Test("Cancelled output is never reported as a successful cleanup")
    func cancelledOutput() throws {
        let output = """
        FLOE_LINUX_CLEANUP_V1
        schema=floe.linux-cache-cleanup.v1
        mode=clean
        df_path=/floe/env
        df_available_before_bytes=1000
        category=apt status=partial bytes_before=100 bytes_after=100 note=delete_failed
        df_available_after_bytes=1000
        cancelled=1
        summary cleaned_categories=0 skipped_categories=0 failed_categories=1
        error=cancelled
        """
        let receipt = try #require(LinuxCacheCleanupScriptResult.parse(output))
        #expect(receipt.state == "cancelled")
        #expect(receipt.cancelled)
    }

    @Test("Malformed or missing protocol output is not guessed")
    func malformedOutput() {
        #expect(LinuxCacheCleanupScriptResult.parse("done") == nil)
        #expect(LinuxCacheCleanupScriptResult.parse("") == nil)
    }

    @Test("Unverified runtime/origin errors map to repair guidance, never to a reset claim")
    func repairGuidance() throws {
        let guidance = try #require(LinuxCacheCleanupEnvironmentRepair.guidance(
            forMessage: "Linux runtime origin is unverified; image must be revalidated"))
        #expect(guidance.contains("Execution Environments") || guidance.contains("执行环境"))
        #expect(guidance.contains("did not reset disk") || guidance.contains("没有重置磁盘"))
        #expect(LinuxCacheCleanupEnvironmentRepair.guidance(forMessage: "network timeout") == nil)
    }

    @Test("Legacy scratch is retained without traversing or deleting generic temporary files")
    func scratchHasNoDeletionCapability() throws {
        let source = LinuxCacheCleanupScript.source
        let start = try #require(source.range(of: "clean_scratch() {"))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        #expect(body.contains("emit_category scratch retained unknown unknown ownership_unverified"))
        #expect(!body.contains("rm "))
        #expect(!body.contains("find "))
        #expect(!body.contains("du_bytes"))
        #expect(!source.contains("SCRATCH_MIN_AGE_MINUTES"))
        let output = """
        FLOE_LINUX_CLEANUP_V1
        mode=clean
        category=scratch status=retained bytes_before=unknown bytes_after=unknown note=ownership_unverified
        cancelled=0
        """
        let receipt = try #require(LinuxCacheCleanupScriptResult.parse(output))
        #expect(receipt.categoryResults.first?.status == "retained")
        #expect(receipt.categoryResults.first?.bytesBefore == nil)
    }

    @Test("No offered schema or native payload can select scratch")
    func schemasAndPayloadRefuseScratch() throws {
        for schema in [LinuxCacheCleanupInspectTool.parametersJSON, LinuxCacheCleanupCleanTool.parametersJSON] {
            let root = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
            let properties = try #require(root["properties"] as? [String: Any])
            #expect(properties["includeScratch"] == nil)
            let categories = try #require(properties["categories"] as? [String: Any])
            let items = try #require(categories["items"] as? [String: Any])
            #expect(items["enum"] as? [String] == ["apt", "pip", "npm"])
        }
        do {
            _ = try LinuxCacheCleanupService.makePayload(
                script: LinuxCacheCleanupScript.source, mode: "clean", categories: [.apt, .scratch])
            Issue.record("A mixed legacy scratch payload must be refused, not silently narrowed")
        } catch { }
    }

}
