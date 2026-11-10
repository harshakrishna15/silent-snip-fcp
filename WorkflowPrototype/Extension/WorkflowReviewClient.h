#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_OPTIONS(NSUInteger, SSReviewBoundaryEdit) {
    SSReviewBoundaryStartEarlier = 1, SSReviewBoundaryStartLater = 2,
    SSReviewBoundaryEndEarlier = 4, SSReviewBoundaryEndLater = 8, SSReviewBoundaryReset = 16
};

/// A control-only client for the existing Silent Snip worker. UUIDs are their
/// canonical string representations. No media, XML, or Final Cut preferences
/// are opened by this client.
@interface SSWorkflowReviewClient : NSObject
@property (nonatomic, readonly, copy, nullable) NSString *requestID;
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, readonly) BOOL canApply;
@property (nonatomic, readonly) BOOL canChangeSelection;
@property (nonatomic, readonly) BOOL canCancel;
@property (nonatomic, readonly) BOOL canUpdateCuts;
/// Capability advertised only by workers that verify automatic snapshot edits.
/// Availability remains visible while an update is in flight so the owner can
/// retain/coalesce later edits without dispatching overlapping commands.
@property (nonatomic, readonly) BOOL automaticPreviewAvailable;
@property (nonatomic, readonly) BOOL updatingCuts;
@property (nonatomic, readonly) BOOL canHighlight;
@property (nonatomic, readonly) BOOL supportsNativeNavigation;
/// Editing invalidates Apply/navigation and hides the stale timeline overlay,
/// retaining reusable measurements for an eligible snapshot refresh. New edits
/// during a refresh remain dirty until their own acknowledged result arrives.
- (void)markSettingsDirty;
/// Sends only to the already-running review while Final Cut Pro is frontmost.
/// The owner exposes edit in its natural settings group and coalesces drafts;
/// this method never activates the host, launches a helper, or exports audio.
- (BOOL)automaticallyUpdateCutsWithSettings:(NSDictionary *)settings edit:(NSString *)edit;
/// Retained for compatibility with earlier explicitly invoked frontends.
- (BOOL)updateCutsWithSettings:(NSDictionary *)settings gesture:(NSString *)gesture;
- (BOOL)highlightCut:(NSString *)cutID;
/// The move block is called at most once, with the current worker's permit.
- (BOOL)navigateCut:(NSString *)cutID gesture:(NSString *)gesture move:(BOOL (^)(NSDictionary *permit))move;
/// Explicit read-only recovery; accepts only Silent Snip.fcpxml. This client
/// never gains Apply authority from an adopted verification result.
- (BOOL)verifyExistingResultURL:(NSURL *)resultURL
                   libraryURL:(NSURL *)libraryURL
                   projectUID:(NSString *)projectUID
                  projectName:(NSString *)projectName
                      gesture:(NSString *)gesture;

- (instancetype)initWithViewID:(NSString *)viewID
                       update:(void (^)(NSDictionary *response))update
                      failure:(void (^)(NSString *message))failure NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Settings keys match the M1 controls: thresholdDBFS,
/// minimumSilenceDuration, beforeSpeechPadding, afterSpeechPadding, outputMode.
/// The Analyze gesture must already be exposed by the native button identifier.
/// YES means a validated connection attempt began; launch/capability failures
/// arrive through failure. Observers attach before dispatch. Unreadable helper
/// metadata requires a fresh availability reply before the analysis URL.
/// Explicit Analyze/Apply/Retry actions wait for the exact Final Cut process
/// to become frontmost. Apply/Retry activation failure preserves the review and
/// reports a recoverable message through update, without sending a command.
- (BOOL)startWithLibraryURL:(NSURL *)libraryURL
                projectUID:(NSString *)projectUID
               projectName:(NSString *)projectName
                  settings:(NSDictionary *)settings
                   gesture:(NSString *)gesture;
- (BOOL)sendApplyWithGesture:(NSString *)gesture;
- (BOOL)setCut:(NSString *)cutID included:(BOOL)included;
- (BOOL)setCutsFrom:(NSString *)firstID through:(NSString *)lastID included:(BOOL)included;
- (BOOL)adjustCut:(NSString *)cutID edit:(SSReviewBoundaryEdit)edit;
- (BOOL)auditionCut:(NSString *)cutID proposed:(BOOL)proposed gesture:(NSString *)gesture;
- (BOOL)stopAudition;
- (BOOL)selectAll:(BOOL)included;
- (BOOL)retryVerification;
- (void)cancel;
/// Stop polling and detach observers. This sends no cancellation or edit; the
/// owner calls cancel first when closing/switching should cancel active work.
- (void)detach;
/// Launch only the pinned installed helper in the background. Creates no
/// analysis request and does not activate Final Cut or change review state.
- (void)prepareWindowHelper:(void (^)(NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
