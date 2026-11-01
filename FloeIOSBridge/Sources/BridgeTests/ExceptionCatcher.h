#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and converts an Objective-C exception into an NSError.
FOUNDATION_EXPORT BOOL BRCatchException(void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
