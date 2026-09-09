// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
// Runtime startup adapted from the pinned Collabora Mobile AppDelegate (MPL-2.0).
#import "config.h"
#import "FloeOfficeNative.h"
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
    NSURL *profile = [root URLByAppendingPathComponent:@"27b21dc1/profile" isDirectory:YES];
    NSURL *cache = [root URLByAppendingPathComponent:@"27b21dc1/cache" isDirectory:YES];
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
@property (nonatomic, copy, readwrite) NSURL *workingFileURL;
@property DocumentViewController *editor;
@property (nonatomic, strong) FloeSaveReceiptJoiner *saveReceipts;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL closed;
@property (nonatomic) BOOL insertingAttachment;
@property (nonatomic, strong) NSMutableArray *closeWaiters;
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
            if (host.onWorkingCopyOpened) host.onWorkingCopyOpened(success);
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
            NSArray *waiters = [host.closeWaiters copy];
            [host.closeWaiters removeAllObjects];
            for (void (^completion)(NSError *) in waiters)
                completion(success ? nil : OfficeError(10, @"Office could not close this document. Your document copies have been retained."));
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
- (void)cancelPendingSave {
    [self.saveReceipts cancel];
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
    [self.closeWaiters addObject:[completion copy]];
    if (self.closing) return;
    self.closing = YES;
    [self.saveReceipts cancel];
    self.editor.view.userInteractionEnabled = NO;
    [self.editor bye];
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
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self addChildViewController:self.editor];
    UIView *content = self.editor.view;
    if (self.readOnly) {
        // Add before viewWillAppear opens the document. At document start the
        // listener precedes the bundled editor's DOMContentLoaded callbacks.
        WKUserScript *script = [[WKUserScript alloc] initWithSource:FloeReadOnlyScript()
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
        [self.editor.webView.configuration.userContentController addUserScript:script];
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
