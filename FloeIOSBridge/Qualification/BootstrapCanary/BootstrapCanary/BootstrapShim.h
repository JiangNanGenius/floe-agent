#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FBCBootstrapResult) {
    FBCBootstrapResultOK = 0,
    FBCBootstrapResultAlreadyStarted = 1,
    FBCBootstrapResultInvalidBundle = 2,
    FBCBootstrapResultNoXCTestRuntime = 3,
    FBCBootstrapResultMissingEntryPoint = 4,
    FBCBootstrapResultEntryContextFailure = 5,
};

/// Probes the mounted Developer Disk Image for the DDI XCTest runtime.
/// The returned dictionary is JSON-serializable and is also written to the log.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *FBCProbeDDI(NSString *logPath);

/// Loads the DDI XCTest runtime, sets XCTestBundlePath, and enqueues
/// _XCTestMain(nil) exactly once on the main queue after the host UI is up.
/// The XCTest/XCUI driver requires main-thread initialization; bundle
/// validation, DDI probing, dlopen and environment setup stay off-main.
/// Returns immediately after the main-queue dispatch is enqueued.
FOUNDATION_EXPORT FBCBootstrapResult FBCStartBootstrap(NSString *xctestPath, NSString *logPath);

/// Human-readable reason for the last failed FBCStartBootstrap call.
FOUNDATION_EXPORT NSString * _Nullable FBCLastBootstrapError(void);

/// Appends one line to the canary log with an ISO-8601 timestamp. Serialized.
FOUNDATION_EXPORT void FBCAppendLog(NSString *logPath, NSString *message);

NS_ASSUME_NONNULL_END
