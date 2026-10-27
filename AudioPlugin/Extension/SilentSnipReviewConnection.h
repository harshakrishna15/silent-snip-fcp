#import <Foundation/Foundation.h>

// Wire state constants are checked against the Swift enum by shared fixtures.
typedef NSString *SilentSnipReviewState NS_TYPED_EXTENSIBLE_ENUM;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateAnalyzing;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateCapturing;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateRecalculating;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateReview;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateApplying;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateVerifying;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateNavigating;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateCancelling;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateCompleted;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateComplete;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateFailed;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateCancelled;
FOUNDATION_EXPORT SilentSnipReviewState const SilentSnipReviewStateUnavailable;
FOUNDATION_EXPORT BOOL SilentSnipReviewStateIsBusy(SilentSnipReviewState state);
FOUNDATION_EXPORT BOOL SilentSnipReviewStateIsTerminal(SilentSnipReviewState state);
FOUNDATION_EXPORT BOOL SilentSnipReviewStateCanRetry(SilentSnipReviewState state);

/// Connection and command acknowledgment state. No AppKit controls or host UI.
@interface SilentSnipReviewConnection : NSObject
@property(nonatomic) NSDictionary *pendingSelection;
@property(nonatomic) NSNumber *selectionRevision;
@property(nonatomic) NSDictionary *pendingRetry;
@property(nonatomic) NSDictionary *pendingSettings;
@property(nonatomic) BOOL applyAcknowledged;
@property(nonatomic) NSDictionary *pendingApply;
@property(nonatomic) NSString *requestID;
@property(nonatomic) NSNumber *revision;
@property(nonatomic) NSDate *lastResponse;
@property(nonatomic, copy) NSString *lastResponseObject;
@property(nonatomic) BOOL awaitingResponse;
@property(nonatomic) BOOL applying;
@property(nonatomic) NSNumber *applyRevision;
@property(nonatomic) BOOL operationBusy;
@property(nonatomic, copy) SilentSnipReviewState state;
@property(nonatomic) BOOL timedOut;

- (NSDictionary *)acceptNotification:(NSNotification *)notification;
- (NSArray<NSDictionary *> *)commandsToRetry;
- (BOOL)hasTimedOutAt:(NSDate *)now;
@end
