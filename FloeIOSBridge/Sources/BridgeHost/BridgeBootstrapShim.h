#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BRBootstrapResult) {
    BRBootstrapResultOK = 0,
    BRBootstrapResultAlreadyStarted = 1,
    BRBootstrapResultInvalidBundle = 2,
    BRBootstrapResultNoXCTestRuntime = 3,
    BRBootstrapResultMissingEntryPoint = 4,
    BRBootstrapResultEntryContextFailure = 5,
    BRBootstrapResultCancelled = 6,
};

/// Loads the mounted DDI XCTest runtime, sets XCTestBundlePath and enters
/// _XCTestMain(nil) exactly once from a main-run-loop block. The entry must run
/// on the main thread, but it must not occupy a long-lived main dispatch-queue
/// work item: _XCTestMain does not return while the driver is alive, and a held
/// main-queue item would starve every later MainActor/main-queue job. The
/// cancellation block is evaluated on the main thread immediately before the
/// irreversible call; a stale generation prevents a late initialization after
/// Stop. The host does not link XCTest.
FOUNDATION_EXPORT BRBootstrapResult BRStartBootstrap(
    NSString *xctestPath,
    NSString *logPath,
    uint64_t generation,
    BOOL (^ _Nullable cancellationCheck)(uint64_t generation));

FOUNDATION_EXPORT NSString * _Nullable BRLastBootstrapError(void);

/// Returns YES only if the mounted DDI exposes a readable XCTest framework.
FOUNDATION_EXPORT BOOL BRProbeDDI(NSString *logPath);

FOUNDATION_EXPORT void BRAppendLog(NSString *logPath, NSString *message);

NS_ASSUME_NONNULL_END
