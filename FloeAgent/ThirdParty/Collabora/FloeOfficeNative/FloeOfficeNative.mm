// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
// Runtime startup adapted from the pinned Collabora Mobile AppDelegate (MPL-2.0).
#import "config.h"
#import "FloeOfficeNative.h"
#define LIBO_INTERNAL_ONLY
#import <COKit/COKitInit.h>
#include <comphelper/kit.hxx>
#include <i18nlangtag/languagetag.hxx>
#include <common/LangUtil.hpp>
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

NSErrorDomain const FloeOfficeNativeErrorDomain = @"org.floeagent.office.native";
NSNotificationName const FloeOfficeNativeRuntimeDidFailNotification = @"FloeOfficeNativeRuntimeDidFail";
// The framework excludes upstream AppDelegate.mm, which normally owns these.
NSString *app_locale;
NSString *app_text_direction;

static NSError *OfficeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:FloeOfficeNativeErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: description}];
}

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
    for (NSString *name in @[@"cool.html", @"rc", @"ICU.dat"]) {
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
        app_locale = NSLocale.preferredLanguages.firstObject ?: @"en-US";
        app_text_direction = LangUtil::isRtlLanguage(std::string(app_locale.UTF8String)) ? @"rtl" : @"";
        lo_kit = cok_init_2(nullptr, profile.absoluteString.UTF8String);
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
                std::string cacheOption("--override=cache_files.path=");
                cacheOption += cache.path.UTF8String;
                char *arguments[] = {executable.data(), cacheOption.data(), nullptr};
                // Keep native server lifetime process-wide. Upstream shutdown
                // destructors are not qualified for restarting inside another app.
                auto server = new COOLWSD();
                server->run(2, arguments);
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

@interface FloeOfficeNativeViewController ()
@property (nonatomic, readwrite, getter=isReadOnly) BOOL readOnly;
@property (nonatomic, copy, readwrite) NSURL *workingFileURL;
@property DocumentViewController *editor;
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
        _editor.floeCloseCompletion = ^(BOOL success) {
            FloeOfficeNativeViewController *host = weakSelf;
            if (host.onClosed) host.onClosed(success);
        };
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self addChildViewController:self.editor];
    UIView *content = self.editor.view;
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
