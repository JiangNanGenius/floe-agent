#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Bounded Objective-C shims for private XCTest/SpringBoard/LSApplication
/// APIs that the pinned iCTRL runner uses.
///
/// Every function is runtime-guarded with `NSClassFromString` and
/// `respondsToSelector:`; callers must treat a false result as "capability
/// unavailable", never as a successful action. Nothing here is linked from the
/// host or from BridgeCore; only the BridgeTests bundle imports this header.

/// Whether `-[XCPointerEventPath typeText:atOffset:typingSpeed:shouldRedact:]`
/// is present. When it is absent, text input is not advertised rather than
/// falling back to a path that may log raw text.
FOUNDATION_EXPORT BOOL BRRedactedTypingAvailable(void);

/// Synthesizes text through the private text-input event path with
/// `shouldRedact:YES`. Returns NO when the class/selector is unavailable or
/// the event record reports an error. No text is logged.
FOUNDATION_EXPORT BOOL BRTypeTextRedacted(NSString *text,
                                          NSError * _Nullable * _Nullable error);

/// Whether the private synthesized multi-point drag path is available.
FOUNDATION_EXPORT BOOL BRContinuousDragAvailable(void);

/// Synthesizes one continuous single-finger drag through `points`
/// (`NSValue`-wrapped `CGPoint`) over `duration` seconds.
FOUNDATION_EXPORT BOOL BRContinuousDrag(NSArray<NSValue *> *points,
                                        NSTimeInterval duration,
                                        NSError * _Nullable * _Nullable error);

/// Whether `XCUIDevice` exposes the private lock button.
FOUNDATION_EXPORT BOOL BRLockButtonAvailable(void);
FOUNDATION_EXPORT BOOL BRPressLockButton(void);

/// SpringBoard lock-state notification (no XCTest call).
/// `BRLockStateAvailable` means the notify token was registered; it does not
/// prove the current value was read. `BRLockStateKnown` is true only after a
/// successful `notify_get_state`. Callers must treat unavailable/unknown as
/// locked, never as unlocked.
FOUNDATION_EXPORT BOOL BRLockStateAvailable(void);
FOUNDATION_EXPORT BOOL BRLockStateKnown(void);
/// 0 = unlocked, 1 = locked, 2 = unknown/unavailable. Never treat 2 as
/// unlocked.
FOUNDATION_EXPORT NSInteger BRLockRawState(void);
FOUNDATION_EXPORT BOOL BRIsLocked(void);

/// Resolves the frontmost app bundle id through XCTest's accessibility
/// interface. Returns nil when the private path is unavailable.
FOUNDATION_EXPORT BOOL BRForegroundHelperAvailable(void);
FOUNDATION_EXPORT NSString * _Nullable BRCurrentForegroundBundleID(void);

/// Installed-app enumeration through LSApplicationWorkspace.
FOUNDATION_EXPORT BOOL BRInstalledAppsAvailable(void);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> * _Nullable
BRInstalledApps(BOOL userOnly);

/// Opens a URL / bundle id through XCTRunnerDaemonSession or
/// LSApplicationWorkspace. Returns the actual API result.
FOUNDATION_EXPORT BOOL BROpenURLAvailable(void);
FOUNDATION_EXPORT BOOL BROpenURL(NSURL *url);
FOUNDATION_EXPORT BOOL BROpenBundleIdentifier(NSString *bundleIdentifier);

/// Safe `XCUIApplication(bundleIdentifier:).state` read. Returns 0..4
/// (XCUIApplicationState raw) or 0 when unavailable.
FOUNDATION_EXPORT BOOL BRAppStateAvailable(void);
FOUNDATION_EXPORT NSInteger BRAppStateForBundleIdentifier(NSString *bundleIdentifier);

NS_ASSUME_NONNULL_END
