#!/usr/bin/env python3
"""Execute pinned native save/close fragments with controlled document callbacks.

Requires macOS/Xcode. This is a lifecycle unit harness, NOT a full UIKit,
Collabora, file-provider, rendering, keyboard or device integration test.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import shutil

BASE = Path(__file__).resolve().parent.parent / "ThirdParty/Collabora"


def checked_source(root, name, lock):
    path = root / name
    source = path.read_text()
    expected = lock["embeddingOverlay"]["files"][name]["preparedSHA256"]
    if hashlib.sha256(source.encode()).hexdigest() != expected:
        raise ValueError("Lifecycle source does not match prepared pin: " + name)
    return source


def check(root):
    lock = json.loads((BASE / "engine.lock.json").read_text())
    for name in lock["embeddingOverlay"]["files"]:
        checked_source(root, name, lock)
    controller = checked_source(root, "ios/Mobile/DocumentViewController.mm", lock)
    kit = checked_source(root, "kit/ChildSession.cpp", lock)
    start = controller.index("- (IBAction)dismissDocumentViewController {")
    close = controller[start:controller.index("\n- (void)webView:", start)]
    start = controller.index("- (void)bye {")
    bye = controller[start:controller.index("\n- (void)exportFileURL:", start)]
    start = kit.index("                dispatch_async(dispatch_get_main_queue(), ^{", kit.index("const bool engineSaved ="))
    save = kit[start:kit.index("\n#elif defined(__ANDROID__)", start)]
    harness = HEADER + "\nstatic void Save(CODocument *document, bool engineSaved) {\n" + save + "\n}\n"
    harness += "@implementation DocumentViewController\n" + close + bye + CONTROLLER_END + MAIN
    with tempfile.TemporaryDirectory(prefix="floe-native-lifecycle-") as temporary:
        folder = Path(temporary)
        source, executable = folder / "lifecycle.mm", folder / "lifecycle"
        source.write_text(harness)
        subprocess.run(["xcrun", "--sdk", "macosx", "clang++", "-std=c++20", "-fobjc-arc", "-fblocks", "-Wall", "-Werror", "-framework", "Foundation", str(source), "-o", str(executable)], check=True, capture_output=True, text=True)
        result = subprocess.run([str(executable)], check=True, capture_output=True, text=True, timeout=20)
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        subprocess.run(["xcrun", "--sdk", "iphoneos", "clang++", "-x", "objective-c++", "-std=c++20", "-fobjc-arc", "-fmodules", "-fsyntax-only", "-target", "arm64-apple-ios26.0", "-isysroot", sdk, str(root / "ios/Mobile/DocumentViewController.h")], check=True, capture_output=True, text=True)
    return {"sourceCommit": lock["commit"], "patchSHA256": lock["embeddingOverlay"]["sha256"],
            "kind": "compiled native fragments with controlled document and view doubles",
            "checksPassed": result.stdout.strip().splitlines(),
            "nativePublicHeadersSyntaxPassed": True,
            "fullNativeControllerCompiled": False, "deviceRoundtripPassed": False}


def check_source(source_root):
    """Prepare all locked overlay files, not a complete engine bundle."""
    lock = json.loads((BASE / "engine.lock.json").read_text())
    overlay = lock["embeddingOverlay"]
    patch = BASE / overlay["patch"]
    if hashlib.sha256(patch.read_bytes()).hexdigest() != overlay["sha256"]:
        raise ValueError("Embedding patch checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="floe-lifecycle-inputs-") as folder:
        root = Path(folder)
        for name, hashes in overlay["files"].items():
            source = source_root / name
            if hashlib.sha256(source.read_bytes()).hexdigest() != hashes["originalSHA256"]:
                raise ValueError("Original source is not the pinned revision: " + name)
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=root, check=True, capture_output=True, text=True)
        subprocess.run(["git", "apply", str(patch)], cwd=root, check=True, capture_output=True, text=True)
        return check(root)


HEADER = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <cassert>
#include <cstdio>
static NSString * const UIKeyboardWillHideNotification = @"fixtureKeyboard";
static const NSInteger UIDocumentSaveForOverwriting = 1;
static int closedFD = -1;
static void fakeSocketClose(int descriptor) { assert(closedFD == -1); closedFD = descriptor; }

@interface CODocument : NSObject {
@public NSURL *copyFileURL;
}
@property NSURL *fileURL;
@property (copy) void (^floeSaveCompletion)(BOOL);
@property (copy) void (^savePending)(BOOL);
@property (copy) void (^closePending)(BOOL);
@property NSInteger saveCount;
@property NSInteger closeCount;
- (void)saveToURL:(NSURL *)url forSaveOperation:(NSInteger)operation completionHandler:(void (^)(BOOL))completion;
- (void)closeWithCompletionHandler:(void (^)(BOOL))completion;
@end
@implementation CODocument
- (void)saveToURL:(NSURL *)url forSaveOperation:(NSInteger)operation completionHandler:(void (^)(BOOL))completion {
    assert([NSThread isMainThread]); self.saveCount++; self.savePending = completion;
}
- (void)closeWithCompletionHandler:(void (^)(BOOL))completion {
    assert([NSThread isMainThread]); self.closeCount++; self.closePending = completion;
}
@end
@interface Handler : NSObject
@property NSInteger removed;
- (void)removeScriptMessageHandlerForName:(NSString *)name;
@end
@implementation Handler
- (void)removeScriptMessageHandlerForName:(NSString *)name { self.removed++; }
@end
@interface Configuration : NSObject
@property Handler *userContentController;
@end
@implementation Configuration
@end
@interface Web : NSObject
@property Configuration *configuration;
@property BOOL removed;
- (void)removeFromSuperview;
@end
@implementation Web
- (void)removeFromSuperview { self.removed = YES; }
@end
@interface DocumentViewController : NSObject {
@public BOOL floeClosing; BOOL floeClosed;
int closeNotificationPipeForForwardingThread[2];
}
@property CODocument *document;
@property Web *webView;
@property (copy) void (^floeCloseCompletion)(BOOL);
@property NSInteger dismissals;
- (IBAction)dismissDocumentViewController;
- (void)bye;
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion;
@end
'''
CONTROLLER_END = r'''
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    self.dismissals++;
    if (completion) completion();
}
@end
static void Drain(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!done && [limit timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(done);
}
'''
MAIN = r'''
int main(void) { @autoreleasepool {
    NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]);
    CODocument *doc = [CODocument new];
    doc->copyFileURL = [root URLByAppendingPathComponent:@"engine.docx"];
    doc.fileURL = [root URLByAppendingPathComponent:@"working.docx"];
    NSData *bytes = [@"unsaved document fixture" dataUsingEncoding:NSUTF8StringEncoding];
    assert([bytes writeToURL:doc->copyFileURL atomically:YES]);
    __block NSInteger saveResults = 0;
    __block BOOL saved = YES;
    doc.floeSaveCompletion = ^(BOOL result) { assert([NSThread isMainThread]); saveResults++; saved = result; };
    Save(doc, false); Drain();
    assert(doc.saveCount == 0 && saveResults == 1 && !saved);
    puts("engine failure reports failure without committing");
    Save(doc, true); Drain();
    assert(doc.saveCount == 1 && saveResults == 1);
    puts("engine success waits for document persistence callback");
    doc.savePending(NO); doc.savePending = nil; Drain();
    assert(saveResults == 2 && !saved && [[NSData dataWithContentsOfURL:doc->copyFileURL] isEqual:bytes]);
    puts("failed persistence retains the engine copy");
    Save(doc, true); Drain(); doc.savePending(YES); doc.savePending = nil; Drain();
    assert(saveResults == 3 && saved && [[NSData dataWithContentsOfURL:doc->copyFileURL] isEqual:bytes]);
    puts("successful persistence retains the working engine copy for continued editing");

    DocumentViewController *vc = [DocumentViewController new];
    vc.document = doc; vc.webView = [Web new];
    vc.webView.configuration = [Configuration new];
    vc.webView.configuration.userContentController = [Handler new];
    Web *web = vc.webView;
    vc->closeNotificationPipeForForwardingThread[0] = -1;
    vc->closeNotificationPipeForForwardingThread[1] = -1;
    __block NSInteger closeResults = 0;
    __block BOOL closed = YES;
    vc.floeCloseCompletion = ^(BOOL result) { assert([NSThread isMainThread]); closeResults++; closed = result; };
    [vc bye]; Drain(); [vc bye]; Drain();
    assert(closedFD == -1 && doc.closeCount == 1 && closeResults == 0 && vc.webView == web);
    puts("uninitialized and duplicate close requests do not close another descriptor or dismiss early");
    doc.closePending(NO); doc.closePending = nil; Drain();
    assert(closeResults == 1 && !closed && vc.webView == web && !web.removed && vc.dismissals == 0);
    assert([[NSData dataWithContentsOfURL:doc->copyFileURL] isEqual:bytes]);
    puts("failed close retains view and file and reports failure");
    [vc bye]; Drain(); assert(doc.closeCount == 2);
    doc.closePending(YES); doc.closePending = nil; Drain();
    assert(closeResults == 2 && closed && vc.webView == nil && web.removed);
    assert(web.configuration.userContentController.removed == 3 && vc.dismissals == 0);
    assert([[NSData dataWithContentsOfURL:doc->copyFileURL] isEqual:bytes]);
    puts("successful close releases web handlers before handing control to host without deleting files");
    [vc bye]; Drain(); [vc dismissDocumentViewController]; Drain();
    assert(doc.closeCount == 2 && closeResults == 2);
    puts("completed close cannot dispatch or complete again");
    assert([[NSFileManager defaultManager] removeItemAtURL:root error:nil]);
    return 0;
} }
'''

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prepared_root", type=Path)
    parser.add_argument("--original-source", action="store_true", help="Input is pinned upstream source; prepare only lifecycle fragments in a temporary directory")
    args = parser.parse_args()
    try:
        print(json.dumps(check_source(args.prepared_root) if args.original_source else check(args.prepared_root), indent=2))
    except subprocess.CalledProcessError as error:
        print(error.stdout or "")
        print(error.stderr or "")
        raise
