// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const FloeOfficeNativeErrorDomain;
FOUNDATION_EXPORT NSNotificationName const FloeOfficeNativeRuntimeDidFailNotification;

@interface FloeOfficeAttachmentInfo : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) unsigned long long byteCount;
@end

/// Process-wide native engine. All completions and controller APIs use the main queue.
/// The app must copy the qualified editor and engine resources into its main bundle.
///
/// Failure handling: a failed engine is terminal for the process lifetime. An
/// in-process restart is deliberately not offered — engine initialization and
/// the kit/server workers are not re-entrant by qualification, and a timed-out
/// or unresponsive engine is not proof that its workers exited. Document
/// working copies and recovery versions are retained by the App layer, and the
/// user recovers by restarting the app.
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
/// Engine-reported backing permission of this session. This is not the App's
/// requested grant and not the current mobile viewing/editing UI mode: the
/// mobile editor starts editable documents in its viewing UI, so UI mode alone
/// must never be treated as a denied document. Updated after open and whenever
/// the editor reports a permission change.
@property (nonatomic, readonly) BOOL sessionIsReadOnly;
/// Open completion that also reports the engine's backing permission. The
/// original onWorkingCopyOpened remains for callers that only need success.
@property (nonatomic, copy, nullable) void (^onWorkingCopyOpenedWithPermission)(BOOL success, BOOL readOnly);
/// Fired after open when the engine-reported backing permission changes.
@property (nonatomic, copy, nullable) void (^onEnginePermissionChanged)(BOOL readOnly);
/// Raw engine/autosave persistence event. NOT an explicit-save acknowledgement,
/// original-file writeback result, or layout verification.
@property (nonatomic, copy, nullable) void (^onWorkingCopySaved)(BOOL success);
/// First evidence that the engine actually painted the document surface for
/// this session: at least one decoded document tile and a non-empty document
/// canvas, observed through the editor's own tile pipeline. The UIDocument
/// open, the engine backing permission, a save receipt and `docloaded` are
/// explicitly NOT visible-render evidence. `docType` is the engine's own type
/// string (text/spreadsheet/presentation/drawing) and `elapsed` is seconds
/// since the working copy open settled. Fired at most once per session.
@property (nonatomic, copy, nullable) void (^onVisibleRenderReady)(NSString * _Nullable docType, NSTimeInterval elapsed);
/// Bounded failure: the session produced no visible-render evidence before the
/// host deadline. The working copy is retained; the caller must fail visibly
/// with retry/recovery instead of presenting a blank ready editor. Fired at
/// most once per session and never for a session the host read-only script
/// intentionally renders without document tiles.
@property (nonatomic, copy, nullable) void (^onVisibleRenderFailed)(NSError *error);
/// Format/type/open/render/save diagnostics for logging and qualification.
/// Contains only engine state and counters, never document contents.
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *renderDiagnostics;
/// Native close completed. The caller still owns writeback and recovery retention.
@property (nonatomic, copy, nullable) void (^onClosed)(BOOL success);
/// Force a normal engine save and wait for this request's native working-file
/// persistence result. The caller still coordinates original-file writeback.
/// Only one explicit request is admitted at a time; no autosave can complete it.
- (void)saveWorkingCopyWithCompletion:(void (^)(NSError * _Nullable error))completion;
/// Export to a new private file. Save the working copy first to flush pending editor input.
/// Completion confirms a nonempty file; the client additionally validates its format.
- (void)exportDocumentWithFormat:(NSString *)format completion:(void (^)(NSURL * _Nullable fileURL, NSError * _Nullable error))completion;
/// Start the engine's actual presentation surface; completion acknowledges dispatch only.
- (void)startPresentationWithCompletion:(void (^)(NSError * _Nullable error))completion;
/// Uses Office's editable vector freehand shape tool, so annotations follow normal save/export.
- (void)setDrawingMode:(NSNumber *)enabled completion:(void (^)(NSError * _Nullable error))completion;
/// Stop waiting for an explicit save. An already running engine save may still
/// finish in its private files; this never cancels or commits the original file.
- (void)cancelPendingSave;
/// Follow the engine's normal guarded mobile edit entry for a session the host
/// opened for editing. The engine keeps its own format/password/lock checks.
/// A controller mounted readOnly never relaxes that grant. The completion's
/// readOnly is the engine state after the attempt; error code 42 means the
/// engine is waiting for the edit password, not that the document was denied.
- (void)enterEditModeWithCompletion:(void (^)(BOOL readOnly, NSError * _Nullable error))completion;
/// Insert an attachment at the Word cursor, selected Excel cell, or centre of
/// the active PowerPoint slide. Copies
/// the authorized input into this private session; completion is insertion,
/// not original-file save.
- (void)insertAttachmentFromFileURL:(NSURL *)fileURL completion:(void (^)(NSError * _Nullable error))completion;
/// Enumerates live Office Package attachments. Other embedded Office objects are
/// not represented as original-file attachments. Does not modify the document.
- (void)listAttachmentsWithCompletion:(void (^)(NSArray<FloeOfficeAttachmentInfo *> * _Nullable attachments, NSError * _Nullable error))completion;
/// Extract the current embedded bytes into a private export copy. Never opens
/// or executes the attachment; the caller chooses preview or a destination.
- (void)exportAttachmentWithIdentifier:(NSString *)identifier completion:(void (^)(NSURL * _Nullable fileURL, NSError * _Nullable error))completion;
/// Settle the native document before releasing its view. This does not request
/// an engine save or remove any files; save first when committing user edits.
/// When the document open is still in flight the close is ordered behind it:
/// a `bye` issued before the open settles is dropped upstream and its
/// acknowledgement would never arrive.
- (void)closeWorkingCopyWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (nullable instancetype)initWithWorkingFileURL:(NSURL *)workingFileURL
                             sessionDirectory:(NSURL *)sessionDirectory
                                     readOnly:(BOOL)readOnly
                                        error:(NSError * _Nullable * _Nullable)error;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
