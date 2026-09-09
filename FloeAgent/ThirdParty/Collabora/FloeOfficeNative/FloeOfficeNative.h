// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const FloeOfficeNativeErrorDomain;
FOUNDATION_EXPORT NSNotificationName const FloeOfficeNativeRuntimeDidFailNotification;

/// Process-wide native engine. All completions and controller APIs use the main queue.
/// The app must copy the qualified editor and engine resources into its main bundle.
@interface FloeOfficeNativeRuntime : NSObject
@property (class, nonatomic, readonly) FloeOfficeNativeRuntime *sharedRuntime NS_SWIFT_NAME(shared);
@property (nonatomic, readonly, getter=isReady) BOOL ready;
- (void)prepareWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Hosts the actual Collabora mobile document UI, never a field-based substitute.
/// workingFileURL must belong to a persistent Floe document session. The controller
/// does not open, overwrite, delete or release the user's original file.
@interface FloeOfficeNativeViewController : UIViewController
@property (nonatomic, readonly, getter=isReadOnly) BOOL readOnly;
@property (nonatomic, copy, readonly) NSURL *workingFileURL;
/// UIDocument opened its private copy; this is not a rendered-document-ready event.
@property (nonatomic, copy, nullable) void (^onWorkingCopyOpened)(BOOL success);
/// Raw engine/autosave persistence event. NOT an explicit-save acknowledgement,
/// original-file writeback result, or layout verification.
@property (nonatomic, copy, nullable) void (^onWorkingCopySaved)(BOOL success);
/// Native close completed. The caller still owns writeback and recovery retention.
@property (nonatomic, copy, nullable) void (^onClosed)(BOOL success);
/// Force a normal engine save and wait for this request's native working-file
/// persistence result. The caller still coordinates original-file writeback.
/// Only one explicit request is admitted at a time; no autosave can complete it.
- (void)saveWorkingCopyWithCompletion:(void (^)(NSError * _Nullable error))completion;
/// Stop waiting for an explicit save. An already running engine save may still
/// finish in its private files; this never cancels or commits the original file.
- (void)cancelPendingSave;
/// Insert a file as an embedded Word attachment at the current cursor. Copies
/// the authorized input into this private session; completion is insertion,
/// not original-file save. Other document types are rejected until implemented.
- (void)insertAttachmentFromFileURL:(NSURL *)fileURL completion:(void (^)(NSError * _Nullable error))completion;
/// Settle the native document before releasing its view. This does not request
/// an engine save or remove any files; save first when committing user edits.
- (void)closeWorkingCopyWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (nullable instancetype)initWithWorkingFileURL:(NSURL *)workingFileURL
                             sessionDirectory:(NSURL *)sessionDirectory
                                     readOnly:(BOOL)readOnly
                                        error:(NSError * _Nullable * _Nullable)error;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
