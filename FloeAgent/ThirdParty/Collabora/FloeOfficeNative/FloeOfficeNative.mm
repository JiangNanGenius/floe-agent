// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
// Runtime startup adapted from the pinned Collabora Mobile AppDelegate (MPL-2.0).
#import "config.h"
#import "FloeOfficeNative.h"
#import <WebKit/WebKit.h>
#import <CoreText/CoreText.h>
#include <os/proc.h>
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

// FLOE_OFFICE_LOG_BEGIN
// Bounded, content-free diagnostics. A report is a single line of engine state
// (format, document type, open/permission/JS-bridge state, render counters and
// save receipt identity) — never document text, paths or bytes. Logging is
// capped so a stuck session cannot flood the device console.
static void FloeOfficeLog(NSString *event, NSDictionary<NSString *, id> *facts) {
    static NSUInteger emitted = 0;
    if (emitted >= 256) return;
    emitted++;
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    for (NSString *key in [facts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id value = facts[key];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])
            [fields addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    NSLog(@"[FloeOffice] %@ %@", event, [fields componentsJoinedByString:@" "]);
}
// FLOE_OFFICE_LOG_END

// FLOE_OFFICE_STAGE_BEGIN
// Build 233 (R1/R3): content-free native breadcrumbs persisted by the App's
// OfficeStageRecorder, plus the web-content recovery hook.
//
// The host already logs bounded `[FloeOffice]` stages to the unified log, but
// a process killed inside the editable open window (the Build 232 PPT idle
// crash) never delivered them anywhere durable. `FloeOfficeStageEvent` is
// handed to the App's recorder under its own session/generation correlation,
// so a recurrence names the last native stage. Facts stay counters, enums and
// memory samples; never document text, paths or bytes.
static NSNotificationName const FloeOfficeWebContentTerminatedNotification = @"FloeOfficeWebContentTerminated";

/// Process memory headroom for one stage sample. `os_proc_available_memory`
/// returns the kernel's current allowance; a raw 0 is a real reading and is
/// recorded as such (Swift's optional bridging must never fold it to nil).
static NSDictionary<NSString *, id> *FloeOfficeMemoryFacts(void) {
    unsigned long long physical = NSProcessInfo.processInfo.physicalMemory;
    size_t available = os_proc_available_memory();
    return @{@"memAvailableMB": @(available / (1024ULL * 1024ULL)),
             @"memPhysicalMB": @(physical / (1024ULL * 1024ULL))};
}

/// The pinned upstream `DocumentViewController` owns the editor's
/// WKNavigationDelegate and *already implements* the optional termination
/// callback (`ios/Mobile/DocumentViewController.mm`, pinned 27b21dc1, original
/// SHA-256 7dab7a3c…): it calls `[self bye]`, which the embedding patch turns
/// into the coordinated document close that settles `floeCloseCompletion`.
/// An Objective-C category implementing the same selector would silently
/// replace that upstream implementation (category methods win over the
/// class's own method), so the recovery hook is a subclass: it calls the
/// upstream implementation through first and only then reports the death to
/// the host controller. The declaration-only category exists so the
/// call-through type-checks; it registers no runtime method. No delegate is
/// replaced or proxied and the working copy is never discarded here.
@interface DocumentViewController (FloeWebContentRecovery)
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView;
@end

@interface FloeOfficeDocumentViewController : DocumentViewController
@end

@implementation FloeOfficeDocumentViewController
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    // Pinned upstream teardown first: `[self bye]` closes the document,
    // dismisses the dead surface and settles the host's close completion.
    // The guard keeps a future upstream without the callback from arming an
    // unrecognized-selector crash in the delegate path.
    if ([DocumentViewController instancesRespondToSelector:_cmd])
        [super webViewWebContentProcessDidTerminate:webView];
    // Then report this editor's death to the host, which cancels the probe,
    // keeps every file and settles the bounded recoverable failure.
    [NSNotificationCenter.defaultCenter postNotificationName:FloeOfficeWebContentTerminatedNotification
                                                      object:self
                                                    userInfo:@{@"webView": webView ?: NSNull.null}];
}
@end
// FLOE_OFFICE_STAGE_END

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
// The embedded engine discovers fonts in two steps: its quartz backend scans
// `$BRAND_BASE_DIR/program/resource/common/fonts` and
// `$BRAND_BASE_DIR/share/fonts/truetype` and registers every file it finds
// there for the process (pinned `vcl/quartz/salgdi.cxx`
// `AddLocalTempFontDirs`), and then it caches the process's *available*
// CoreText font list (`GetCoretextFontList` →
// `CTFontCollectionCreateFromAvailableFonts`). The App additionally registers
// its staged families from `Bundled/` at launch. A stale profile cache from a
// build that predates the staged CJK families — or a registration that never
// took effect — makes every Chinese glyph render as a tofu box even though the
// font files exist.
//
// The profile identity therefore fingerprints every location a font change can
// come from, and for the App-staged families it records whether the process
// really resolves the font: descriptors that merely parse from a file are not
// discovery.
static bool FloeFontFileResolvesInProcess(NSURL *url) {
    NSArray *descriptors = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
    if (![descriptors isKindOfClass:NSArray.class]) return false;
    for (id descriptor in descriptors) {
        NSString *name = CFBridgingRelease(CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)descriptor,
                                                                         kCTFontNameAttribute));
        if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
        CTFontRef font = CTFontCreateWithNameAndOptions((__bridge CFStringRef)name, 12, NULL,
                                                        kCTFontOptionsPreventAutoActivation);
        if (!font) continue;
        NSString *actual = CFBridgingRelease(CTFontCopyPostScriptName(font));
        CFRelease(font);
        if ([actual caseInsensitiveCompare:name] == NSOrderedSame) return true;
    }
    return false;
}

static bool FloeFontFileExtension(NSURL *url) {
    static NSSet<NSString *> *extensions = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[@"ttf", @"otf", @"ttc", @"otc"]];
    });
    return [extensions containsObject:url.pathExtension.lowercaseString ?: @""];
}

static NSDictionary<NSString *, id> *gFloeFontDiscoveryFacts;

static NSString *FloeBundledFontCatalogFingerprint(NSBundle *bundle) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    // {relative root, verify real resolution}. The engine-scanned roots come
    // first: those are what AddLocalTempFontDirs registers before the CoreText
    // list is cached. The App-staged roots are verified by resolution so a
    // broken registration changes the identity instead of hiding behind an
    // unchanged file listing.
    NSArray<NSArray *> *roots = @[
        @[@"program/resource/common/fonts", @NO],
        @[@"share/fonts", @NO],
        @[@"Bundled", @YES],
        @[@"Fonts", @YES],
    ];
    NSUInteger stagedFonts = 0;
    NSUInteger resolvedFonts = 0;
    for (NSArray *root in roots) {
        NSString *relative = root[0];
        BOOL verifyResolution = [root[1] boolValue];
        NSURL *resourceRoot = [NSURL fileURLWithPath:bundle.resourcePath isDirectory:YES];
        NSURL *directory = [resourceRoot URLByAppendingPathComponent:relative isDirectory:YES];
        NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager enumeratorAtURL:directory
                                                      includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                    errorHandler:nil];
        for (NSURL *url in enumerator) {
            NSNumber *size = nil;
            [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            if (!verifyResolution) {
                [entries addObject:[NSString stringWithFormat:@"%@:%@:%@", relative, url.lastPathComponent, size ?: @0]];
                continue;
            }
            // App-staged roots carry licenses and readmes next to the fonts;
            // only font files are part of the discovery verification.
            if (!FloeFontFileExtension(url)) continue;
            stagedFonts++;
            BOOL resolved = FloeFontFileResolvesInProcess(url);
            if (resolved) resolvedFonts++;
            [entries addObject:[NSString stringWithFormat:@"%@:%@:%@:%@", relative, url.lastPathComponent,
                                                         size ?: @0, resolved ? @"registered" : @"unresolved"]];
        }
    }
    LOG_INF_NOFILE("FloeOffice font discovery staged=" << stagedFonts << " resolved=" << resolvedFonts);
    NSString *fingerprint = nil;
    if (entries.count == 0) {
        fingerprint = @"no-fonts";
    } else {
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
        fingerprint = [NSString stringWithFormat:@"%llu-%08llx",
                       (unsigned long long)entries.count, (unsigned long long)hash];
    }
    // The App's durable diagnostics record these counts; the profile identity
    // keeps the full fingerprint.
    gFloeFontDiscoveryFacts = @{@"staged": @(stagedFonts), @"resolved": @(resolvedFonts),
                                @"catalogFingerprint": fingerprint ?: @"unavailable"};
    return fingerprint;
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

// FLOE_RENDER_READINESS_BEGIN
// A document surface is "visible-rendered" only when the engine reports its
// document type, the editor has decoded at least one document tile into an
// image and the document canvas has a real size. `docloaded`, the UIDocument
// open, the backing permission and a save receipt are all deliberately absent
// from this decision: they can be true while nothing was ever painted. The
// pixel fingerprint is a coarse, downsampled paint check used for non-Impress
// formats and as a diagnostic; presentation decks must show decoded tiles
// because their file-based view paints page skeletons before any tile arrives.
// FLOE_RENDER_DECISION_BEGIN
// Compiled independently by office_render_readiness.py against synthetic facts.
typedef struct {
    bool docTypeKnown;
    bool docLoaded;
    bool canvasSized;
    bool tileDecoded;
    bool pixelPainted;
    bool vectorRendering;
    /// A paint that happened on the part-based edit surface after the edit
    /// entry: a tile decoded after the entry's baseline, or a repainted
    /// document canvas. The engine's shared tile map keeps the file-based
    /// startup's decoded tiles across `_switchToPartBasedView`, so the decoded
    /// tile count alone is never edit-surface evidence.
    bool editSurfacePainted;
} FloeRenderFacts;

static bool FloeRenderFactsSatisfyVisibleRender(FloeRenderFacts facts) {
    if (!facts.docTypeKnown || !facts.docLoaded || !facts.canvasSized) return false;
    if (facts.tileDecoded) return true;
    // Vector-rendered documents have no bitmap tiles; require a real paint.
    if (facts.vectorRendering && facts.pixelPainted) return true;
    return false;
}

// Formats whose renderer starts in the engine's file-based view (endless
// scrolling / slide sorter) where page skeletons are painted before any
// document tile arrives, so `docloaded` plus a non-empty canvas is not proof of
// a rendered document. Mirrored by OfficeRenderRequirement in
// FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift; a focused check
// asserts both lists stay identical.
static bool FloeDocumentRequiresVisibleRender(NSString *extension) {
    static NSSet<NSString *> *formats = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formats = [NSSet setWithArray:@[@"ppt", @"pptx", @"pptm", @"pps", @"ppsx", @"pot", @"potx",
                                        @"odp", @"otp", @"fodp", @"odg", @"otg", @"fodg"]];
    });
    return [formats containsObject:extension.lowercaseString ?: @""];
}
// FLOE_RENDER_DECISION_END

// FLOE_RENDER_PROGRESS_BEGIN
// Bounded, content-free render-probe progress breadcrumbs. Build 234's PPT
// device evidence ends at `edit-entry-deferred` with no later durable stage:
// the process died inside the engine's file-based Impress load, and the trace
// could not name how far the engine had come (page map only? layer loaded?
// canvas sized? tile decoded?) or how the headroom moved while it waited.
// Each newly observed readiness class is persisted through `floeStage:` (which
// stamps the App recorder and a memory sample), so the last breadcrumb before
// a kill attributes the open window. Diagnostics only: neither the mask nor
// the counters participate in any readiness decision.
typedef NS_OPTIONS(NSUInteger, FloeProbeProgressClass) {
    FloeProbeProgressPage        = 1 << 0, // window.app.map was observed
    FloeProbeProgressType        = 1 << 1, // engine reported a document type
    FloeProbeProgressLoaded      = 1 << 2, // document layer loaded
    FloeProbeProgressCanvas      = 1 << 3, // a sized document canvas exists
    FloeProbeProgressTile        = 1 << 4, // at least one decoded document tile
    FloeProbeProgressPaint       = 1 << 5, // canvas pixels read as painted
    FloeProbeProgressEditSurface = 1 << 6, // post-entry edit-surface paint
};

/// Upper bound on progress breadcrumbs per probe session. The open window is
/// bounded (25 s), so this only protects the App's 512-event trace from a
/// stuck session.
static const NSUInteger FloeRenderProbeMaxProgressBreadcrumbs = 10;
/// While no new readiness class appears, the probe still refreshes the
/// breadcrumb on this poll cadence, leaving a time series for a long import.
static const NSUInteger FloeRenderProbeProgressCadenceAttempts = 20;
/// A poll's JS evaluation that has not called back within this many seconds is
/// a stalled (or dead) web content process. The probe persists a bounded stall
/// breadcrumb instead of leaving the trace silent until the wall-clock
/// deadline; the deadline still owns the bounded outcome.
static const NSTimeInterval FloeRenderProbeEvalStallSeconds = 3.0;
/// Upper bound on stall breadcrumbs per probe session.
static const NSUInteger FloeRenderProbeMaxStallBreadcrumbs = 3;

/// The readiness classes one poll observed. `pageObserved` is the probe's own
/// JS stage (`ready`), never a guessed value.
static NSUInteger FloeRenderProbeProgressMask(FloeRenderFacts facts, BOOL pageObserved) {
    NSUInteger mask = pageObserved ? FloeProbeProgressPage : 0;
    if (facts.docTypeKnown) mask |= FloeProbeProgressType;
    if (facts.docLoaded) mask |= FloeProbeProgressLoaded;
    if (facts.canvasSized) mask |= FloeProbeProgressCanvas;
    if (facts.tileDecoded) mask |= FloeProbeProgressTile;
    if (facts.pixelPainted) mask |= FloeProbeProgressPaint;
    if (facts.editSurfacePainted) mask |= FloeProbeProgressEditSurface;
    return mask;
}

/// Bounded render-probe counters for the failure/unobserved stages. Only
/// counters, booleans and engine type/layout strings survive; pixel sample
/// dictionaries and unknown keys are dropped, so the durable trace can never
/// receive document content or paths.
static NSDictionary<NSString *, id> *FloeRenderProbeDiagnosticFacts(NSDictionary<NSString *, id> *diagnostics) {
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"stage", @"failure", @"format", @"readOnly", @"requiresVisibleRender",
                 @"docType", @"docLoaded", @"fileBasedView", @"tiles", @"decodedTiles",
                 @"attempts", @"elapsed", @"deadline", @"editSurfacePainted",
                 @"editSurfaceNewDecodes", @"editSurfaceChangedSamples",
                 @"editSurfaceLayoutChanged", @"editSurfaceLayout",
                 @"evalStalled", @"evalPendingSeconds"];
    });
    NSMutableDictionary<NSString *, id> *facts = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        id value = diagnostics[key];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])
            facts[key] = value;
    }
    return facts;
}
// FLOE_RENDER_PROGRESS_END

// FLOE_RENDER_PROBE_SCRIPT_BEGIN
// Downsampled document-canvas fingerprint. The probe never returns pixels or
// document contents, only counters, booleans and the edit-surface paint
// evidence it derives from them (the baseline samples stay in the page).
static NSString *FloeRenderProbeScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    try {
        const map = window.app && window.app.map;
        if (!map) return { stage: 'map' };
        const file = (window.app && window.app.file) || {};
        const layer = map._docLayer || null;
        const docType = layer && typeof layer._docType === 'string'
            ? layer._docType
            : (typeof map.getDocType === 'function' ? map.getDocType() : null);
        const manager = window.RenderManager
            || (window.app && window.app.definitions && window.app.definitions.RenderManager)
            || null;
        let tiles = 0;
        let decodedTiles = 0;
        const decodedImages = new Map();
        if (manager && typeof manager.getTiles === 'function') {
            const all = manager.getTiles();
            if (all && typeof all.forEach === 'function') {
                all.forEach((tile, key) => {
                    tiles++;
                    if (!tile) return;
                    const ready = typeof tile.isReadyToDraw === 'function'
                        ? tile.isReadyToDraw() : !!tile.image;
                    if (ready) {
                        decodedTiles++;
                        decodedImages.set(String(key), tile.image);
                    }
                });
            }
        }
        const canvases = document.querySelectorAll('canvas');
        let canvas = null;
        for (let i = 0; i < canvases.length; i++) {
            const candidate = canvases[i];
            if (!candidate || candidate.width < 2 || candidate.height < 2) continue;
            if (!canvas || candidate.width * candidate.height > canvas.width * canvas.height)
                canvas = candidate;
        }
        let pixels = null;
        let sampled = null;
        if (canvas) {
            try {
                const probe = document.createElement('canvas');
                probe.width = 24;
                probe.height = 16;
                const context = probe.getContext('2d', { willReadFrequently: true });
                context.drawImage(canvas, 0, 0, canvas.width, canvas.height, 0, 0, 24, 16);
                const data = context.getImageData(0, 0, 24, 16).data;
                sampled = data;
                const colours = {};
                let distinct = 0;
                let opaque = 0;
                for (let i = 0; i < data.length; i += 4) {
                    if (data[i + 3] > 8) opaque++;
                    const key = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
                    if (colours[key] !== true) {
                        colours[key] = true;
                        distinct++;
                    }
                }
                pixels = { distinctColours: distinct, samples: data.length / 4, opaque: opaque };
            } catch (_) { pixels = null; sampled = null; }
        }
        const vectorRendering = !!(manager && typeof manager.isVectorRendering === 'function'
            && manager.isVectorRendering());
        const fileBasedView = file.fileBasedView === true;
        // FLOE_EDIT_SURFACE_EVIDENCE_BEGIN
        // Edit-surface paint evidence. The engine's shared tile map keeps the
        // file-based startup's decoded tiles across
        // ImpressTileLayer._switchToPartBasedView (pinned engine 27b21dc1: the
        // switch only flips app.file.fileBasedView, swaps the active layout and
        // updates the scroll limits), so a decoded tile plus a cleared flag can
        // be the leftover preview frame. An editable presentation is ready only
        // after its own surface painted: a tile decoded after the switch (a
        // different image object for the same tile key, or a tile that was not
        // decoded before), a repainted document canvas (downsampled samples
        // changed), or — the layout-swap receipt below — a real layout swap
        // followed by painted canvas content. The last file-based frame is the
        // baseline the edit surface must move away from; the host also arms
        // that baseline with the session generation immediately before it runs
        // the deferred edit entry, so the evidence can only describe work done
        // after the entry.
        const state = window.__floeEditSurfaceState || (window.__floeEditSurfaceState = {
            baseline: null,
            painted: false,
            armedToken: null,
        });
        // The shipped engine tags its view layouts with a stable string
        // (`app.activeDocument.activeLayout.type`, e.g. "ViewLayoutFileBased"
        // vs "ViewLayoutImpress"); verified against the pinned bundle. The
        // layout swap is the engine-protocol receipt that the guarded entry
        // rebuilt the edit surface: when the engine then shows painted canvas
        // content, the edit surface provably repainted even if its pixels are
        // identical to the preview (tile-cache reuse with an unchanged
        // downsampled fingerprint otherwise reads as "never painted" and the
        // session would be failed on a healthy, painted editor).
        const activeLayoutType = () => {
            try {
                const doc = window.app && window.app.activeDocument;
                const layout = doc && doc.activeLayout;
                return layout && typeof layout.type === 'string' ? layout.type : null;
            } catch (_) { return null; }
        };
        const contentPainted = pixels !== null && pixels.distinctColours >= 2
            && pixels.samples > 0 && pixels.opaque * 8 >= pixels.samples;
        const captureBaseline = (token) => ({
            token: token || null,
            at: Date.now(),
            samples: sampled ? new Uint8ClampedArray(sampled) : null,
            images: new Map(decodedImages),
            layout: activeLayoutType(),
        });
        window.__floeArmEditSurface = function (token) {
            try {
                state.armedToken = String(token);
                if (fileBasedView) state.baseline = captureBaseline(state.armedToken);
                return true;
            } catch (_) { return false; }
        };
        let newDecodes = 0;
        let changedSamples = 0;
        let canvasRepainted = false;
        let layoutChanged = false;
        if (fileBasedView) {
            // The engine's read-only/mobile startup paints the file-based
            // preview. That is the leftover frame a stale edit surface could
            // show, so it is the baseline, never the evidence.
            state.baseline = captureBaseline(state.armedToken);
        } else if (state.baseline) {
            const baseline = state.baseline;
            const currentLayout = activeLayoutType();
            layoutChanged = baseline.layout !== null && currentLayout !== null
                && baseline.layout !== currentLayout;
            if (baseline.samples && sampled) {
                const length = Math.min(baseline.samples.length, sampled.length);
                for (let i = 0; i + 3 < length; i += 4) {
                    if (baseline.samples[i] !== sampled[i]
                        || baseline.samples[i + 1] !== sampled[i + 1]
                        || baseline.samples[i + 2] !== sampled[i + 2]
                        || baseline.samples[i + 3] !== sampled[i + 3])
                        changedSamples++;
                }
                // One downsampled sample is a 1/384th of the document canvas;
                // four changed samples are a real relayout, not a blink or an
                // anti-aliasing flicker.
                canvasRepainted = changedSamples >= 4;
            } else if (!baseline.samples && sampled) {
                // The document canvas itself appeared after the switch.
                canvasRepainted = true;
            }
            decodedImages.forEach((image, key) => {
                if (baseline.images.get(key) !== image) newDecodes++;
            });
            if (newDecodes > 0 || canvasRepainted
                || (layoutChanged && contentPainted)) state.painted = true;
        } else {
            // No file-based startup frame was observed on this page, so there
            // is no observed pre-edit frame to mistake for the edit surface;
            // the visible-render facts remain the only evidence.
            state.painted = true;
        }
        // FLOE_EDIT_SURFACE_EVIDENCE_END
        return {
            stage: 'ready',
            docType: docType || null,
            docLoaded: map._docLoaded === true,
            fileBasedView: fileBasedView,
            backendReadOnly: file.readOnly === true,
            uiEdit: typeof map.isEditMode === 'function' && map.isEditMode() === true,
            permission: typeof map._permission === 'string' ? map._permission : null,
            tiles: tiles,
            decodedTiles: decodedTiles,
            vectorRendering: vectorRendering,
            canvas: canvas ? {
                width: canvas.width,
                height: canvas.height,
                clientWidth: canvas.clientWidth,
                clientHeight: canvas.clientHeight,
            } : null,
            pixels: pixels,
            editSurfacePainted: state.painted,
            editSurfaceBaseline: state.baseline !== null,
            editSurfaceArmed: state.armedToken !== null,
            editSurfaceNewDecodes: newDecodes,
            editSurfaceChangedSamples: changedSamples,
            editSurfaceLayoutChanged: layoutChanged,
            editSurfaceLayout: activeLayoutType(),
        };
    } catch (_) {
        return { stage: 'error' };
    }
})()
)FLOE_JS"];
}
// FLOE_RENDER_PROBE_SCRIPT_END

// FLOE_EDIT_SURFACE_ARM_SCRIPT_BEGIN
// The host evaluates this immediately before it runs the paint-gated edit
// entry. It pins the edit-surface paint baseline to the frame that is on
// screen at the entry (the last file-based preview paint) and stamps it with
// the session id and open generation, so the visible-render report can only
// come from a paint that happened after this entry — never from the preview
// tiles the engine's shared tile map keeps across the layout switch. The
// baseline samples stay in the page; the payload carries the correlation id
// only.
static NSString *FloeEditSurfaceArmScript(NSString *token) {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:(token ?: @"") options:0 error:nil];
    NSString *literal = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] ?: @"\"\"";
    NSString *source = [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    try {
        if (typeof window.__floeArmEditSurface !== 'function') return false;
        return window.__floeArmEditSurface(__FLOE_EDIT_SURFACE_TOKEN__) === true;
    } catch (_) { return false; }
})()
)FLOE_JS"];
    return [source stringByReplacingOccurrencesOfString:@"__FLOE_EDIT_SURFACE_TOKEN__" withString:literal];
}
// FLOE_EDIT_SURFACE_ARM_SCRIPT_END
// FLOE_RENDER_READINESS_END

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

// FLOE_SESSION_FACTS_BEGIN
// The host's own mount grant, exposed to the injected editor scripts. The
// engine cannot infer the App's requested permission from a handshake that omits
// `permission` for editable sessions, and a missing fact must never be read as
// an editing grant. Contains no document contents.
static NSString *FloeSessionFactsScript(BOOL readOnly, NSString *fileName) {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:@{
        @"readOnly": @(readOnly),
        @"editable": @(!readOnly),
        @"fileName": fileName.lastPathComponent ?: @"",
        @"extension": fileName.pathExtension.lowercaseString ?: @"",
    } options:0 error:nil];
    NSString *facts = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] ?: @"{}";
    return [NSString stringWithFormat:
        @"window.__floeOfficeSession = Object.freeze(%@);", facts];
}
// FLOE_SESSION_FACTS_END

// FLOE_FULLSCREEN_EDIT_SCRIPT_BEGIN
// Edit-intent handoff: in Floe's fullscreen editable mounts the page is
// deliberately NOT the edit-intent owner. The native host is. The host knows
// the real readiness the page cannot observe: the UIDocument open, the
// engine's verified backing permission, the document layer's first status and
// — for the file-based Impress/Draw startup — a decoded document tile.
//
// The previous wrapper called `map._switchToEditMode()` synchronously from the
// first `setPermission('edit')`. In the pinned engine (`Socket.ts`,
// `CanvasTileLayer.onAdd`) that first grant arrives while the layer is still
// initialising: `onAdd` calls `map.setPermission(app.file.permission)` and only
// afterwards runs `sendInitUNOCommands()` and `setInitialZoom()`. An entry
// driven from inside that call is therefore re-entrant with the layer's own
// initialisation; and the engine's `_enterEditMode` dereferences
// `this._docLayer` (`_docType`, and Calc's `showCalcInputBar`), so an entry
// that reaches the engine before the layer exists throws after it already set
// `_permission = 'edit'` and fired `updatepermission` — partial edit state.
// The file-based Impress/Draw startup additionally needs its preview to decode
// its first document tile before the layout switch has a real document extent.
//
// The wrapper therefore leaves the engine's own mobile startup untouched: on
// first open it still enters its normal viewing-first readonly mode
// (Permission.js), and the host runs the engine's guarded
// `map._switchToEditMode()` exactly once, asynchronously, after the readiness
// the render probe observes. The in-page mobile edit button is a second,
// human-owned intent path, so it is hidden here: the fullscreen mount itself
// is already the explicit edit action and the App owns the recoverable
// outcome (retry/recovery) instead of two entries racing.
static NSString *FloeFullScreenEditScript() {
    return [NSString stringWithUTF8String:R"FLOE_JS(
(() => {
    const install = () => {
        const proto = window.L && window.L.Map && window.L.Map.prototype;
        if (!proto || typeof proto.setPermission !== 'function' || proto.floeEditHandoffInstalled) return;
        proto.floeEditHandoffInstalled = true;
        const setPermission = proto.setPermission;
        const hideMobileEditEntry = () => {
            const button = document.getElementById('mobile-edit-button');
            if (!button) return;
            button.hidden = true;
            button.setAttribute('aria-hidden', 'true');
            button.setAttribute('tabindex', '-1');
        };
        const style = document.createElement('style');
        style.textContent = '#mobile-edit-button { display: none !important; }';
        document.head.appendChild(style);
        proto.setPermission = function (permission) {
            const firstOpen = this._permission === undefined;
            const result = setPermission.apply(this, arguments);
            if (firstOpen) {
                // Content-free marker for the host diagnostics: the initial
                // grant the engine itself applied (the page records, never
                // acts on it).
                try {
                    window.__floeInitialGrant = {
                        permission: String(permission),
                        hostEditable: (window.__floeOfficeSession || {}).editable === true,
                        at: Date.now(),
                    };
                } catch (_) {}
                hideMobileEditEntry();
            }
            return result;
        };
        hideMobileEditEntry();
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
/// Build 233 (R1): the engine's own font-discovery facts, shared with the
/// App's durable diagnostics after `prepare` settles. Main-queue owned because
/// `startEngine` populates it there.
+ (NSDictionary<NSString *, id> *)fontDiscoveryFacts {
    return gFloeFontDiscoveryFacts ?: @{};
}
- (void)finishWaiters:(NSError *)error {
    NSArray *pending = [self.waiters copy];
    [self.waiters removeAllObjects];
    for (void (^completion)(NSError *) in pending) completion(error);
}
- (void)serverBecameReady {
    if (self.state != FloeRuntimeStarting) return;
    self.state = FloeRuntimeReady;
    FloeOfficeLog(@"host-ready", @{});
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

// FLOE_RENDER_PROBE_BEGIN
// Bounded, main-queue owned probe for the first visible document render. It
// polls the shipped `FloeRenderProbeScript` and finishes exactly once; a
// session that never paints its document surface reports a bounded failure
// instead of leaving a blank editor that claims to be ready.

// FLOE_EDIT_ENTRY_GATE_BEGIN
// Two format-aware thresholds over the same render facts, compiled
// independently by test_office_native_host.py against synthetic engine states:
//
// * the edit-entry trigger fires at the real readiness of the format, never on
//   the open-permission clock (the pinned engine reports the backing
//   permission from main.js before any document layer exists):
//     – the file-based presentation formats require a decoded document tile:
//       proof of a live paint pipeline and a real document extent before the
//       guarded entry may switch the file-based startup into the part-based
//       edit layout;
//     – Word/Excel require the document layer's completed first status — a
//       reported document type, `docloaded` and a sized canvas. In the pinned
//       engine (`Socket.ts`) `_docLayer` is assigned before `addLayer`, and
//       `docloaded` is fired only after `CanvasTileLayer.onAdd` returned — an
//       `onAdd` whose final `setPermission(app.file.permission)` is where the
//       old page wrapper synchronously re-entered `_switchToEditMode()` before
//       the same `onAdd` had run `sendInitUNOCommands()`/`setInitialZoom()`,
//       and before the layer had processed the status it was created for. The
//       engine's `_enterEditMode` also dereferences `this._docLayer`, so the
//       layer must exist before any entry.
// * the session-ready threshold additionally requires the part-based edit
//   surface for an editable session (fileBasedView cleared) *and* a paint that
//   happened after the edit entry (`editSurfacePainted`): a file-based startup
//   paint is preview evidence, never edit-surface evidence, and the engine's
//   shared tile map keeps the preview's decoded tiles across the layout
//   switch, so the tile count alone is never edit-surface evidence.
// * the edit-entry trigger has one bounded, weaker-evidence fallback for the
//   file-based presentation formats: a session that proved the document
//   extent (type, loaded document and sized canvas) but waited
//   `FloeEditEntryExtentBootstrapGraceSeconds` without decoding any tile may
//   run the guarded entry on the extent proof alone. Nothing here relaxes the
//   session-ready threshold — readiness below still demands the post-entry
//   paint, so the fallback can never ready a session whose edit surface did
//   not really paint.
// * the open-permission report is settled by the entry (or the bounded
//   fallback), never before it, so a session's readiness can not run ahead of
//   the entry it is evidence for.
static bool FloeRenderFactsSatisfyEditEntryTrigger(FloeRenderFacts facts, bool requiresVisibleRender) {
    if (requiresVisibleRender) return FloeRenderFactsSatisfyVisibleRender(facts);
    // Word/Excel: the layer exists, its first status was fully processed and
    // its canvas has a real size. The `docloaded` event follows
    // `addLayer`/`onAdd`, sets `_docLoaded` and then the same synchronous
    // status task runs the layer's `_onMessage`; a probe evaluation is its own
    // task, so observing the flag already implies that task returned. A type
    // alone is not readiness: it can be reported while the layer is still
    // initialising.
    return facts.docTypeKnown && facts.docLoaded && facts.canvasSized;
}

/// Bounded weaker-evidence fallback for the paint-gated edit entry (see the
/// gate comment above). Pure and compiled by the qualification harness.
static const NSTimeInterval FloeEditEntryExtentBootstrapGraceSeconds = 5.0;
static bool FloeDeferredEditEntryExtentBootstrapEligible(BOOL entryPending,
                                                         BOOL entryRunning,
                                                         BOOL openPermissionReported,
                                                         BOOL extentProven,
                                                         NSTimeInterval parkedSeconds) {
    if (!entryPending || entryRunning || openPermissionReported) return false;
    if (!extentProven) return false;
    return parkedSeconds >= FloeEditEntryExtentBootstrapGraceSeconds;
}

static bool FloeRenderFactsSatisfySessionReady(FloeRenderFacts facts, bool readOnly, bool fileBasedView) {
    if (!FloeRenderFactsSatisfyVisibleRender(facts)) return false;
    if (readOnly) return true;
    if (fileBasedView) return false;
    // The engine's shared tile map keeps the file-based startup's decoded
    // tiles across `ImpressTileLayer._switchToPartBasedView` (pinned engine
    // 27b21dc1: the switch only flips `app.file.fileBasedView`, swaps the
    // active layout and updates the scroll limits; `BitmapTileManager.tiles`
    // and the `RenderManager` instance survive — verified against the pinned
    // sources and the shipped bundle). A decoded tile plus a cleared flag
    // therefore proves nothing about the edit surface: it can be the leftover
    // preview frame. An editable session is ready only after its own surface
    // painted — a tile decoded after the edit entry, a repainted document
    // canvas, or the layout-swap receipt (a real file->part layout change
    // followed by painted canvas content, which also covers a repaint whose
    // pixels are identical to the preview because the engine reused its tile
    // cache entries).
    return facts.editSurfacePainted;
}
// FLOE_EDIT_ENTRY_GATE_END

@interface FloeOfficeNativeViewController (FloeRenderProbe)
- (void)evaluateRenderFactsWithCompletion:(void (^)(NSDictionary<NSString *, id> * _Nullable facts,
                                                    NSError * _Nullable error))completion;
/// The engine decoded at least one document tile on a sized canvas — proof of
/// a live paint pipeline and a real document extent. Fired at most once per
/// session, before the session-ready decision, and never for a skeleton-only
/// surface. The host gates the guarded mobile edit entry on this: switching
/// the file-based presentation startup into the part-based edit layout before
/// any tile exists builds the edit surface on an empty document extent, which
/// is the device white screen.
- (void)renderProbeDidObserveFirstPaint:(NSDictionary<NSString *, id> *)diagnostics;
/// The probe reached the format-specific edit-entry readiness (decoded tile
/// for the file-based presentation formats, or full first-status layer init
/// — reported type, `docloaded` and a sized canvas — for Word/Excel). The
/// single parked edit entry runs here; the probe state is also latched so an
/// entry that parks just after still runs.
- (void)renderProbeDidReachEditEntryReadiness;
- (void)renderProbeDidObserveVisibleRender:(NSDictionary<NSString *, id> *)diagnostics;
- (void)renderProbeDidFail:(NSError *)error diagnostics:(NSDictionary<NSString *, id> *)diagnostics;
- (void)renderProbeDidFinishWithoutVisibleRender:(NSDictionary<NSString *, id> *)diagnostics;
/// The open-permission/entry report settled for this open generation. The
/// deferred edit entry settles it; the visible-render ready must never precede
/// that acknowledgement (an entry that ends in a password prompt or a refusal
/// must not have declared the edit surface ready). `reportOpenPermissionOnce`
/// is the one-shot latch behind it.
- (BOOL)hasSettledOpenPermission;
// The probe implementation appears before the controller's private class
// extension, so expose only the observations it needs at this boundary.
- (BOOL)hasPendingDeferredEditEntry;
- (BOOL)isDeferredEditEntryRunning;
- (BOOL)hasReportedOpenPermission;
- (NSTimeInterval)deferredEditEntryParkedSeconds;
- (NSString *)renderProbeSessionID;
- (NSUInteger)renderProbeOpenGeneration;
- (void)renderProbeDidProveExtentForEditEntry;
@end

@interface FloeOfficeRenderProbe : NSObject
@property (nonatomic, weak) FloeOfficeNativeViewController *controller;
/// Presentation/drawing formats must show a decoded document tile; other
/// formats report the first paint as diagnostics but never fail the session.
@property (nonatomic) BOOL requiresVisibleRender;
/// The mount grant this probe was started for. An editable session's
/// session-ready evidence must come from the part-based edit surface
/// (fileBasedView cleared), never from the file-based startup view.
@property (nonatomic, readonly) BOOL readOnlySession;
/// The session-ready decision additionally requires the edit entry's own
/// acknowledgement for the paint-gated file-based formats: the ready signal
/// must never overtake the entry it is evidence for.
@property (nonatomic, readonly) BOOL expectsDeferredEditEntry;
@property (nonatomic) NSTimeInterval deadline;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *diagnostics;
- (instancetype)initWithController:(FloeOfficeNativeViewController *)controller
                          readOnly:(BOOL)readOnly
                       workingFile:(NSURL *)workingFile;
- (void)start;
- (void)cancel;
@end

@implementation FloeOfficeRenderProbe {
    NSDate *_startedAt;
    NSUInteger _attempts;
    BOOL _finished;
    BOOL _cancelled;
    /// The first-paint trigger was delivered; it fires at most once per session.
    BOOL _firstPaintReported;
    NSMutableDictionary<NSString *, id> *_lastFacts;
    /// Last logged probe stage; polling every 200 ms must not flood the log.
    NSString *_lastLoggedStage;
    /// Readiness classes and JS stage already persisted as durable progress
    /// breadcrumbs, plus the bounded emission count. Diagnostics only: the
    /// readiness decisions never read these.
    NSUInteger _persistedProgressMask;
    NSString *_persistedProgressStage;
    NSUInteger _progressEmissions;
    /// The poll evaluation currently in flight and its issue time. A
    /// callback-less evaluation is the "stalled JS" case: it blocks the next
    /// poll (the next poll is scheduled from the completion), so the stall is
    /// persisted explicitly and bounded.
    BOOL _evalPending;
    NSUInteger _inFlightAttempt;
    NSDate *_evalStartedAt;
    NSUInteger _stallBreadcrumbs;
    /// Wall-clock deadline. The completion-driven check below only runs after a
    /// probe eval finishes; a content process that never answers an eval would
    /// otherwise delay the honest bounded outcome past the App's budgets. The
    /// timer guarantees the render report fires at the deadline either way.
    dispatch_source_t _deadlineTimer;
}

- (instancetype)initWithController:(FloeOfficeNativeViewController *)controller
                          readOnly:(BOOL)readOnly
                       workingFile:(NSURL *)workingFile {
    if ((self = [super init])) {
        _controller = controller;
        _requiresVisibleRender = FloeDocumentRequiresVisibleRender(workingFile.pathExtension);
        _readOnlySession = readOnly;
        _expectsDeferredEditEntry = _requiresVisibleRender && !readOnly;
        // A preview of the same presentation shapes is cheaper than an editable
        // session (no edit-mode switch and no part-based relayout), so it gets a
        // smaller bound. Both stay below the App's open watchdog so the honest
        // render failure wins over the generic open timeout.
        _deadline = readOnly ? 20.0 : 25.0;
        _lastFacts = [NSMutableDictionary dictionaryWithDictionary:@{
            @"format": workingFile.pathExtension.lowercaseString ?: @"",
            @"readOnly": @(readOnly),
            @"requiresVisibleRender": @(_requiresVisibleRender),
            @"stage": @"not-started",
        }];
    }
    return self;
}

- (NSDictionary<NSString *, id> *)diagnostics {
    NSMutableDictionary *facts = [_lastFacts mutableCopy];
    facts[@"attempts"] = @(_attempts);
    facts[@"elapsed"] = @(_startedAt ? -[_startedAt timeIntervalSinceNow] : 0);
    facts[@"deadline"] = @(self.deadline);
    return facts;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    if (_startedAt || _finished || _cancelled) return;
    _startedAt = [NSDate date];
    __weak FloeOfficeRenderProbe *weakSelf = self;
    _deadlineTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_deadlineTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.deadline * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(_deadlineTimer, ^{
        FloeOfficeRenderProbe *probe = weakSelf;
        if (!probe || probe->_finished || probe->_cancelled) return;
        [probe finishWithStage:@"deadline"];
        [probe reportFailureIfRequiredWithReason:@"no-visible-render"];
    });
    dispatch_resume(_deadlineTimer);
    [self poll];
}

- (void)invalidateDeadlineTimer {
    if (_deadlineTimer) {
        dispatch_source_cancel(_deadlineTimer);
        _deadlineTimer = nil;
    }
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    _cancelled = YES;
    _finished = YES;
    [self invalidateDeadlineTimer];
    [_lastFacts setObject:@"cancelled" forKey:@"stage"];
}

- (void)finishWithStage:(NSString *)stage {
    _finished = YES;
    [self invalidateDeadlineTimer];
    [_lastFacts setObject:stage forKey:@"stage"];
}

- (void)poll {
    if (_finished || _cancelled) return;
    FloeOfficeNativeViewController *controller = self.controller;
    if (!controller) {
        [self finishWithStage:@"controller-gone"];
        [self reportFailureIfRequiredWithReason:@"editor-surface-missing"];
        return;
    }
    _attempts++;
    _inFlightAttempt = _attempts;
    _evalStartedAt = [NSDate date];
    _evalPending = YES;
    // Names a never-returning evaluation (stalled or dead web content
    // process) in the durable trace; the deadline still owns the outcome.
    [self scheduleEvalStallCheckForAttempt:_attempts];
    __weak FloeOfficeRenderProbe *weakSelf = self;
    [controller evaluateRenderFactsWithCompletion:^(NSDictionary<NSString *, id> *facts, NSError *error) {
        FloeOfficeRenderProbe *probe = weakSelf;
        if (!probe || probe->_finished || probe->_cancelled) return;
        probe->_evalPending = NO;
        if (facts) [probe->_lastFacts addEntriesFromDictionary:facts];
        if (facts) {
            FloeRenderFacts renderFacts = [probe renderFactsFromDictionary:facts];
            // Durable, bounded progress breadcrumb first: a process killed
            // inside this poll window leaves the furthest observed readiness
            // class (and its memory sample) in the App's trace.
            [probe persistProgressWithFacts:facts renderFacts:renderFacts];
            NSString *stage = [facts[@"stage"] isKindOfClass:NSString.class] ? facts[@"stage"] : nil;
            if (stage && ![stage isEqualToString:probe->_lastLoggedStage]) {
                probe->_lastLoggedStage = stage;
                FloeOfficeLog(@"render-probe-facts", facts);
            }
            // Format-specific entry readiness (see the gate comment): the
            // file-based presentation formats need a decoded document tile;
            // Word/Excel need the document layer's full first-status init.
            BOOL visibleRenderProven = FloeRenderFactsSatisfyVisibleRender(renderFacts);
            BOOL entryTrigger = FloeRenderFactsSatisfyEditEntryTrigger(renderFacts,
                                                                       probe.requiresVisibleRender);
            BOOL extentBootstrap = NO;
            if (!visibleRenderProven && probe.expectsDeferredEditEntry) {
                BOOL extentProven = renderFacts.docTypeKnown && renderFacts.docLoaded && renderFacts.canvasSized;
                NSTimeInterval parked = [probe.controller deferredEditEntryParkedSeconds];
                if (FloeDeferredEditEntryExtentBootstrapEligible([probe.controller hasPendingDeferredEditEntry],
                                                                 [probe.controller isDeferredEditEntryRunning],
                                                                 [probe.controller hasReportedOpenPermission],
                                                                 extentProven, parked)) {
                    extentBootstrap = YES;
                    FloeOfficeLog(@"edit-entry-extent-bootstrap", @{@"session": [probe.controller renderProbeSessionID],
                                                                    @"generation": @([probe.controller renderProbeOpenGeneration]),
                                                                    @"parked": @(parked)});
                    // This only permits the guarded edit entry. No document
                    // tile has painted, so it must not set firstPaintObserved
                    // or emit first-paint/visible-render evidence.
                    [probe.controller renderProbeDidProveExtentForEditEntry];
                }
            }
            if (entryTrigger || extentBootstrap) {
                // Reported before the session-ready decision, at most once per
                // session, so a pending edit entry always runs. A document
                // layer alone is NOT first-paint evidence for Word/Excel, so
                // the first-paint report stays tied to the visible render.
                if (visibleRenderProven && !probe->_firstPaintReported) {
                    probe->_firstPaintReported = YES;
                    [probe.controller renderProbeDidObserveFirstPaint:probe.diagnostics];
                }
                // The single edit entry runs once at this readiness, whether
                // it was already parked or parks just after the probe passed.
                if (entryTrigger) [probe.controller renderProbeDidReachEditEntryReadiness];
                BOOL fileBasedView = [facts[@"fileBasedView"] isKindOfClass:NSNumber.class]
                    && [facts[@"fileBasedView"] boolValue];
                BOOL ready = FloeRenderFactsSatisfySessionReady(renderFacts, probe.readOnlySession, fileBasedView);
                // The ready signal for the paint-gated edit entry never
                // precedes the entry's own acknowledgement: the entry can still
                // end in a password prompt or a refusal, and the App's
                // permission report is the acknowledgement the edit path
                // awaits. The entry settles the one-shot report, so this only
                // delays readiness by the entry completion.
                if (ready && probe.expectsDeferredEditEntry && ![probe.controller hasSettledOpenPermission])
                    ready = NO;
                if (ready) {
                    [probe finishWithStage:@"visible-render"];
                    [probe.controller renderProbeDidObserveVisibleRender:probe.diagnostics];
                    return;
                }
                // An editable presentation still shows the file-based startup:
                // the guarded entry now switches it to the part-based edit
                // layout. Keep polling, bounded by the deadline, for the edit
                // surface's own paint — the session is only ready on that, and
                // only after a paint that happened after the entry.
            }
        } else {
            // A page that stopped answering the eval (or a dead web content
            // process) still leaves its bounded probe state in the trace.
            [probe persistProgressWithFacts:@{@"stage": @"no-facts",
                                              @"errorCode": @(error.code)}
                                renderFacts:(FloeRenderFacts){0}];
        }
        if (probe->_startedAt && -[probe->_startedAt timeIntervalSinceNow] >= probe.deadline) {
            [probe finishWithStage:@"deadline"];
            [probe reportFailureIfRequiredWithReason:error ? @"probe-error" : @"no-visible-render"];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf poll]; });
    }];
}

/// Persists one bounded, content-free progress breadcrumb when a poll observes
/// a new readiness class or JS stage (and on the slow cadence). The line names
/// how far the engine got and how long the edit entry has been parked; the
/// App's durable trace keeps it across a hard kill. Diagnostics only: no
/// readiness decision reads the persisted state.
- (void)persistProgressWithFacts:(NSDictionary<NSString *, id> *)facts
                     renderFacts:(FloeRenderFacts)renderFacts {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    if (_finished || _cancelled) return;
    if (_progressEmissions >= FloeRenderProbeMaxProgressBreadcrumbs) return;
    NSString *stage = [facts[@"stage"] isKindOfClass:NSString.class] ? facts[@"stage"] : nil;
    NSString *stageName = stage ?: @"unknown";
    NSUInteger mask = FloeRenderProbeProgressMask(renderFacts, [stage isEqualToString:@"ready"]);
    BOOL stageChanged = ![stageName isEqualToString:_persistedProgressStage ?: @""];
    BOOL cadence = (_attempts % FloeRenderProbeProgressCadenceAttempts) == 0;
    if (_progressEmissions > 0 && !stageChanged && mask == _persistedProgressMask && !cadence) return;
    _persistedProgressStage = stageName;
    _persistedProgressMask = mask;
    _progressEmissions++;
    NSMutableDictionary<NSString *, id> *progress = [@{
        @"stage": stageName,
        @"attempts": @(_attempts),
        @"docTypeKnown": @(renderFacts.docTypeKnown),
        @"docLoaded": @(renderFacts.docLoaded),
        @"canvasSized": @(renderFacts.canvasSized),
        @"tileDecoded": @(renderFacts.tileDecoded),
        @"pixelPainted": @(renderFacts.pixelPainted),
        @"editSurfacePainted": @(renderFacts.editSurfacePainted),
        @"fileBasedView": @([facts[@"fileBasedView"] isKindOfClass:NSNumber.class] && [facts[@"fileBasedView"] boolValue]),
    } mutableCopy];
    if ([facts[@"docType"] isKindOfClass:NSString.class]) progress[@"docType"] = facts[@"docType"];
    if ([facts[@"tiles"] isKindOfClass:NSNumber.class]) progress[@"tiles"] = facts[@"tiles"];
    if ([facts[@"decodedTiles"] isKindOfClass:NSNumber.class]) progress[@"decodedTiles"] = facts[@"decodedTiles"];
    if ([facts[@"editSurfaceNewDecodes"] isKindOfClass:NSNumber.class])
        progress[@"newDecodes"] = facts[@"editSurfaceNewDecodes"];
    if ([facts[@"errorCode"] isKindOfClass:NSNumber.class]) progress[@"errorCode"] = facts[@"errorCode"];
    // A parked edit entry names its own wait in the same trace line.
    FloeOfficeNativeViewController *controller = self.controller;
    if ([controller hasPendingDeferredEditEntry])
        progress[@"entryParkedSeconds"] = @((long long)[controller deferredEditEntryParkedSeconds]);
    [controller floeStage:@"render-probe-progress" facts:progress];
}

/// Names a poll evaluation that never called back — a stalled or dead web
/// content process — with a bounded, content-free breadcrumb. The evaluation
/// blocks the poll chain (the next poll is scheduled from its completion), so
/// without this the trace would stay silent until the wall-clock deadline.
/// The deadline still owns the bounded outcome; this only makes the stall
/// attributable. Content-free: counters, the deadline and the last readiness
/// mask, never page contents.
- (void)scheduleEvalStallCheckForAttempt:(NSUInteger)attempt {
    __weak FloeOfficeRenderProbe *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(FloeRenderProbeEvalStallSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FloeOfficeRenderProbe *probe = weakSelf;
        if (!probe || probe->_finished || probe->_cancelled) return;
        if (!probe->_evalPending || probe->_inFlightAttempt != attempt) return;
        if (probe->_stallBreadcrumbs >= FloeRenderProbeMaxStallBreadcrumbs) return;
        probe->_stallBreadcrumbs++;
        NSTimeInterval pending = probe->_evalStartedAt
            ? -[probe->_evalStartedAt timeIntervalSinceNow] : 0;
        // The diagnostics snapshot the failure/unobserved stages consume
        // carries the stall too, so a deadline outcome names it.
        [probe->_lastFacts setObject:@YES forKey:@"evalStalled"];
        [probe->_lastFacts setObject:@(pending) forKey:@"evalPendingSeconds"];
        [probe.controller floeStage:@"render-probe-stalled" facts:@{
            @"attempts": @(attempt),
            @"pendingSeconds": @((long long)pending),
            @"deadline": @(probe.deadline),
            @"readinessMask": @(probe->_persistedProgressMask),
        }];
        // Keep the bounded series going while the evaluation stays pending.
        if (probe->_stallBreadcrumbs < FloeRenderProbeMaxStallBreadcrumbs)
            [probe scheduleEvalStallCheckForAttempt:attempt];
    });
}

- (FloeRenderFacts)renderFactsFromDictionary:(NSDictionary *)facts {
    FloeRenderFacts render;
    render.docTypeKnown = [facts[@"docType"] isKindOfClass:NSString.class]
        && [(NSString *)facts[@"docType"] length] > 0;
    render.docLoaded = [facts[@"docLoaded"] isKindOfClass:NSNumber.class] && [facts[@"docLoaded"] boolValue];
    render.vectorRendering = [facts[@"vectorRendering"] isKindOfClass:NSNumber.class]
        && [facts[@"vectorRendering"] boolValue];
    NSDictionary *canvas = [facts[@"canvas"] isKindOfClass:NSDictionary.class] ? facts[@"canvas"] : nil;
    double width = [canvas[@"width"] isKindOfClass:NSNumber.class] ? [canvas[@"width"] doubleValue] : 0;
    double height = [canvas[@"height"] isKindOfClass:NSNumber.class] ? [canvas[@"height"] doubleValue] : 0;
    render.canvasSized = canvas != nil && width > 1 && height > 1;
    NSNumber *decoded = [facts[@"decodedTiles"] isKindOfClass:NSNumber.class] ? facts[@"decodedTiles"] : nil;
    render.tileDecoded = decoded != nil && decoded.unsignedIntegerValue > 0;
    // The edit-surface paint evidence is computed in the page against the
    // pre-entry baseline; the native side only consumes its boolean.
    render.editSurfacePainted = [facts[@"editSurfacePainted"] isKindOfClass:NSNumber.class]
        && [facts[@"editSurfacePainted"] boolValue];
    NSDictionary *pixels = [facts[@"pixels"] isKindOfClass:NSDictionary.class] ? facts[@"pixels"] : nil;
    NSNumber *distinct = [pixels[@"distinctColours"] isKindOfClass:NSNumber.class] ? pixels[@"distinctColours"] : nil;
    NSNumber *opaque = [pixels[@"opaque"] isKindOfClass:NSNumber.class] ? pixels[@"opaque"] : nil;
    NSNumber *samples = [pixels[@"samples"] isKindOfClass:NSNumber.class] ? pixels[@"samples"] : nil;
    // A painted surface has more than one colour and is at least an eighth
    // opaque; a cleared canvas fails both.
    render.pixelPainted = distinct != nil && samples != nil && opaque != nil
        && distinct.unsignedIntegerValue >= 2 && samples.unsignedIntegerValue > 0
        && opaque.unsignedIntegerValue * 8 >= samples.unsignedIntegerValue;
    return render;
}

- (void)reportFailureIfRequiredWithReason:(NSString *)reason {
    [_lastFacts setObject:reason forKey:@"failure"];
    if (!self.requiresVisibleRender) {
        // DOCX/XLSX behaviour is deliberately preserved: a document that shows
        // no decoded tile yet is left to the App's own open bound, and only the
        // diagnostics record the missing paint.
        [self.controller renderProbeDidFinishWithoutVisibleRender:self.diagnostics];
        return;
    }
    NSError *error = [NSError errorWithDomain:FloeOfficeNativeErrorDomain code:50 userInfo:@{
        NSLocalizedDescriptionKey:
            @"The presentation did not paint its document surface in time. Your editing copies were retained; retry or recover the document.",
        NSDebugDescriptionErrorKey: [self diagnosticsDescription],
    }];
    [self.controller renderProbeDidFail:error diagnostics:self.diagnostics];
}

- (NSString *)diagnosticsDescription {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:self.diagnostics options:0 error:nil];
    return encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : @"render diagnostics unavailable";
}
@end
// FLOE_RENDER_PROBE_END

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
/// Bounded probe for the first painted document surface. A presentation that
/// never paints must fail visibly instead of showing a blank ready editor.
@property (nonatomic, strong) FloeOfficeRenderProbe *renderProbe;
@property (nonatomic, readwrite, getter=hasVisibleRender) BOOL visibleRenderObserved;
@property (nonatomic, readwrite, copy, nullable) NSDictionary<NSString *, id> *renderDiagnostics;
/// Per-controller correlation identity for the bounded, content-free stage
/// logs (open, permission, edit entry, paint, save). Never document contents.
@property (nonatomic, copy, readonly) NSString *sessionID;
/// Monotonic open generation of this controller; every viewWillAppear open
/// request advances it. Stage logs carry it so a device trace can order the
/// open/permission/entry/paint sequence of one mounted session.
@property (nonatomic) NSUInteger openGeneration;
/// The guarded mobile edit entry is paint-gated for the file-based
/// presentation formats: it runs once the render probe observed the first
/// decoded document tile, never on the open-permission clock. The pending
/// entry is stored here until that trigger (or a settle path) fires.
@property (nonatomic) BOOL editEntryPending;
/// Set when the entry was parked; the render probe's bounded
/// extent-bootstrap fallback measures the wait from this stamp (main-queue
/// clock). Nil once the entry ran or settled.
@property (nonatomic, strong) NSDate *editEntryDeferredAt;
/// The guarded edit entry is running; a second trigger can never start a
/// concurrent engine switch.
@property (nonatomic) BOOL editEntryRunning;
/// The open-permission report settled exactly once for this open generation;
/// a late probe/entry completion can never report a second time.
@property (nonatomic) BOOL openPermissionReported;
/// The render probe observed at least one decoded document tile (any surface).
@property (nonatomic) BOOL firstPaintObserved;
/// The probe reached the format-specific edit-entry readiness at least once
/// (decoded tile for the file-based presentations, or full first-status
/// layer init — type, `docloaded`, sized canvas — for Word/Excel). An edit
/// intent parked after this runs immediately.
@property (nonatomic) BOOL editEntryReadinessObserved;
/// The render probe finished (ready or failed); a late deferral can never
/// park the edit entry behind a finished probe.
@property (nonatomic) BOOL renderProbeFinished;
/// Build 233 (R3): the editor's web content process terminated once; a second
/// notification can never report again.
@property (nonatomic) BOOL webContentProcessTerminated;
/// Content-free stage breadcrumb: bounded unified-log line plus the optional
/// App recorder block under this controller's session/generation, always with
/// a process memory sample. Never document text, paths or bytes.
- (void)floeStage:(NSString *)stage facts:(NSDictionary<NSString *, id> *)facts;
- (void)startRenderProbe;
- (void)enginePermissionDidUpdate:(BOOL)readOnly;
- (void)probeEnginePermissionWithAttempts:(NSUInteger)attempts
                               completion:(void (^)(BOOL known, BOOL readOnly))completion;
- (void)attemptEngineEditEntryWithAttempts:(NSUInteger)attempts
                                completion:(void (^)(BOOL readOnly, BOOL pendingPassword))completion;
- (void)attemptEngineEditEntryWithCompletion:(void (^)(BOOL readOnly, BOOL pendingPassword))completion;
/// Settles the open-permission report exactly once for this open generation.
- (void)reportOpenPermissionOnce:(BOOL)success readOnly:(BOOL)readOnly;
- (BOOL)hasSettledOpenPermission;
/// Arms the edit-surface paint baseline in the page immediately before the
/// paint-gated edit entry runs, stamped with this session and generation. The
/// visible-render ready can then only describe a paint that happened after
/// this entry; a missing helper or a page error leaves the evidence to the
/// probe's own last file-based baseline. Always calls the completion.
- (void)armEditSurfaceEvidenceWithCompletion:(void (^)(void))completion;
/// Defers the single guarded mobile edit entry until the render probe reaches
/// the format-specific readiness: a decoded document tile for the file-based
/// presentation formats, or full first-status layer init for Word/Excel. Runs
/// it at once when the readiness already passed, and settles without an entry
/// when the probe already finished without it.
- (void)deferEditEntryUntilFirstPaint;
/// Runs the guarded edit entry at most once and reports its real outcome.
- (void)runEditEntryAndReport;
/// Settles a still-pending edit entry without forcing an entry: the render
/// gate owns the bounded outcome. Exactly once.
- (void)settlePendingEditEntryWithoutEntry;
/// A sized, loaded document can bootstrap the guarded edit entry without
/// claiming that a decoded tile has painted. Readiness still needs a later
/// real first paint and edit-surface paint.
- (void)renderProbeDidProveExtentForEditEntry;
/// The parked paint-gated edit entry is still awaiting its trigger: pending,
/// not running, and the one-shot open-permission report has not settled.
- (BOOL)hasPendingDeferredEditEntry;
/// Seconds the parked edit entry has waited for its first-paint trigger
/// (0 when it was never parked or already ran/settled).
- (NSTimeInterval)deferredEditEntryParkedSeconds;
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
        _sessionID = [[NSUUID UUID] UUIDString];
        _saveReceipts = [FloeSaveReceiptJoiner new];
        _closeWaiters = [NSMutableArray array];
        // The Floe subclass calls the pinned upstream termination callback
        // through and then reports web-content death (see the recovery block).
        _editor = [[FloeOfficeDocumentViewController alloc] initWithNibName:nil bundle:nil];
        FloeOfficeDocument *document = [[FloeOfficeDocument alloc] initWithFileURL:file];
        document->readOnly = readOnly;
        document.floeEngineCopyDirectory = [directory URLByAppendingPathComponent:@"engine" isDirectory:YES];
        document.viewController = _editor;
        _editor.document = document;
        // Build 233 (R3): the editor (upstream WKNavigationDelegate) reports
        // web-content death through the recovery subclass; only this
        // controller's editor is observed, and the session's files are never
        // touched here.
        [NSNotificationCenter.defaultCenter addObserver:self
                                              selector:@selector(floeEditorWebContentTerminated:)
                                                  name:FloeOfficeWebContentTerminatedNotification
                                                object:_editor];
        __weak FloeOfficeNativeViewController *weakSelf = self;
        document.onOpened = ^(BOOL success) {
            FloeOfficeNativeViewController *host = weakSelf;
            if (!host) return;
            host.openSettled = YES;
            host.documentOpened = success;
            if (host.onWorkingCopyOpened) host.onWorkingCopyOpened(success);
            [host floeStage:@"open" facts:@{@"success": @(success),
                                           @"format": host.workingFileURL.pathExtension.lowercaseString ?: @"",
                                           @"readOnly": @(host.readOnly),
                                           @"appDocId": @(host.editor.document->appDocId)}];
            if (!success) {
                host.sessionIsReadOnly = YES;
                [host reportOpenPermissionOnce:NO readOnly:YES];
                [host beginCloseIfRequested];
                return;
            }
            // Readiness is not the open event: start the bounded probe that
            // requires a real painted surface (decoded document tile) for the
            // file-based presentation formats.
            [host startRenderProbe];
            if (host.readOnly) {
                // A preview is forced readonly by the mount grant and the lock
                // script, so the engine's backing permission cannot change the
                // session. Probing it only delayed readiness (seconds on a cold
                // engine, worse on compact layouts) and was the visible "open
                // spinner" on iPhone. Report immediately; the permission
                // observer still streams later engine state for diagnostics.
                host.sessionIsReadOnly = YES;
                [host reportOpenPermissionOnce:YES readOnly:YES];
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
                [probed floeStage:@"permission" facts:@{@"known": @(known),
                                                        @"readOnly": @(probed.sessionIsReadOnly)}];
                // An editable backing document that the mobile editor mounted in
                // its viewing-first UI is not a denied document. Every editable
                // format funnels through the single readiness-gated entry: the
                // render probe runs the engine's guarded
                // `map._switchToEditMode()` exactly once, at the real readiness
                // (a decoded tile for the file-based Impress/Draw startup, full
                // first-status layer init for Word/Excel), then reports the real
                // state. The page wrapper no longer owns an entry.
                if (known && !readOnly && !probed.readOnly) {
                    [probed deferEditEntryUntilFirstPaint];
                    return;
                }
                [probed reportOpenPermissionOnce:YES readOnly:probed.sessionIsReadOnly];
                [probed beginCloseIfRequested];
            }];
        };
        document.floeSaveCompletion = ^(BOOL success) {
            FloeOfficeNativeViewController *host = weakSelf;
            FloeOfficeLog(@"save-persistence", @{@"success": @(success),
                                                 @"sequence": @"unsequenced"});
            if (host.onWorkingCopySaved) host.onWorkingCopySaved(success);
        };
        document.floeSaveSequenceCompletion = ^(NSString *sequence, BOOL success) {
            FloeOfficeLog(@"save-receipt", @{@"sequence": sequence ?: @"",
                                             @"success": @(success)});
            [weakSelf.saveReceipts complete:sequence success:success];
        };
        document.floeSaveSequenceAssociation = ^(NSString *sequence, NSString *requestID) {
            FloeOfficeLog(@"save-association", @{@"sequence": sequence ?: @"",
                                                 @"request": requestID ?: @""});
            [weakSelf.saveReceipts associate:sequence requestID:requestID];
        };
        document.floeSaveRequestRejected = ^(NSString *requestID) {
            FloeOfficeLog(@"save-rejected", @{@"request": requestID ?: @""});
            [weakSelf.saveReceipts reject:requestID];
        };
        _editor.floeCloseCompletion = ^(BOOL success) {
            FloeOfficeNativeViewController *host = weakSelf;
            [host.saveReceipts cancel];
            host.closing = NO;
            host.closed = success;
            [host floeStage:@"close.ack" facts:@{@"success": @(success)}];
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
    __weak FloeOfficeNativeViewController *weakSaveHost = self;
    if (![self.saveReceipts begin:requestID completion:^(BOOL success) {
        FloeOfficeLog(@"save-completed", @{@"request": requestID ?: @"",
                                           @"session": weakSaveHost.sessionID ?: @"",
                                           @"success": @(success),
                                           @"visibleRender": @(weakSaveHost.visibleRenderObserved)});
        completion(success ? nil : OfficeError(8, @"Office could not complete this save. Your document copies have been retained."));
    }]) {
        completion(OfficeError(9, @"An Office save is already in progress."));
        return;
    }
    FloeOfficeLog(@"save-requested", @{@"request": requestID ?: @"",
                                       @"session": self.sessionID,
                                       @"visibleRender": @(self.visibleRenderObserved),
                                       @"uiEdit": @(self.sessionIsReadOnly == NO)});
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
// MARK: - Durable stage breadcrumbs
/// One content-free native stage. `FloeOfficeLog` keeps the bounded unified
/// log, the memory sample turns memory pressure into a trace fact, and the
/// App's recorder receives the same stage under its own session identity when
/// this App installed the block (pinned framework older than this source just
/// skips that half).
- (void)floeStage:(NSString *)stage facts:(NSDictionary<NSString *, id> *)facts {
    NSMutableDictionary<NSString *, id> *all = [NSMutableDictionary dictionaryWithDictionary:facts ?: @{}];
    [all addEntriesFromDictionary:FloeOfficeMemoryFacts()];
    FloeOfficeLog(stage, all);
    if (!self.onStageEvent) return;
    self.onStageEvent(@{@"stage": stage ?: @"",
                        @"session": self.sessionID ?: @"",
                        @"generation": @(self.openGeneration),
                        @"facts": all});
}
/// Build 233 (R3): the upstream navigation delegate reported that the editor's
/// web content process died. The engine session is unrecoverable; record the
/// stage, stop the probe so its deadline cannot double-report, keep every file
/// and let the App settle its bounded recoverable failure.
- (void)floeEditorWebContentTerminated:(NSNotification *)notification {
    NSAssert(NSThread.isMainThread, @"Office controllers are main-queue owned");
    if (notification.object != self.editor || self.closing || self.closed) return;
    if (self.webContentProcessTerminated) return;
    self.webContentProcessTerminated = YES;
    [self.renderProbe cancel];
    self.renderProbe = nil;
    self.renderProbeFinished = YES;
    [self floeStage:@"webcontent.terminated" facts:@{}];
    if (self.onWebContentProcessTerminated) self.onWebContentProcessTerminated();
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
// MARK: - Visible render readiness
- (void)startRenderProbe {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    if (self.renderProbe || self.closing || self.closed) return;
    FloeOfficeRenderProbe *probe = [[FloeOfficeRenderProbe alloc] initWithController:self
                                                                            readOnly:self.readOnly
                                                                         workingFile:self.workingFileURL];
    self.renderProbe = probe;
    [self floeStage:@"render-probe" facts:@{@"deadline": @(probe.deadline),
                                            @"requiresVisibleRender": @(probe.requiresVisibleRender)}];
    [probe start];
}
- (void)evaluateRenderFactsWithCompletion:(void (^)(NSDictionary<NSString *, id> * _Nullable,
                                                     NSError * _Nullable))completion {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    if (self.closing || self.closed || !self.editor.webView) {
        completion(nil, OfficeError(51, @"The editor surface is no longer available."));
        return;
    }
    [self.editor.webView evaluateJavaScript:FloeRenderProbeScript()
                          completionHandler:^(id value, NSError *error) {
        NSDictionary<NSString *, id> *facts = [value isKindOfClass:NSDictionary.class] ? value : nil;
        if (!facts || error)
            FloeOfficeLog(@"render-probe-error", error ? @{@"code": @(error.code)} : @{@"stage": @"no-facts"});
        completion(facts, error);
    }];
}
- (void)renderProbeDidObserveFirstPaint:(NSDictionary<NSString *, id> *)diagnostics {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    if (self.firstPaintObserved) return;
    self.firstPaintObserved = YES;
    [self floeStage:@"first-paint" facts:@{@"elapsed": [diagnostics[@"elapsed"] isKindOfClass:NSNumber.class]
                                              ? diagnostics[@"elapsed"] : @0}];
    // The single edit entry is run by the readiness hook the probe invokes
    // next; this report is paint evidence only.
}
- (void)renderProbeDidReachEditEntryReadiness {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    self.editEntryReadinessObserved = YES;
    // The single edit entry runs at most once, here, at the real readiness.
    if (self.editEntryPending) [self runEditEntryAndReport];
}
- (void)renderProbeDidProveExtentForEditEntry {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    if (self.closed || self.closing || !self.editEntryPending) return;
    [self runEditEntryAndReport];
}
- (void)renderProbeDidObserveVisibleRender:(NSDictionary<NSString *, id> *)diagnostics {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    self.visibleRenderObserved = YES;
    self.firstPaintObserved = YES;
    self.renderProbeFinished = YES;
    self.renderDiagnostics = diagnostics;
    [self floeStage:@"visible-render" facts:@{@"docType": diagnostics[@"docType"] ?: @"",
                                              @"entrySettled": @(self.openPermissionReported),
                                              @"editSurfacePainted": diagnostics[@"editSurfacePainted"] ?: @NO,
                                              @"editSurfaceArmed": diagnostics[@"editSurfaceArmed"] ?: @NO,
                                              @"newDecodes": diagnostics[@"editSurfaceNewDecodes"] ?: @0,
                                              @"changedSamples": diagnostics[@"editSurfaceChangedSamples"] ?: @0,
                                              @"elapsed": [diagnostics[@"elapsed"] isKindOfClass:NSNumber.class]
                                                  ? diagnostics[@"elapsed"] : @0}];
    if (self.onVisibleRenderReady)
        self.onVisibleRenderReady(diagnostics[@"docType"],
                                  [diagnostics[@"elapsed"] isKindOfClass:NSNumber.class]
                                      ? [diagnostics[@"elapsed"] doubleValue] : 0);
}
- (void)renderProbeDidFail:(NSError *)error diagnostics:(NSDictionary<NSString *, id> *)diagnostics {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    self.renderProbeFinished = YES;
    self.renderDiagnostics = diagnostics;
    // The bounded last probe state rides along: the App's durable trace then
    // names the furthest readiness class even when the probe never painted.
    NSMutableDictionary<NSString *, id> *facts =
        [FloeRenderProbeDiagnosticFacts(diagnostics) mutableCopy];
    facts[@"failure"] = diagnostics[@"failure"] ?: @"unknown";
    [self floeStage:@"visible-render-failed" facts:facts];
    // A still-pending edit entry settles here without forcing an entry: the
    // engine never proved a paint, and the render gate owns the bounded
    // outcome. The report still settles exactly once.
    [self settlePendingEditEntryWithoutEntry];
    if (self.onVisibleRenderFailed) self.onVisibleRenderFailed(error);
}
- (void)renderProbeDidFinishWithoutVisibleRender:(NSDictionary<NSString *, id> *)diagnostics {
    NSAssert(NSThread.isMainThread, @"Office render probes are main-queue owned");
    self.renderProbeFinished = YES;
    // A still-parked entry (an editable Word/Excel session whose layer never
    // reached its first status) settles here without forcing an entry: the
    // bounded outcome is the App's, and the permission report must not hang
    // behind the entry's budget. Exactly once.
    [self settlePendingEditEntryWithoutEntry];
    self.renderDiagnostics = diagnostics;
    [self floeStage:@"visible-render-unobserved" facts:FloeRenderProbeDiagnosticFacts(diagnostics)];
}
// Retries until the editor has created its map. app.file.readOnly is the
// backing permission; _permission/isReadOnlyMode() alone is the mobile UI mode.
// The budget covers a cold page load of the multi-megabyte editor bundle plus
// the close-then-reopen document switch on a device: giving up earlier misread
// a slow editable open as a denied document and bounced the editor to preview.
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
        if (!host) {
            completion(NO, YES);
            return;
        }
        NSDictionary *result = [value isKindOfClass:NSDictionary.class] ? value : nil;
        NSNumber *backendReadOnly = [result[@"backendReadOnly"] isKindOfClass:NSNumber.class]
            ? result[@"backendReadOnly"] : nil;
        if (backendReadOnly) {
            completion(YES, backendReadOnly.boolValue);
            return;
        }
        if (attempts >= 150 || error) {
            completion(NO, host.sessionIsReadOnly);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [host probeEnginePermissionWithAttempts:attempts + 1 completion:completion];
        });
    }];
}
// Follows the engine's normal mobile edit entry. A page that is still loading
// (or a context momentarily busy during the document switch) returns
// `not-ready` or no result at all; that transient state is retried, bounded,
// instead of being misread as a denied document. Only a definitive engine
// answer reports.
- (void)attemptEngineEditEntryWithAttempts:(NSUInteger)attempts
                                completion:(void (^)(BOOL readOnly, BOOL pendingPassword))completion {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    if (self.closing || self.closed || !self.editor.webView) {
        completion(YES, NO);
        return;
    }
    __weak FloeOfficeNativeViewController *weakSelf = self;
    [self.editor.webView evaluateJavaScript:FloeEngineEditEntryScript()
                          completionHandler:^(id value, NSError *error) {
        FloeOfficeNativeViewController *host = weakSelf;
        if (!host) {
            completion(YES, NO);
            return;
        }
        NSDictionary *result = [value isKindOfClass:NSDictionary.class] ? value : nil;
        NSString *reason = [result[@"reason"] isKindOfClass:NSString.class] ? result[@"reason"] : nil;
        BOOL transient = !result || [reason isEqualToString:@"not-ready"] || [reason isEqualToString:@"error"];
        if (transient && attempts < 24) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [host attemptEngineEditEntryWithAttempts:attempts + 1 completion:completion];
            });
            return;
        }
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
- (void)attemptEngineEditEntryWithCompletion:(void (^)(BOOL readOnly, BOOL pendingPassword))completion {
    [self attemptEngineEditEntryWithAttempts:0 completion:completion];
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
/// Settles the open-permission report exactly once for this open generation.
/// Every path (preview, non-deferred entry, paint-gated entry, probe failure,
/// close) funnels through here, so a late probe or entry completion can never
/// report a second permission over an already-settled one.
- (void)reportOpenPermissionOnce:(BOOL)success readOnly:(BOOL)readOnly {
    NSAssert(NSThread.isMainThread, @"Office open reports are main-queue owned");
    if (self.openPermissionReported) return;
    self.openPermissionReported = YES;
    if (self.onWorkingCopyOpenedWithPermission) self.onWorkingCopyOpenedWithPermission(success, readOnly);
}
- (BOOL)hasSettledOpenPermission {
    NSAssert(NSThread.isMainThread, @"Office open reports are main-queue owned");
    return self.openPermissionReported;
}
/// Arms the edit-surface paint baseline in the page immediately before the
/// paint-gated edit entry. The baseline is the frame that is on screen at the
/// entry (the last file-based preview paint), stamped with the session id and
/// open generation, so the probe's visible-render evidence can only describe a
/// paint that happened after this entry. Always calls the completion, even
/// when the helper is missing or the page errors: the probe's own last
/// file-based baseline still covers that case, and the guarded entry must not
/// be blocked forever by an evidence-only step.
- (void)armEditSurfaceEvidenceWithCompletion:(void (^)(void))completion {
    NSAssert(NSThread.isMainThread, @"Office edit-surface evidence is main-queue owned");
    if (!completion) return;
    if (self.closed || self.closing || !self.editor.webView) { completion(); return; }
    NSString *token = [NSString stringWithFormat:@"%@:%lu", self.sessionID, (unsigned long)self.openGeneration];
    __weak FloeOfficeNativeViewController *weakSelf = self;
    [self.editor.webView evaluateJavaScript:FloeEditSurfaceArmScript(token)
                          completionHandler:^(id value, NSError *error) {
        FloeOfficeNativeViewController *host = weakSelf;
        BOOL armed = !error && [value isKindOfClass:NSNumber.class] && [value boolValue];
        [host floeStage:@"edit-surface-armed" facts:@{@"armed": @(armed)}];
        completion();
    }];
}
/// Defers the single guarded mobile edit entry until the render probe reaches
/// the format-specific readiness. The file-based presentation startup needs a
/// decoded document tile: switching the layout on the open-permission clock
/// built the part-based edit surface on an empty document extent, which never
/// painted on device. Word/Excel need the engine's document layer, because
/// the engine's real `_enterEditMode` dereferences `this._docLayer`.
- (void)deferEditEntryUntilFirstPaint {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    if (self.editEntryPending || self.editEntryRunning || self.openPermissionReported) return;
    // The probe already passed the format-specific readiness: a decoded tile
    // for the file-based presentations, or full first-status layer init for
    // Word/Excel. Run the entry at once instead of waiting for another probe.
    if (self.firstPaintObserved || self.editEntryReadinessObserved) {
        [self runEditEntryAndReport]; return;
    }
    if (self.renderProbeFinished) {
        // The probe already settled without a paint: report the real backing
        // permission without forcing an entry; the render gate owns the
        // bounded outcome and a later entry could only race a dead surface.
        [self reportOpenPermissionOnce:YES readOnly:self.sessionIsReadOnly];
        [self beginCloseIfRequested];
        return;
    }
    self.editEntryPending = YES;
    self.editEntryDeferredAt = [NSDate date];
    [self floeStage:@"edit-entry-deferred" facts:@{}];
}
/// Runs the guarded edit entry at most once and reports its real outcome.
/// A close that wins the race owns the outcome; the entry result is dropped.
/// The file-based presentation formats arm the edit-surface paint baseline
/// first: every later paint the probe reports is then provably newer than the
/// entry's own frame, never the preview tiles the engine's shared tile map
/// keeps across the layout switch. Word/Excel keep their direct timing.
- (void)runEditEntryAndReport {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    if (self.editEntryRunning || self.openPermissionReported) return;
    self.editEntryPending = NO;
    self.editEntryDeferredAt = nil;
    self.editEntryRunning = YES;
    [self floeStage:@"edit-entry" facts:@{}];
    __weak FloeOfficeNativeViewController *weakSelf = self;
    void (^performEntry)(void) = ^{
        FloeOfficeNativeViewController *host = weakSelf;
        if (!host || host.closed || host.closing) return;
        [host attemptEngineEditEntryWithCompletion:^(BOOL stillReadOnly, BOOL pendingPassword) {
            FloeOfficeNativeViewController *entered = weakSelf;
            if (!entered) return;
            entered.editEntryRunning = NO;
            if (entered.closed || entered.closing) return;
            entered.sessionIsReadOnly = stillReadOnly;
            [entered floeStage:@"edit-entry-result" facts:@{@"readOnly": @(stillReadOnly),
                                                            @"pendingPassword": @(pendingPassword)}];
            [entered reportOpenPermissionOnce:YES readOnly:stillReadOnly];
            [entered beginCloseIfRequested];
        }];
    };
    if (FloeDocumentRequiresVisibleRender(self.workingFileURL.pathExtension)) {
        [self armEditSurfaceEvidenceWithCompletion:performEntry];
    } else {
        performEntry();
    }
}
/// Settles a still-pending edit entry without forcing an entry: the engine
/// never proved a paint, so switching the layout could only build the edit
/// surface on an empty extent. The backing permission is reported once and
/// the render gate owns the bounded outcome.
- (void)settlePendingEditEntryWithoutEntry {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    if (!self.editEntryPending) return;
    self.editEntryPending = NO;
    self.editEntryDeferredAt = nil;
    if (self.closed || self.closing) return;
    [self floeStage:@"edit-entry-settled-without-entry" facts:@{@"readOnly": @(self.sessionIsReadOnly)}];
    [self reportOpenPermissionOnce:YES readOnly:self.sessionIsReadOnly];
    [self beginCloseIfRequested];
}
- (BOOL)hasPendingDeferredEditEntry {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    return self.editEntryPending && !self.editEntryRunning && !self.openPermissionReported;
}
- (BOOL)isDeferredEditEntryRunning { return self.editEntryRunning; }
- (BOOL)hasReportedOpenPermission { return self.openPermissionReported; }
- (NSString *)renderProbeSessionID { return self.sessionID; }
- (NSUInteger)renderProbeOpenGeneration { return self.openGeneration; }
- (NSTimeInterval)deferredEditEntryParkedSeconds {
    NSAssert(NSThread.isMainThread, @"Office edit entry is main-queue owned");
    return self.editEntryDeferredAt ? -[self.editEntryDeferredAt timeIntervalSinceNow] : 0;
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
    // A close owns the session's outcome from here: a paint-gated edit entry
    // still waiting for its trigger is dropped, never run against a surface
    // that is going away, and its report is left to the close path.
    self.editEntryPending = NO;
    // A closed session can never paint again; stop the render probe so its
    // deadline cannot report a failure or a ready signal for a dead surface.
    [self.renderProbe cancel];
    self.renderProbe = nil;
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
    [self floeStage:@"close.bye" facts:@{}];
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
    // later close must go through the engine's acknowledgement path. The
    // document itself opens only once per controller (the upstream guard on
    // fakeClientFd), so the open generation advances on the first request.
    if (!self.openRequested) {
        self.openRequested = YES;
        self.openGeneration += 1;
    }
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self addChildViewController:self.editor];
    UIView *content = self.editor.view;
    // Add before viewWillAppear opens the document. At document start the
    // listener precedes the bundled editor's DOMContentLoaded callbacks.
    WKUserContentController *contentController = self.editor.webView.configuration.userContentController;
    // The injected scripts need the host's own mount grant: the engine cannot
    // infer it from a handshake that omits `permission` for editable sessions,
    // and a missing fact must never be read as an editing grant.
    [contentController addUserScript:[[WKUserScript alloc]
        initWithSource:FloeSessionFactsScript(self.readOnly, self.workingFileURL.lastPathComponent)
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
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
