#!/usr/bin/env python3
"""Build 233 R1/R2/R3 contract checks for the durable Office stage trace.

Proves the native host and the App half of the contract stay wired:

* the pinned host emits one content-free breadcrumb for every stage the
  diagnosis needs (open settle, permission, render probe, edit entry chain,
  close ack) through `floeStage:`, each carrying a process memory sample;
* web-content termination is recovered by adding the optional
  `WKNavigationDelegate` callback to the upstream delegate class (a category),
  never by replacing or proxying the delegate, and the host only accepts the
  notification from its own editor;
* the App records the native stages with the controller/generation guard,
  samples memory at the mount/open/edit/render stages, installs the bounded
  idle-model shed, and observes memory warnings;
* the stage block still compiles as Objective-C++ (syntax checked against the
  macOS SDK with a documented `os_proc_available_memory` shim, because that
  symbol is iOS-only).
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
HOST = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm"
HEADER = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.h"
APP = REPO_ROOT / "FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift"
DIAGNOSTICS = REPO_ROOT / "FloeAgent/FloeApp/Workspace/OfficeStageDiagnostics.swift"
ENVIRONMENT = REPO_ROOT / "FloeAgent/FloeApp/App/AppEnvironment.swift"
ADAPTER = REPO_ROOT / "FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift"

REQUIRED_STAGES = (
    "open",
    "permission",
    "render-probe",
    "first-paint",
    "visible-render",
    "visible-render-failed",
    "visible-render-unobserved",
    "edit-surface-armed",
    "edit-entry-deferred",
    "edit-entry",
    "edit-entry-result",
    "edit-entry-settled-without-entry",
    "close.bye",
    "close.ack",
    "webcontent.terminated",
)


def compile_stage_block():
    """Syntax-check the native stage block with the macOS SDK.

    The block is compiled standalone with minimal stubs (the real
    `DocumentViewController` and engine headers are only available in the
    cloud native-host build). `os_proc_available_memory` is unavailable on
    macOS, so the check defines a shim under the same name for the syntax pass.
    """
    text = HOST.read_text(encoding="utf-8")
    block = text.split("// FLOE_OFFICE_STAGE_BEGIN", 1)[1].split("// FLOE_OFFICE_STAGE_END", 1)[0]
    source = '''#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#include <os/proc.h>
#if !TARGET_OS_IPHONE
static size_t floe_macos_available_memory(void) { return 0; }
#define os_proc_available_memory floe_macos_available_memory
#endif
@interface UIViewController : NSObject
@end
@implementation UIViewController
@end
@interface DocumentViewController : UIViewController
@property (nonatomic, strong) WKWebView *webView;
@end
@implementation DocumentViewController
@end
''' + block + '''
void floe_stage_compile_probe(void) { (void)FloeOfficeMemoryFacts(); }
'''
    with tempfile.TemporaryDirectory(prefix="floe-stage-") as folder:
        path = Path(folder) / "stage.mm"
        path.write_text(source, encoding="utf-8")
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                      text=True).strip()
        subprocess.run(["xcrun", "--sdk", "macosx", "clang++", "-fsyntax-only", "-std=c++20",
                        "-fobjc-arc", "-Wall", "-Werror", "-isysroot", sdk, str(path)],
                       check=True, capture_output=True, text=True)
    return {"stageBlockCompiled": True, "osProcShim": "macOS syntax pass only; iOS symbol"}


class NativeStageContractTests(unittest.TestCase):
    def setUp(self):
        self.host = HOST.read_text(encoding="utf-8")
        self.header = HEADER.read_text(encoding="utf-8")

    def test_every_required_stage_is_recorded(self):
        missing = [stage for stage in REQUIRED_STAGES
                   if f'floeStage:@"{stage}"' not in self.host]
        self.assertEqual(missing, [], f"native host is missing stage breadcrumbs: {missing}")

    def test_stage_helper_samples_memory(self):
        helper = self.host.split("- (void)floeStage:(NSString *)stage facts:(NSDictionary<NSString *, id> *)facts {",
                                  1)[1].split("\n}\n", 1)[0]
        self.assertIn("FloeOfficeMemoryFacts()", helper)
        memory = self.host.split("static NSDictionary<NSString *, id> *FloeOfficeMemoryFacts(void)",
                                 1)[1].split("\n}\n", 1)[0]
        self.assertIn("os_proc_available_memory()", memory)
        self.assertIn("memAvailableMB", memory)
        self.assertIn("memPhysicalMB", memory)
        # A raw 0 must be recorded as 0, never folded away.
        self.assertNotIn("?:", memory)
        self.assertNotIn("if (available", memory)

    def test_app_recorder_api_is_exposed(self):
        for name in ("onStageEvent", "onWebContentProcessTerminated", "fontDiscoveryFacts"):
            self.assertIn(name, self.header, f"header is missing {name}")
            self.assertIn(name, self.host, f"host is missing {name}")

    def test_web_content_death_uses_the_upstream_delegate_class(self):
        block = self.host.split("// FLOE_OFFICE_STAGE_BEGIN", 1)[1].split("// FLOE_OFFICE_STAGE_END", 1)[0]
        self.assertIn("DocumentViewController (FloeWebContentRecovery)", block)
        self.assertIn("webViewWebContentProcessDidTerminate:", block)
        self.assertNotIn("navigationDelegate =", block,
                         "recovery must add the callback to the upstream delegate class, "
                         "never replace the delegate")
        # The host only accepts termination from its own editor instance.
        self.assertIn("notification.object != self.editor", self.host)
        self.assertIn("object:_editor", self.host)

    def test_close_ack_and_bye_are_breadcrumbed(self):
        begin_close = self.host.split("- (void)beginClose", 1)[1]
        self.assertIn('floeStage:@"close.bye"', begin_close)
        completion = self.host.split("_editor.floeCloseCompletion", 1)[1].split("};", 1)[0]
        self.assertIn('floeStage:@"close.ack"', completion)


class AppStageContractTests(unittest.TestCase):
    def setUp(self):
        self.app = APP.read_text(encoding="utf-8")
        self.diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")

    def test_app_maps_native_stages_and_guards_late_callbacks(self):
        self.assertIn('NSSelectorFromString("setOnStageEvent:")', self.app)
        self.assertIn("recordNativeStage", self.app)
        guard = self.app.split("let onStage:", 1)[1].split("}", 1)[0]
        self.assertIn("self.controller === native", guard)
        self.assertIn("self.openGeneration.isCurrent(generation)", guard)
        self.assertIn("!self.runtimeFailed", guard)

    def test_memory_samples_are_attached_to_key_stages(self):
        for stage in ("controller.mounted", "engine.open", "edit.attempt", "engine.visibleRender"):
            marker = f'recordStage("{stage}"'
            self.assertIn(marker, self.app, f"missing stage {stage}")
            segment = self.app.split(marker, 1)[1].split("\n", 6)
            joined = "\n".join(segment)
            self.assertIn("withMemory: true", joined,
                          f"stage {stage} must carry a memory sample")

    def test_web_content_termination_is_a_recoverable_failure(self):
        self.assertIn('NSSelectorFromString("setOnWebContentProcessTerminated:")', self.app)
        self.assertIn("OfficeRenderFailure.webContentProcessTerminated()", self.app)
        self.assertIn("webContentProcessTerminated", self.diagnostics + self.app)

    def test_memory_sample_preserves_a_real_zero(self):
        sample = self.diagnostics.split("enum OfficeMemorySample", 1)[1]
        self.assertIn("os_proc_available_memory()", sample)
        self.assertNotIn("availableBytes ?? ", sample)

    def test_memory_warning_observes_and_sheds_idle_only(self):
        self.assertIn("didReceiveMemoryWarningNotification", self.app)
        self.assertIn("handleOfficeMemoryWarning", self.app)
        self.assertIn("memory.warningShedSkipped", self.app)

    def test_idle_shed_is_non_blocking_and_claim_checked(self):
        adapter = ADAPTER.read_text(encoding="utf-8")
        method = adapter.split("func shedIdleResidentEngineForOffice", 1)[1].split("\n    private func acquireInferenceSlot", 1)[0]
        self.assertIn("!inferenceBusy", method)
        self.assertIn("engineLeaseCount == 0", method)
        self.assertIn("taskResidency.activeTaskCount == 0", method)
        self.assertNotIn("await acquireInferenceSlot()", method,
                         "the Office shed must never wait on the FIFO inference slot")
        self.assertIn("releaseResidentEngine", method)
        environment = ENVIRONMENT.read_text(encoding="utf-8")
        self.assertIn("func shedIdleLocalModelForOffice", environment)
        # Every Office surface reaches the same shed through the process-wide
        # coordination seam; AppEnvironment installs it at launch.
        self.assertIn("OfficeMemoryCoordination.shared.install", environment)
        self.assertIn("OfficeMemoryCoordination.shared.shedIdleResidentEngine", self.app)
        coordination = (REPO_ROOT / "FloeAgent/FloeApp/Platform/OfficeMemoryCoordination.swift")
        self.assertTrue(coordination.is_file())
        source = coordination.read_text(encoding="utf-8")
        self.assertIn("func install(shed:", source)
        self.assertIn("func shedIdleResidentEngine(reason:", source)


class CompilationTests(unittest.TestCase):
    def test_stage_block_compiles(self):
        result = compile_stage_block()
        self.assertTrue(result["stageBlockCompiled"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
