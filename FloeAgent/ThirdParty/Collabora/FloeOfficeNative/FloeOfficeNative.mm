// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
// Runtime startup adapted from the pinned Collabora Mobile AppDelegate (MPL-2.0).
#import "config.h"
#import "FloeOfficeNative.h"
#import <WebKit/WebKit.h>
#define LIBO_INTERNAL_ONLY
#import <COKit/COKitInit.h>
#include <comphelper/kit.hxx>
#include <i18nlangtag/languagetag.hxx>
#include <common/LangUtil.hpp>
#include <rtl/bootstrap.hxx>
#include <Poco/Util/LayeredConfiguration.h>
#include <exception>
#include <string>
#import "ios.h"
#import "CODocument.h"
#import "DocumentViewController.h"
#import "FakeSocket.hpp"
#import "Kit.hpp"
#import "Log.hpp"
#import "ProcUtil.hpp"
#import "COOLWSD.hpp"
#import "SetupKitEnvironment.hpp"
#include "FloeOfficeAttachment.hxx"

NSErrorDomain const FloeOfficeNativeErrorDomain = @"org.floeagent.office.native";
NSNotificationName const FloeOfficeNativeRuntimeDidFailNotification = @"FloeOfficeNativeRuntimeDidFail";
@interface FloeOfficeAttachmentInfo ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, readwrite) unsigned long long byteCount;
@end
@implementation FloeOfficeAttachmentInfo
@end
// The framework excludes upstream AppDelegate.mm, which normally owns these.
NSString *app_locale;
NSString *app_text_direction;

static NSError *OfficeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:FloeOfficeNativeErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSError *OfficeAttachmentReadError(NSInteger code, NSString *description, const std::exception &failure) {
    // Engine-only attachment readers throw fixed format/IO diagnostics, never
    // document contents. Keep them for qualification without changing UI copy.
    return [NSError errorWithDomain:FloeOfficeNativeErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description,
        NSDebugDescriptionErrorKey: [NSString stringWithUTF8String:failure.what()] ?: @"Attachment read failed"
    }];
}

// FLOE_EDITOR_LANGUAGE_BEGIN
static NSString *FloeEditorLanguage(NSArray<NSString *> *preferences) {
    // Match the engine's --with-lang resources, respecting the user's script
    // and preference order. Apple can supply zh-Hans-TW: passing that unmatched
    // tag through the kit loses UI translations and corrupts General on XLSX
    // export. Foundation correctly selects zh-CN for Hans, zh-TW for Hant.
    // This selects the editor language; it does not rewrite document styles,
    // number-format locales, or the user's persistent language preferences.
    NSArray<NSString *> *supported = @[@"en-US", @"zh-CN", @"zh-TW"];
    NSString *language = [NSBundle preferredLocalizationsFromArray:supported
                                                  forPreferences:preferences].firstObject;
    return [supported containsObject:language] ? language : @"en-US";
}
// FLOE_EDITOR_LANGUAGE_END

// FLOE_NATIVE_DRAIN_SCRIPT_BEGIN
static NSString *FloeNativeDrainScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    // Native queues own the bytes. Notifications only ask us to drain them:
    // a burst must not become concurrent proxy polls and a false idle timeout.
    const install = socket => {
        if (!window.ThisIsTheiOSApp || !socket || socket.floeNativeDrainState ||
            typeof socket.uri !== 'string' || !socket.uri.startsWith('cool:/cool/mobilesocket') ||
            typeof socket.getEndPoint !== 'function' || typeof socket.parseIncomingArray !== 'function') return socket;
        const state = socket.floeNativeDrainState = {
            requests: 0, responses: 0, failures: 0, pending: false, active: false
        };
        const drain = () => {
            if (socket.unloading || socket.readyState === 3) { state.pending = false; return; }
            if (state.active || socket.msgInflight > 0 || socket.readyState !== 1) return;
            state.pending = false;
            state.active = true;
            socket.msgInflight++;
            state.requests++;
            const request = new XMLHttpRequest();
            let failed = false;
            const fail = () => {
                if (failed) return;
                failed = true;
                state.failures++;
                state.pending = false;
                if (!socket.unloading && socket.readyState !== 3) socket._signalErrorClose();
            };
            request.addEventListener('load', () => {
                if (socket.unloading || socket.readyState === 3) return;
                if (request.status !== 200) { fail(); return; }
                state.responses++;
                socket.lastDataTimestamp = performance.now();
                socket.parseIncomingArray(new Uint8Array(request.response));
            });
            const finish = () => {
                if (!state.active) return;
                state.active = false;
                socket.msgInflight = Math.max(0, socket.msgInflight - 1);
                if (!failed && state.pending) drain();
            };
            request.addEventListener('loadend', finish);
            for (const event of ['error', 'abort', 'timeout']) request.addEventListener(event, fail);
            try {
                request.open('POST', socket.getEndPoint('write'));
                request.responseType = 'arraybuffer';
                // Mobile commands travel through postMobileMessage, never this
                // receive request. Keep the upstream framing terminator.
                request.send('.');
            } catch (_) { fail(); finish(); }
        };
        socket.doSend = () => { state.pending = true; drain(); };
        const onopen = socket.onopen;
        socket.onopen = function () {
            const result = typeof onopen === 'function' ? onopen.apply(this, arguments) : undefined;
            if (state.pending) drain();
            return result;
        };
        // A request started by the original socket before document-end may
        // still be in flight. Once it ends, replay only the drain notification.
        const resume = () => {
            if (socket.unloading || socket.readyState === 3) return;
            if (socket.msgInflight > 0 && !state.active) { setTimeout(resume, 25); return; }
            if (state.pending) drain();
        };
        if (socket.msgInflight > 0) setTimeout(resume, 25);
        return socket;
    };
    if (!window.ThisIsTheiOSApp) return;
    install(window.socket);
    const create = window.createWebSocket;
    if (typeof create === 'function' && !create.floeNativeDrainInstalled) {
        const wrapped = function () { return install(create.apply(this, arguments)); };
        wrapped.floeNativeDrainInstalled = true;
        window.createWebSocket = wrapped;
    }
})();
)FLOE_JS"];
}
// FLOE_NATIVE_DRAIN_SCRIPT_END

// FLOE_FONT_CATALOG_BEGIN
// The embedded engine discovers fonts once and caches that discovery inside
// its versioned profile. A stale cache from a build that predates the staged
// CJK families (or a post-install font copy that changed) makes every Chinese
// glyph render as a tofu box even though the font files are present. The
// profile identity therefore includes a fingerprint of the staged font
// catalog: when the catalog changes, a fresh profile re-runs discovery, while
// previous profiles are retained for recovery.
static NSString *FloeBundledFontCatalogFingerprint(NSBundle *bundle) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    // Both staged locations the engine scans: the app-level Fonts directory
    // (bundled CJK families) and the engine's own share/fonts resources.
    for (NSString *relative in @[@"Fonts", @"share/fonts"]) {
        NSURL *resourceRoot = [NSURL fileURLWithPath:bundle.resourcePath isDirectory:YES];
        NSURL *root = [resourceRoot URLByAppendingPathComponent:relative isDirectory:YES];
        NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager enumeratorAtURL:root
                                                      includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                    errorHandler:nil];
        for (NSURL *url in enumerator) {
            NSNumber *size = nil;
            [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            [entries addObject:[NSString stringWithFormat:@"%@:%@", url.lastPathComponent, size ?: @0]];
        }
    }
    if (entries.count == 0) { return @"no-fonts"; }
    [entries sortUsingSelector:@selector(compare:)];
    // FNV-1a over the sorted catalog: stable across launches, cheap, and only
    // identifies the catalog (never file contents or user data).
    uint64_t hash = 1469598103934665603ULL;
    for (NSString *entry in entries) {
        const char *bytes = entry.UTF8String;
        for (const char *cursor = bytes; cursor && *cursor; cursor++) {
            hash ^= (uint8_t)*cursor;
            hash *= 1099511628211ULL;
        }
    }
    return [NSString stringWithFormat:@"%llu-%08llx",
            (unsigned long long)entries.count, (unsigned long long)hash];
}
// FLOE_FONT_CATALOG_END

// FLOE_INK_GATING_SCRIPT_BEGIN
// Pencil-only annotation input: while annotation mode is on, only Apple
// Pencil pointer events ('pen') reach the document's freehand tool; finger
// pointer events are stopped so a finger keeps navigating the document.
// WKWebView's own gesture recognizers are untouched, so pinching/scrolling
// stays native.
static NSString *FloeInkInputGatingScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    const install = () => {
        if (window.__floeInkGatingInstalled) return;
        window.__floeInkGatingInstalled = true;
        window.__floePencilOnly = false;
        const isDrawing = () => window.__floePencilOnly === true;
        const blockFinger = (event) => {
            if (!isDrawing()) return;
            const pointerType = event.pointerType || '';
            if (pointerType === 'pen' || pointerType === 'mouse') return;
            if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
            if (typeof event.stopPropagation === 'function') event.stopPropagation();
            if (typeof event.preventDefault === 'function') event.preventDefault();
        };
        for (const type of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel']) {
            window.addEventListener(type, blockFinger, { capture: true, passive: false });
        }
    };
    if (document.readyState === 'loading')
        document.addEventListener('DOMContentLoaded', install, { once: true });
    else install();
})();
)FLOE_JS"];
}
// FLOE_INK_GATING_SCRIPT_END

// FLOE_READONLY_SCRIPT_BEGIN
static NSString *FloeReadOnlyScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    // Native preview permission cannot be relaxed by the mobile edit button,
    // a menu, or a later server presentation update. Backend session permission
    // and UIDocument persistence independently enforce the same boundary.
    const install = () => {
        const proto = window.L && window.L.Map && window.L.Map.prototype;
        if (!proto || typeof proto.setPermission !== 'function' ||
            typeof proto._enterReadOnlyMode !== 'function') return;
        const setPermission = proto.setPermission;
        const enterReadOnly = proto._enterReadOnlyMode;
        const hideEditEntry = () => {
            const button = document.getElementById('mobile-edit-button');
            if (button) {
                button.hidden = true;
                button.setAttribute('aria-hidden', 'true');
                button.setAttribute('tabindex', '-1');
            }
        };
        const style = document.createElement('style');
        style.textContent = '#mobile-edit-button { display: none !important; }';
        document.head.appendChild(style);
        proto.setPermission = function () {
            const result = setPermission.call(this, 'readonly');
            hideEditEntry();
            return result;
        };
        proto._enterEditMode = function () {
            const result = enterReadOnly.call(this, 'readonly');
            hideEditEntry();
            return result;
        };
        proto._switchToEditMode = proto._proceedEditMode = function () {
            hideEditEntry();
            return false;
        };
        hideEditEntry();
    };
    if (document.readyState === 'loading')
        document.addEventListener('DOMContentLoaded', install, { once: true });
    else install();
})();
)FLOE_JS"];
}
// FLOE_READONLY_SCRIPT_END

// FLOE_FULLSCREEN_EDIT_SCRIPT_BEGIN
static NSString *FloeFullScreenEditScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    const install = () => {
        const proto = window.L && window.L.Map && window.L.Map.prototype;
        if (!proto || typeof proto.setPermission !== 'function' || proto.floeFullScreenEditInstalled) return;
        proto.floeFullScreenEditInstalled = true;
        const setPermission = proto.setPermission;
        proto.setPermission = function (permission) {
            const firstOpen = this._permission === undefined;
            const result = setPermission.apply(this, arguments);
            // Floe's fullscreen entry is already an explicit edit action. Honor
            // the initial engine grant via the normal mobile entry point, which
            // retains format/password/lock checks. The mobile app forces
            // startreadonly=true for its viewing-first startup, so
            // _shouldStartReadOnly() describes the initial UI mode, not a denied
            // document; the backing permission (app.file.readOnly) is
            // authoritative. Never relax a readonly/view grant, the PDF
            // full-view mode, a non-native context or a later permission change.
            const backendEditable = window.app && window.app.file && window.app.file.readOnly === false;
            const startReadOnly = typeof this._shouldStartReadOnly === 'function' && this._shouldStartReadOnly();
            if (firstOpen && permission === 'edit' && this._permission === 'readonly' &&
                window.ThisIsAMobileApp && typeof this._switchToEditMode === 'function' &&
                !(window.app && window.app.file && window.app.file.fileBasedView) &&
                (backendEditable || !startReadOnly))
                this._switchToEditMode();
            return result;
        };
    };
    if (document.readyState === 'loading')
        document.addEventListener('DOMContentLoaded', install, { once: true });
    else install();
})();
)FLOE_JS"];
}
// FLOE_FULLSCREEN_EDIT_SCRIPT_END

// FLOE_ENGINE_PERMISSION_BEGIN
// Reads the engine's own backing permission and UI mode. app.file.readOnly is
// set from the handshake permission (main.js) and only lowered by a real edit
// grant; map.isEditMode()/_permission is the current mobile UI mode, which is
// "readonly" while an editable document is still in its viewing-first startup.
// A missing/unknown app.file.readOnly stays unknown (null → the ObjC caller
// keeps retrying) and is never read as an editable grant.
static NSString *FloeEnginePermissionProbeScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    try {
        const app = window.app;
        const map = app && app.map;
        if (!app || !app.file || !map) return null;
        if (typeof app.file.readOnly !== 'boolean') return null;
        return {
            backendReadOnly: app.file.readOnly,
            uiEdit: typeof map.isEditMode === 'function' && map.isEditMode() === true,
            pendingPassword: map._docHasPasswordToModify === true && map._modifyPasswordProvided !== true,
        };
    } catch (_) { return null; }
})()
)FLOE_JS"];
}

// Follows the engine's normal mobile edit entry. The engine itself challenges
// the edit password and refuses non-editable formats; this never bypasses a
// readonly backing permission.
static NSString *FloeEngineEditEntryScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    try {
        const app = window.app;
        const map = app && app.map;
        if (!app || !app.file || !map) return { ok: false, reason: 'not-ready' };
        if (app.file.readOnly === true) return { ok: false, reason: 'readonly' };
        if (typeof map.isEditMode === 'function' && map.isEditMode() === true)
            return { ok: true, reason: 'already-editable', backendReadOnly: false, uiEdit: true, pendingPassword: false };
        if (typeof map._switchToEditMode !== 'function') return { ok: false, reason: 'unsupported' };
        map._switchToEditMode();
        return {
            ok: true,
            reason: 'switched',
            backendReadOnly: app.file.readOnly === true,
            uiEdit: typeof map.isEditMode === 'function' && map.isEditMode() === true,
            pendingPassword: map._docHasPasswordToModify === true && map._modifyPasswordProvided !== true,
        };
    } catch (_) { return { ok: false, reason: 'error' }; }
})()
)FLOE_JS"];
}

// Keeps the host's engine-truth state current without polling. The editor owns
// app.setPermission; we only observe the resulting backing permission.
static NSString *FloeEnginePermissionObserverScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    let attempts = 0;
    const post = () => {
        try {
            const app = window.app;
            const handlers = window.webkit && window.webkit.messageHandlers;
            if (!app || !app.file || !handlers || !handlers.floePermission) return;
            // A missing/unknown app.file.readOnly is not an edit grant: wait
            // until the engine reports a real boolean instead of posting false.
            if (typeof app.file.readOnly !== 'boolean') return;
            handlers.floePermission.postMessage({ readOnly: app.file.readOnly });
        } catch (_) {}
    };
    const install = () => {
        const app = window.app;
        if (!app || typeof app.setPermission !== 'function' || app.floePermissionObserverInstalled) {
            if (attempts++ < 400) setTimeout(install, 50);
            return;
        }
        app.floePermissionObserverInstalled = true;
        const original = app.setPermission;
        app.setPermission = function (permission) {
            const result = original.apply(this, arguments);
            post();
            return result;
        };
        if (app.events && typeof app.events.on === 'function')
            app.events.on('updatepermission', post);
        post();
    };
    if (document.readyState === 'loading')
        document.addEventListener('DOMContentLoaded', install, { once: true });
    else install();
})()
)FLOE_JS"];
}
// FLOE_ENGINE_PERMISSION_END

@interface FloeOfficeEnginePermissionObserver : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) FloeOfficeNativeViewController *controller;
@end

typedef NS_ENUM(NSUInteger, FloeRuntimeState) {
    FloeRuntimeIdle, FloeRuntimeStarting, FloeRuntimeReady, FloeRuntimeFailed
};

@interface FloeOfficeNativeRuntime ()
@property FloeRuntimeState state;
@property NSMutableArray *waiters;
@property NSError *failure;
- (instancetype)initPrivate;
- (void)serverBecameReady;
- (void)fail:(NSError *)error;
@end

static void ServerReady() {
    dispatch_async(dispatch_get_main_queue(), ^{
        [FloeOfficeNativeRuntime.sharedRuntime serverBecameReady];
    });
}

@implementation FloeOfficeNativeRuntime
+ (FloeOfficeNativeRuntime *)sharedRuntime {
    static FloeOfficeNativeRuntime *runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ runtime = [[self alloc] initPrivate]; });
    return runtime;
}
- (instancetype)initPrivate {
    if ((self = [super init])) _waiters = [NSMutableArray array];
    return self;
}
- (BOOL)isReady {
    NSAssert(NSThread.isMainThread, @"Office runtime state is main-queue owned");
    return self.state == FloeRuntimeReady;
}
- (void)finishWaiters:(NSError *)error {
    NSArray *pending = [self.waiters copy];
    [self.waiters removeAllObjects];
    for (void (^completion)(NSError *) in pending) completion(error);
}
- (void)serverBecameReady {
    if (self.state != FloeRuntimeStarting) return;
    self.state = FloeRuntimeReady;
    [self finishWaiters:nil];
}
- (void)fail:(NSError *)error {
    NSAssert(NSThread.isMainThread, @"Office runtime state is main-queue owned");
    if (self.state == FloeRuntimeFailed) return;
    self.failure = error;
    self.state = FloeRuntimeFailed;
    [self finishWaiters:error];
    [NSNotificationCenter.defaultCenter postNotificationName:FloeOfficeNativeRuntimeDidFailNotification
                                                      object:self userInfo:@{NSUnderlyingErrorKey: error}];
}
- (void)prepareWithCompletion:(void (^)(NSError *))completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self prepareWithCompletion:completion]; });
        return;
    }
    if (self.state == FloeRuntimeReady) { completion(nil); return; }
    if (self.state == FloeRuntimeFailed) { completion(self.failure); return; }
    [self.waiters addObject:[completion copy]];
    if (self.state == FloeRuntimeStarting) return;
    self.state = FloeRuntimeStarting;
    // Preserve upstream engine initialization affinity; performance must be
    // measured on device before moving any UIKit-dependent startup off-main.
    dispatch_async(dispatch_get_main_queue(), ^{ [self startEngine]; });
}
- (void)startEngine {
    NSBundle *bundle = NSBundle.mainBundle;
    for (NSString *name in @[@"cool.html", @"rc", @"fundamentalrc", @"ICU.dat"]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[bundle.resourcePath stringByAppendingPathComponent:name]]) {
            [self fail:OfficeError(1, @"Office resources are missing from the application.")];
            return;
        }
    }
    NSError *error = nil;
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    if (!support) { [self fail:error]; return; }
    NSURL *root = [support URLByAppendingPathComponent:@"FloeAgent/OfficeRuntime" isDirectory:YES];
    // Separate versioned engine profile and cache, never the user's Documents
    // or the process temporary directory. Retain older profiles for recovery.
    // The profile identity also carries the staged font catalog fingerprint so
    // a font set change (app update, newly staged CJK families) starts from a
    // fresh font discovery instead of a stale cached catalog.
    NSString *fontFingerprint = FloeBundledFontCatalogFingerprint(bundle);
    NSString *profileIdentity = [NSString stringWithFormat:@"27b21dc1-fonts-%@", fontFingerprint];
    LOG_INF_NOFILE("FloeOffice font catalog fingerprint=" << fontFingerprint.UTF8String
                   << " profile=" << profileIdentity.UTF8String);
    NSURL *profile = [root URLByAppendingPathComponent:[profileIdentity stringByAppendingPathComponent:@"profile"] isDirectory:YES];
    NSURL *cache = [root URLByAppendingPathComponent:[profileIdentity stringByAppendingPathComponent:@"cache"] isDirectory:YES];
    for (NSURL *directory in @[profile, cache]) {
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self fail:error]; return;
        }
    }
    try {
        setupKitEnvironment(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? "notebookbar" : "");
        Log::initialize("FloeOffice", "warning");
        app_locale = FloeEditorLanguage(NSLocale.preferredLanguages);
        app_text_direction = LangUtil::isRtlLanguage(std::string(app_locale.UTF8String)) ? @"rtl" : @"";
        // The kit's null-path fallback uses the image containing lo_initialize.
        // In an embedded framework that is Frameworks/FloeOfficeNative.framework,
        // while the qualified rc, fundamentalrc, program and share live in the
        // application resource directory. Pass a filesystem path (not a URL);
        // the kit converts it to a correctly escaped file URL itself.
        // The kit's profile argument also applies a desktop-only ../ resource
        // root. Set the private profile directly without moving BRAND_BASE_DIR
        // away from the iOS main-bundle resources declared in fundamentalrc.
        rtl::Bootstrap::set(u"UserInstallation"_ustr,
                            OUString::fromUtf8(OString(profile.absoluteString.UTF8String)));
        lo_kit = cok_init_2(bundle.resourcePath.UTF8String, nullptr);
        if (!lo_kit) { [self fail:OfficeError(2, @"Office could not initialize its document engine.")]; return; }
        comphelper::COKit::setLanguageTag(LanguageTag(OUString::fromUtf8(OString(app_locale.UTF8String)), true));
        fakeSocketSetLoggingCallback([](const std::string& line) { LOG_INF_NOFILE(line); });
        floeOfficeServerReadyCallback = ServerReady;
        runKitLoopInAThread();
    } catch (const std::exception&) {
        [self fail:OfficeError(3, @"Office engine initialization failed.")]; return;
    } catch (...) {
        [self fail:OfficeError(3, @"Office engine initialization failed.")]; return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            try {
                ProcUtil::setThreadName("floe-office");
                std::string executable(bundle.executablePath.UTF8String);
                char *arguments[] = {executable.data(), nullptr};
                // Keep native server lifetime process-wide. Upstream shutdown
                // destructors are not qualified for restarting inside another app.
                auto server = new COOLWSD();
                // Mobile defineOptions deliberately registers no CLI options.
                // Configure this owned cache directly instead of passing the
                // desktop --override switch, which aborts mobile startup.
                server->config().setString("cache_files.path", cache.path.UTF8String);
                server->run(1, arguments);
            } catch (...) {
                // No abort/_Exit and no document cleanup on backend failure.
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self fail:OfficeError(4, @"Office stopped responding. Your document copies have been retained.")];
            });
        }
    });
}
@end

@interface FloeOfficeDocument : CODocument
@property (copy) void (^onOpened)(BOOL);
@end
@implementation FloeOfficeDocument
- (void)openWithCompletionHandler:(void (^)(BOOL))completion {
    [super openWithCompletionHandler:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success);
            if (self.onOpened) self.onOpened(success);
        });
    }];
}
@end

// FLOE_SAVE_RECEIPTS_BEGIN: compiled independently by the receipt-order harness.
@interface FloeSaveReceiptJoiner : NSObject
@property (nonatomic, copy) NSString *activeRequestID;
@property (nonatomic) NSTimeInterval timeout;
@property (nonatomic, copy) void (^completion)(BOOL);
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *requests;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *results;
- (BOOL)begin:(NSString *)requestID completion:(void (^)(BOOL))completion;
- (void)associate:(NSString *)sequence requestID:(NSString *)requestID;
- (void)complete:(NSString *)sequence success:(BOOL)success;
- (void)reject:(NSString *)requestID;
- (void)cancel;
@end
@implementation FloeSaveReceiptJoiner
- (instancetype)init {
    if ((self = [super init])) {
        _timeout = 90;
        _requests = [NSMutableDictionary dictionary];
        _results = [NSMutableDictionary dictionary];
    }
    return self;
}
- (BOOL)begin:(NSString *)requestID completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Save receipts are main-queue owned");
    if (self.activeRequestID || !requestID.length) return NO;
    self.activeRequestID = requestID;
    self.completion = completion;
    __weak FloeSaveReceiptJoiner *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.timeout * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [weakSelf reject:requestID]; });
    return YES;
}
- (void)finish:(BOOL)success {
    void (^completion)(BOOL) = self.completion;
    self.completion = nil;
    self.activeRequestID = nil;
    if (completion) completion(success);
}
- (void)join:(NSString *)sequence {
    NSString *request = self.requests[sequence];
    NSNumber *result = self.results[sequence];
    if (request != nil && result != nil) {
        [self.requests removeObjectForKey:sequence];
        [self.results removeObjectForKey:sequence];
        if ([request isEqualToString:self.activeRequestID]) [self finish:result.boolValue];
    }
    if (self.requests.count + self.results.count > 64) {
        // Missing protocol halves must fail an active request, never complete
        // it with a later result. Keep file recovery separate from this cache.
        [self.requests removeAllObjects];
        [self.results removeAllObjects];
        [self finish:NO];
    }
}
- (void)associate:(NSString *)sequence requestID:(NSString *)requestID {
    NSAssert(NSThread.isMainThread, @"Save receipts are main-queue owned");
    if (!sequence.length) return;
    NSString *previous = self.requests[sequence];
    if (previous && ![previous isEqualToString:requestID ?: @""]) {
        [self.requests removeObjectForKey:sequence];
        [self.results removeObjectForKey:sequence];
        [self finish:NO];
        return;
    }
    self.requests[sequence] = requestID ?: @"";
    [self join:sequence];
}
- (void)complete:(NSString *)sequence success:(BOOL)success {
    NSAssert(NSThread.isMainThread, @"Save receipts are main-queue owned");
    if (!sequence.length) return;
    NSNumber *previous = self.results[sequence];
    if (previous && previous.boolValue != success) {
        [self.requests removeObjectForKey:sequence];
        [self.results removeObjectForKey:sequence];
        [self finish:NO];
        return;
    }
    self.results[sequence] = @(success);
    [self join:sequence];
}
- (void)reject:(NSString *)requestID {
    NSAssert(NSThread.isMainThread, @"Save receipts are main-queue owned");
    if ([requestID isEqualToString:self.activeRequestID]) [self finish:NO];
}
- (void)cancel {
    NSAssert(NSThread.isMainThread, @"Save receipts are main-queue owned");
    [self finish:NO];
}
@end
// FLOE_SAVE_RECEIPTS_END

@interface FloeOfficeNativeViewController ()
@property (nonatomic, readwrite, getter=isReadOnly) BOOL readOnly;
@property (nonatomic, readwrite) BOOL sessionIsReadOnly;
@property (nonatomic, copy, readwrite) NSURL *workingFileURL;
@property DocumentViewController *editor;
@property (nonatomic, strong) FloeSaveReceiptJoiner *saveReceipts;
@property (nonatomic, strong) FloeOfficeEnginePermissionObserver *permissionObserver;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL closed;
@property (nonatomic) BOOL insertingAttachment;
/// Annotation mode is on: only Apple Pencil pointer events may start a stroke,
/// finger input stays navigation. Mirrored into the gating script.
@property (nonatomic) BOOL drawingModeEnabled;
/// The host's view was mounted, so its document open was (or is being)
/// requested. `loadViewIfNeeded` alone never sets this: a controller that was
/// created and discarded before mounting has no kit client that could ever
/// acknowledge a close.
@property (nonatomic) BOOL openRequested;
/// A close arrived while the document open was still in flight. A `bye`
/// issued before the open settles is dropped upstream and its ack never
/// arrives (the observed close timeout), and the half-open document would
/// stay alive in the engine with nobody left to close it. The close is
/// therefore ordered behind the open and runs the moment it settles.
@property (nonatomic) BOOL closeRequested;
/// The UIDocument open completed (success or failure).
@property (nonatomic) BOOL openSettled;
/// The UIDocument open completed successfully; a live engine session exists.
@property (nonatomic) BOOL documentOpened;
@property (nonatomic, strong) NSMutableArray *closeWaiters;
- (void)enginePermissionDidUpdate:(BOOL)readOnly;
- (void)probeEnginePermissionWithAttempts:(NSUInteger)attempts
                               completion:(void (^)(BOOL known, BOOL readOnly))completion;
- (void)attemptEngineEditEntryWithCompletion:(void (^)(BOOL readOnly, BOOL pendingPassword))completion;
@end

@implementation FloeOfficeEnginePermissionObserver
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSNumber *readOnly = nil;
    if ([message.body isKindOfClass:NSDictionary.class])
        readOnly = ((NSDictionary *)message.body)[@"readOnly"];
    else if ([message.body isKindOfClass:NSNumber.class])
        readOnly = message.body;
    if (![readOnly isKindOfClass:NSNumber.class]) return;
    [self.controller enginePermissionDidUpdate:readOnly.boolValue];
}
@end

@implementation FloeOfficeNativeViewController
- (instancetype)initWithWorkingFileURL:(NSURL *)workingFileURL sessionDirectory:(NSURL *)sessionDirectory
                             readOnly:(BOOL)readOnly error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Office controllers are main-queue owned");
    if (!FloeOfficeNativeRuntime.sharedRuntime.ready) {
        if (error) *error = OfficeError(5, @"Office is not ready to open a document.");
        return nil;
    }
    NSURL *file = workingFileURL.URLByStandardizingPath.URLByResolvingSymlinksInPath;
    NSURL *directory = sessionDirectory.URLByStandardizingPath.URLByResolvingSymlinksInPath;
    NSString *prefix = [directory.path stringByAppendingString:@"/"];
    BOOL isDirectory = NO;
    if (!workingFileURL.isFileURL || !sessionDirectory.isFileURL || ![file.path hasPrefix:prefix]
        || ![NSFileManager.defaultManager fileExistsAtPath:file.path isDirectory:&isDirectory] || isDirectory) {
        if (error) *error = OfficeError(6, @"Office requires a private document session copy.");
        return nil;
    }
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _readOnly = readOnly;
        // The App's requested grant until the engine reports its own permission.
        _sessionIsReadOnly = readOnly;
        _workingFileURL = file;
        _saveReceipts = [FloeSaveReceiptJoiner new];
        _closeWaiters = [NSMutableArray array];
        _editor = [[DocumentViewController alloc] initWithNibName:nil bundle:nil];
        FloeOfficeDocument *document = [[FloeOfficeDocument alloc] initWithFileURL:file];
        document->readOnly = readOnly;
        document.floeEngineCopyDirectory = [directory URLByAppendingPathComponent:@"engine" isDirectory:YES];
        document.viewController = _editor;
        _editor.document = document;
        __weak FloeOfficeNativeViewController *weakSelf = self;
        document.onOpened = ^(BOOL success) {
            FloeOfficeNativeViewController *host = weakSelf;
            if (!host) return;
            host.openSettled = YES;
            host.documentOpened = success;
            if (host.onWorkingCopyOpened) host.onWorkingCopyOpened(success);
            if (!success) {
                host.sessionIsReadOnly = YES;
                if (host.onWorkingCopyOpenedWithPermission) host.onWorkingCopyOpenedWithPermission(NO, YES);
                [host beginCloseIfRequested];
                return;
            }
            if (host.readOnly) {
                // A preview is forced readonly by the mount grant and the lock
                // script, so the engine's backing permission cannot change the
                // session. Probing it only delayed readiness (seconds on a cold
                // engine, worse on compact layouts) and was the visible "open
                // spinner" on iPhone. Report immediately; the permission
                // observer still streams later engine state for diagnostics.
                host.sessionIsReadOnly = YES;
                if (host.onWorkingCopyOpenedWithPermission) host.onWorkingCopyOpenedWithPermission(YES, YES);
                [host beginCloseIfRequested];
                return;
            }
            [host probeEnginePermissionWithAttempts:0 completion:^(BOOL known, BOOL readOnly) {
                FloeOfficeNativeViewController *probed = weakSelf;
                if (!probed || probed.closed || probed.closing) return;
                // A permission that never reported a boolean is unknown, not
                // an edit grant: keep the conservative read-only state. The
                // permission observer corrects it once the engine reports.
                probed.sessionIsReadOnly = known ? readOnly : YES;
                // An editable backing document that the mobile editor mounted in
                // its viewing-first UI is not a denied document: follow the
                // engine's own guarded entry once, then report the real state.
                if (known && !readOnly && !probed.readOnly) {
                    [probed attemptEngineEditEntryWithCompletion:^(BOOL stillReadOnly, BOOL pendingPassword) {
                        FloeOfficeNativeViewController *entered = weakSelf;
                        if (!entered || entered.closed || entered.closing) return;
                        entered.sessionIsReadOnly = stillReadOnly;
                        if (entered.onWorkingCopyOpenedWithPermission)
                            entered.onWorkingCopyOpenedWithPermission(YES, stillReadOnly);
                        [entered beginCloseIfRequested];
                    }];
                    return;
                }
                if (probed.onWorkingCopyOpenedWithPermission)
                    probed.onWorkingCopyOpenedWithPermission(YES, probed.sessionIsReadOnly);
                [probed beginCloseIfRequested];
            }];
        };
        document.floeSaveCompletion = ^(BOOL success) {
            FloeOfficeNativeViewController *host = weakSelf;
            if (host.onWorkingCopySaved) host.onWorkingCopySaved(success);
        };
        document.floeSaveSequenceCompletion = ^(NSString *sequence, BOOL success) {
            [weakSelf.saveReceipts complete:sequence success:success];
        };
        document.floeSaveSequenceAssociation = ^(NSString *sequence, NSString *requestID) {
            [weakSelf.saveReceipts associate:sequence requestID:requestID];
        };
        document.floeSaveRequestRejected = ^(NSString *requestID) {
            [weakSelf.saveReceipts reject:requestID];
        };
        _editor.floeCloseCompletion = ^(BOOL success) {
            FloeOfficeNativeViewController *host = weakSelf;
            [host.saveReceipts cancel];
            host.closing = NO;
            host.closed = success;
            if (!success) host.editor.view.userInteractionEnabled = YES;
            [host settleCloseWaitersWithError:success ? nil : OfficeError(10, @"Office could not close this document. Your document copies have been retained.")];
            if (host.onClosed) host.onClosed(success);
        };
    }
    return self;
}
- (void)saveWorkingCopyWithCompletion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Office saves are main-queue owned");
    if (self.readOnly || self.closing || self.closed || self.insertingAttachment || !self.editor.webView || self.editor.document->fakeClientFd < 0) {
        completion(OfficeError(7, @"Open the document for editing before saving."));
        return;
    }
    NSString *requestID = [@"floe-save:" stringByAppendingString:NSUUID.UUID.UUIDString];
    if (![self.saveReceipts begin:requestID completion:^(BOOL success) {
        completion(success ? nil : OfficeError(8, @"Office could not complete this save. Your document copies have been retained."));
    }]) {
        completion(OfficeError(9, @"An Office save is already in progress."));
        return;
    }
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:@[requestID] options:0 error:nil];
    NSString *argument = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"(() => { const map = window.app && window.app.map; if (!map || typeof map.save !== 'function' || !window.app.socket || !window.app.socket.connected()) return false; map.save(false, false, (%@)[0]); return true; })()", argument];
    __weak FloeOfficeNativeViewController *weakSelf = self;
    [self.editor.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        if (error || ![value isKindOfClass:NSNumber.class] || ![value boolValue])
            [weakSelf.saveReceipts reject:requestID];
    }];
}
- (void)exportDocumentWithFormat:(NSString *)format completion:(void (^)(NSURL *, NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Office exports are main-queue owned");
    if (self.closing || self.closed || self.insertingAttachment || self.saveReceipts.activeRequestID ||
        !self.editor.webView || self.editor.document->fakeClientFd < 0 ||
        ![@[@"pdf", @"docx", @"odt", @"rtf", @"txt", @"pptx", @"odp", @"xlsx", @"ods"] containsObject:format]) {
        completion(nil, OfficeError(30, @"Finish the current operation before exporting.")); return;
    }
    // Reuse the exclusive engine-operation guard: close and save cannot race this worker.
    self.insertingAttachment = YES;
    self.editor.view.userInteractionEnabled = NO;
    const unsigned documentID = self.editor.document->appDocId;
    NSURL *folder = [[[self.workingFileURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"exports" isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSString *name = [[self.workingFileURL.lastPathComponent stringByDeletingPathExtension] stringByAppendingPathExtension:format];
    NSURL *output = [folder URLByAppendingPathComponent:name];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *failure = nil;
            if ([NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&failure]) {
                try {
                    FloeExportDocument([documentID]() -> COKitDocument * {
                        DocumentData *data = DocumentData::getIfExists(documentID);
                        return data ? data->loKitDocument : nullptr;
                    }, output.absoluteString.UTF8String, format.UTF8String);
                    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:output.path error:&failure];
                    if (!failure && (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] == 0))
                        failure = OfficeError(31, @"The exported file is empty or unavailable.");
                } catch (...) { failure = OfficeError(32, @"Office could not convert this document to the selected format."); }
            }
            if (failure) [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.insertingAttachment = NO;
                if (!self.closed && !self.closing) self.editor.view.userInteractionEnabled = YES;
                completion(failure ? nil : output, failure);
            });
        }
    });
}
- (void)startPresentationWithCompletion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Office presentation is main-queue owned");
    if (self.closing || self.closed || self.insertingAttachment || !self.editor.webView ||
        ![@[@"ppt", @"pptx", @"odp"] containsObject:self.workingFileURL.pathExtension.lowercaseString]) {
        completion(OfficeError(33, @"An open presentation is required.")); return;
    }
    NSString *script = @"(() => { const app = window.app; if (!app || !app.map || app.map.getDocType() !== 'presentation' || !app.socket.connected()) return false; app.map.fire(window.canvasSlideshowEnabled ? 'newfullscreen' : 'fullscreen'); return true; })()";
    [self.editor.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        completion(error ?: ([value isKindOfClass:NSNumber.class] && [value boolValue] ? nil : OfficeError(34, @"The presentation is not ready.")));
    }];
}
- (void)setDrawingMode:(NSNumber *)enabled completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Office drawing is main-queue owned");
    if (self.readOnly || self.closing || self.closed || self.insertingAttachment || !self.editor.webView) {
        completion(OfficeError(35, @"Open the document for editing before annotating.")); return;
    }
    NSString *command = enabled.boolValue ? @".uno:Freeline_Unfilled" : @".uno:SelectObject";
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:@[command] options:0 error:nil];
    NSString *argument = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    // Pencil-only input: the gating script is armed with the same switch, so
    // a finger keeps navigating while annotation mode is on.
    NSString *script = [NSString stringWithFormat:@"(() => { const map = window.app && window.app.map; if (!map || !map.isEditMode() || typeof map.sendUnoCommand !== 'function') return false; map.sendUnoCommand((%@)[0]); window.__floePencilOnly = %@; return true; })()", argument, enabled.boolValue ? @"true" : @"false"];
    __weak FloeOfficeNativeViewController *weakSelf = self;
    [self.editor.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        if (!error && [value isKindOfClass:NSNumber.class] && [value boolValue]) weakSelf.drawingModeEnabled = enabled.boolValue;
        completion(error ?: ([value isKindOfClass:NSNumber.class] && [value boolValue] ? nil : OfficeError(36, @"The drawing tool is not ready.")));
    }];
}
- (void)cancelPendingSave {
    [self.saveReceipts cancel];
}
- (void)enginePermissionDidUpdate:(BOOL)readOnly {
    NSAssert(NSThread.isMainThread, @"Office permission state is main-queue owned");
    if (self.closing || self.closed || self.sessionIsReadOnly == readOnly) return;
    self.sessionIsReadOnly = readOnly;
    if (self.onEnginePermissionChanged) self.onEnginePermissionChanged(readOnly);
}
// Retries only until the editor has created its map. app.file.readOnly is the
// backing permission; _permission/isReadOnlyMode() alone is the mobile UI mode.
- (void)probeEnginePermissionWithAttempts:(NSUInteger)attempts
                               completion:(void (^)(BOOL known, BOOL readOnly))completion {
    NSAssert(NSThread.isMainThread, @"Office permission probes are main-queue owned");
    if (self.closing || self.closed || !self.editor.webView) {
        completion(NO, self.sessionIsReadOnly);
        return;
    }
    __weak FloeOfficeNativeViewController *weakSelf = self;
    [self.editor.webView evaluateJavaScript:FloeEnginePermissionProbeScript()
                          completionHandler:^(id value, NSError *error) {
        FloeOfficeNativeViewController *host = weakSelf;
        if (!host) return;
        NSDictionary *result = [value isKindOfClass:NSDictionary.class] ? value : nil;
        NSNumber *backendReadOnly = [result[@"backendReadOnly"] isKindOfClass:NSNumber.class]
            ? result[@"backendReadOnly"] : nil;
        if (backendReadOnly) {
            completion(YES, backendReadOnly.boolValue);
            return;
        }
        if (attempts >= 40 || error) {
            completion(NO, host.sessionIsReadOnly);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [host probeEnginePermissionWithAttempts:attempts + 1 completion:completion];
        });
    }];
}
- (void)attemptEngineEditEntryWithCompletion:(void (^)(BOOL readOnly, BOOL pendingPassword))completion {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    if (self.closing || self.closed || !self.editor.webView) {
        completion(YES, NO);
        return;
    }
    __weak FloeOfficeNativeViewController *weakSelf = self;
    [self.editor.webView evaluateJavaScript:FloeEngineEditEntryScript()
                          completionHandler:^(id value, NSError *error) {
        FloeOfficeNativeViewController *host = weakSelf;
        if (!host) return;
        NSDictionary *result = [value isKindOfClass:NSDictionary.class] ? value : nil;
        if (!result) {
            completion(YES, NO);
            return;
        }
        BOOL backendReadOnly = [result[@"backendReadOnly"] isKindOfClass:NSNumber.class]
            ? [result[@"backendReadOnly"] boolValue] : YES;
        BOOL uiEdit = [result[@"uiEdit"] isKindOfClass:NSNumber.class] && [result[@"uiEdit"] boolValue];
        BOOL pendingPassword = [result[@"pendingPassword"] isKindOfClass:NSNumber.class]
            && [result[@"pendingPassword"] boolValue];
        completion(backendReadOnly || !uiEdit, pendingPassword);
    }];
}
- (void)enterEditModeWithCompletion:(void (^)(BOOL readOnly, NSError *error))completion {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    if (self.closing || self.closed || !self.editor.webView) {
        completion(YES, OfficeError(40, @"Office is not ready to change the edit mode."));
        return;
    }
    if (self.readOnly) {
        // The App mounted this controller as read-only. That grant is never
        // relaxed here; a caller that wants editing opens an editable session.
        completion(YES, OfficeError(41, @"This session was opened as read-only. Reopen it for editing."));
        return;
    }
    __weak FloeOfficeNativeViewController *weakSelf = self;
    [self attemptEngineEditEntryWithCompletion:^(BOOL readOnly, BOOL pendingPassword) {
        FloeOfficeNativeViewController *host = weakSelf;
        if (!host) return;
        host.sessionIsReadOnly = readOnly;
        NSError *error = nil;
        if (readOnly && pendingPassword)
            error = OfficeError(42, @"The document requires its edit password. Enter it in the editor.");
        completion(readOnly, error);
    }];
}
- (void)insertAttachmentFromFileURL:(NSURL *)fileURL completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Office attachment requests are main-queue owned");
    if (self.readOnly || self.closing || self.closed || self.insertingAttachment || self.saveReceipts.activeRequestID ||
        !self.editor.webView || !fileURL.isFileURL) {
        completion(OfficeError(12, @"Open the document for editing and finish the current operation first."));
        return;
    }
    if (![@[@"docx", @"doc", @"odt", @"rtf", @"xlsx", @"xls", @"ods", @"pptx", @"ppt", @"odp"] containsObject:self.workingFileURL.pathExtension.lowercaseString]) {
        completion(OfficeError(13, @"Attachment insertion for this document type is not available yet."));
        return;
    }
    self.insertingAttachment = YES;
    self.editor.view.userInteractionEnabled = NO;
    NSString *name = fileURL.lastPathComponent;
    NSURL *folder = [[[self.workingFileURL URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:@"attachments" isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    // Keep user filenames separate from generated package and preview names.
    NSURL *sourceFolder = [folder URLByAppendingPathComponent:@"source" isDirectory:YES];
    NSURL *copy = [sourceFolder URLByAppendingPathComponent:name];
    NSURL *package = [folder URLByAppendingPathComponent:@"embedded-object.bin"];
    NSURL *icon = [folder URLByAppendingPathComponent:@"attachment-preview.png"];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(300, 90)];
    NSData *iconData = UIImagePNGRepresentation([renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.whiteColor setFill]; UIRectFill(CGRectMake(0, 0, 300, 90));
        UIImage *symbol = [[UIImage systemImageNamed:@"doc.fill"] imageWithTintColor:UIColor.systemBlueColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        [symbol drawInRect:CGRectMake(10, 20, 40, 48)];
        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new]; style.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [name drawInRect:CGRectMake(60, 31, 230, 45) withAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:16], NSForegroundColorAttributeName: UIColor.blackColor,
            NSParagraphStyleAttributeName: style}];
    }]);
    const unsigned documentID = self.editor.document->appDocId;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *failure = nil;
            BOOL scoped = [fileURL startAccessingSecurityScopedResource];
            if (![NSFileManager.defaultManager createDirectoryAtURL:sourceFolder withIntermediateDirectories:YES attributes:nil error:&failure]) {
                // Report below, without touching the original document.
            } else {
                NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
                __block NSError *copyFailure = nil;
                NSError *coordinationFailure = nil;
                [coordinator coordinateReadingItemAtURL:fileURL options:0 error:&coordinationFailure byAccessor:^(NSURL *source) {
                    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:source.path error:&copyFailure];
                    if (!attributes) return;
                    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
                        copyFailure = OfficeError(14, @"Choose a regular file to attach."); return;
                    }
                    [NSFileManager.defaultManager copyItemAtURL:source toURL:copy error:&copyFailure];
                }];
                failure = coordinationFailure ?: copyFailure;
            }
            if (scoped) [fileURL stopAccessingSecurityScopedResource];
            if (!failure && ![iconData writeToURL:icon options:NSDataWritingAtomic error:&failure]) {
                if (!failure) failure = OfficeError(15, @"The attachment preview could not be created.");
            }
            if (!failure) {
                try {
                    FloeImportAttachment([documentID]() -> COKitDocument * {
                        DocumentData *data = DocumentData::getIfExists(documentID);
                        return data ? data->loKitDocument : nullptr;
                    }, copy.absoluteString.UTF8String, package.absoluteString.UTF8String,
                       icon.absoluteString.UTF8String, name.UTF8String, folder.lastPathComponent.UTF8String);
                } catch (...) {
                    failure = OfficeError(16, @"The attachment could not be inserted. Its copied file has been retained for recovery.");
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.insertingAttachment = NO;
                if (!self.closed && !self.closing) self.editor.view.userInteractionEnabled = YES;
                completion(failure);
            });
        }
    });
}
- (void)closeWorkingCopyWithCompletion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Office closes are main-queue owned");
    if (self.insertingAttachment) { completion(OfficeError(11, @"Finish inserting the attachment before closing.")); return; }
    if (self.closed) { completion(nil); return; }
    if (completion) [self.closeWaiters addObject:[completion copy]];
    if (self.openRequested && !self.openSettled) {
        // Order the close behind the in-flight open; it begins the moment
        // the open settles (see `closeRequested`).
        self.closeRequested = YES;
        return;
    }
    [self beginClose];
}
- (void)beginClose {
    if (self.closed || self.closing) return;
    // No live engine session can ever acknowledge this close when the host's
    // view was never mounted (created and discarded before appearing — the
    // preview-to-edit switch on a fast tap) or when its open already failed.
    // Waiting for a bye ack there only stalls the caller for seconds and
    // surfaces as the "closing" spinner; settle immediately instead. Nothing
    // was written back or deleted; the private copies stay on disk.
    BOOL neverOpened = !self.openRequested || !self.documentOpened;
    if (neverOpened) {
        [self.saveReceipts cancel];
        self.closed = YES;
        if (self.editor.webView)
            [self.editor.webView.configuration.userContentController removeScriptMessageHandlerForName:@"floePermission"];
        [self settleCloseWaitersWithError:nil];
        if (self.onClosed) self.onClosed(YES);
        return;
    }
    self.closing = YES;
    [self.saveReceipts cancel];
    self.editor.view.userInteractionEnabled = NO;
    if (self.editor.webView)
        [self.editor.webView.configuration.userContentController removeScriptMessageHandlerForName:@"floePermission"];
    [self.editor bye];
}
- (void)settleCloseWaitersWithError:(NSError *)error {
    NSArray *waiters = [self.closeWaiters copy];
    [self.closeWaiters removeAllObjects];
    for (void (^completion)(NSError *) in waiters)
        completion(error);
}
/// Runs a close that was queued while the document open was still in flight
/// (see `closeRequested`). Called on every open-settle path, after the open
/// report reached the App, so the session UI settles before the close.
- (void)beginCloseIfRequested {
    if (!self.closeRequested) return;
    self.closeRequested = NO;
    [self beginClose];
}
- (void)listAttachmentsWithCompletion:(void (^)(NSArray<FloeOfficeAttachmentInfo *> *, NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Office attachment requests are main-queue owned");
    if (self.closing || self.closed || self.insertingAttachment || self.saveReceipts.activeRequestID || !self.editor.webView) {
        completion(nil, OfficeError(17, @"Finish the current document operation first.")); return;
    }
    self.insertingAttachment = YES;
    self.editor.view.userInteractionEnabled = NO;
    const unsigned documentID = self.editor.document->appDocId;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *failure = nil;
            NSMutableArray<FloeOfficeAttachmentInfo *> *items = [NSMutableArray array];
            try {
                auto attachments = FloeListAttachments([documentID]() -> COKitDocument * {
                    auto data = DocumentData::getIfExists(documentID);
                    return data ? data->loKitDocument : nullptr;
                });
                for (const auto &attachment : attachments) {
                    FloeOfficeAttachmentInfo *item = [FloeOfficeAttachmentInfo new];
                    item.identifier = [NSString stringWithUTF8String:attachment.identifier.c_str()];
                    item.name = [NSString stringWithUTF8String:attachment.name.c_str()] ?: @"Attachment";
                    item.byteCount = attachment.byteCount;
                    [items addObject:item];
                }
            } catch (const std::exception &error) {
                failure = OfficeAttachmentReadError(18, @"The document attachments could not be read.", error);
            } catch (...) { failure = OfficeError(18, @"The document attachments could not be read."); }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.insertingAttachment = NO;
                if (!self.closed && !self.closing) self.editor.view.userInteractionEnabled = YES;
                completion(failure ? nil : [items copy], failure);
            });
        }
    });
}
- (void)exportAttachmentWithIdentifier:(NSString *)identifier completion:(void (^)(NSURL *, NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Office attachment requests are main-queue owned");
    if (self.closing || self.closed || self.insertingAttachment || self.saveReceipts.activeRequestID || !self.editor.webView) {
        completion(nil, OfficeError(17, @"Finish the current document operation first.")); return;
    }
    self.insertingAttachment = YES;
    self.editor.view.userInteractionEnabled = NO;
    const unsigned documentID = self.editor.document->appDocId;
    NSURL *folder = [[[self.workingFileURL URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:@"attachment-exports" isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *failure = nil;
            NSURL *file = nil;
            try {
                auto lookup = [documentID]() -> COKitDocument * {
                    auto data = DocumentData::getIfExists(documentID);
                    return data ? data->loKitDocument : nullptr;
                };
                const auto attachments = FloeListAttachments(lookup);
                for (const auto &attachment : attachments) {
                    if (attachment.identifier != identifier.UTF8String) continue;
                    NSString *name = [NSString stringWithUTF8String:attachment.name.c_str()] ?: @"Attachment";
                    // Embedded names may contain original Windows paths. Never
                    // allow them to escape this private export directory.
                    name = [[name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
                    if (!name.length || [@[@".", @"..", @"/"] containsObject:name]) name = @"Attachment";
                    file = [folder URLByAppendingPathComponent:name];
                    break;
                }
                if (!file) failure = OfficeError(19, @"This attachment is no longer present. Refresh the list.");
                else if ([NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&failure]) {
                    FloeExportAttachment(lookup, identifier.UTF8String, file.absoluteString.UTF8String);
                }
            } catch (const std::exception &error) {
                failure = OfficeAttachmentReadError(20, @"The attachment could not be exported. The document has not been changed.", error);
            } catch (...) { failure = OfficeError(20, @"The attachment could not be exported. The document has not been changed."); }
            if (failure) [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.insertingAttachment = NO;
                if (!self.closed && !self.closing) self.editor.view.userInteractionEnabled = YES;
                completion(failure ? nil : file, failure);
            });
        }
    });
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The upstream editor opens its document from its own viewWillAppear, so
    // reaching this point means a kit session is (or will be) live and every
    // later close must go through the engine's acknowledgement path.
    self.openRequested = YES;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self addChildViewController:self.editor];
    UIView *content = self.editor.view;
    // Add before viewWillAppear opens the document. At document start the
    // listener precedes the bundled editor's DOMContentLoaded callbacks.
    WKUserContentController *contentController = self.editor.webView.configuration.userContentController;
    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:self.readOnly ? FloeReadOnlyScript() : FloeFullScreenEditScript()
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [contentController addUserScript:script];
    FloeOfficeEnginePermissionObserver *observer = [FloeOfficeEnginePermissionObserver new];
    observer.controller = self;
    self.permissionObserver = observer;
    [contentController addScriptMessageHandler:observer name:@"floePermission"];
    [contentController addUserScript:[[WKUserScript alloc]
        initWithSource:FloeEnginePermissionObserverScript()
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    WKUserScript *drainScript = [[WKUserScript alloc] initWithSource:FloeNativeDrainScript()
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [self.editor.webView.configuration.userContentController addUserScript:drainScript];
    // An editable document may enter annotation mode; install the Pencil-only
    // input gate so finger input stays navigation there.
    if (!self.readOnly) {
        [contentController addUserScript:[[WKUserScript alloc]
            initWithSource:FloeInkInputGatingScript()
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    }
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.editor didMoveToParentViewController:self];
}
@end
