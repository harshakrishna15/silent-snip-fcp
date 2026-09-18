#import <Foundation/Foundation.h>

// Wire state constants are checked against the Swift enum by shared fixtures.
typedef NSString *CutdownReviewState NS_TYPED_EXTENSIBLE_ENUM;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateAnalyzing;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateCapturing;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateRecalculating;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateReview;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateApplying;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateVerifying;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateNavigating;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateCancelling;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateCompleted;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateComplete;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateFailed;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateCancelled;
FOUNDATION_EXPORT CutdownReviewState const CutdownReviewStateUnavailable;
FOUNDATION_EXPORT BOOL CutdownReviewStateIsBusy(CutdownReviewState state);
FOUNDATION_EXPORT BOOL CutdownReviewStateIsTerminal(CutdownReviewState state);
FOUNDATION_EXPORT BOOL CutdownReviewStateCanRetry(CutdownReviewState state);

/// Connection and command acknowledgment state. No AppKit controls or host UI.
@interface CutdownReviewConnection : NSObject
@property(nonatomic) NSDictionary *pendingSelection;
@property(nonatomic) NSNumber *selectionRevision;
@property(nonatomic) NSDictionary *pendingRetry;
@property(nonatomic) NSDictionary *pendingPreview;
@property(nonatomic) NSNumber *previewRevision;
@property(nonatomic) BOOL applyAcknowledged;
@property(nonatomic) NSString *requestID;
@property(nonatomic) NSNumber *revision;
@property(nonatomic) NSDate *lastResponse;
@property(nonatomic, copy) NSString *lastResponseObject;
@property(nonatomic) BOOL awaitingResponse;
@property(nonatomic) BOOL applying;
@property(nonatomic) NSNumber *applyRevision;
@property(nonatomic) BOOL operationBusy;
@property(nonatomic, copy) CutdownReviewState state;
@property(nonatomic) BOOL timedOut;

- (NSDictionary *)acceptNotification:(NSNotification *)notification;
- (NSArray<NSDictionary *> *)commandsToRetry;
- (BOOL)hasTimedOutAt:(NSDate *)now;
@end
