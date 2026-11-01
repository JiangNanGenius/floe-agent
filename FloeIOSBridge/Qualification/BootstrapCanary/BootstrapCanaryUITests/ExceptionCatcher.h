#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and converts an Objective-C exception into an NSError.
/// Returns YES when the block completed without raising.
FOUNDATION_EXPORT BOOL FBCatchException(void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
