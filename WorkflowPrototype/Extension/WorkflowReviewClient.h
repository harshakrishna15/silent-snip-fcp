#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A control-only client for the existing Silent Snip worker. UUIDs are their
/// canonical string representations. No media, XML, or Final Cut preferences
/// are opened by this client.
@interface SSWorkflowReviewClient : NSObject
@property (nonatomic, readonly, copy, nullable) NSString *requestID;
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, readonly) BOOL canApply;
@property (nonatomic, readonly) BOOL canChangeSelection;
@property (nonatomic, readonly) BOOL canCancel;

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
- (BOOL)startWithLibraryURL:(NSURL *)libraryURL
                projectUID:(NSString *)projectUID
               projectName:(NSString *)projectName
                  settings:(NSDictionary *)settings
                   gesture:(NSString *)gesture;
- (BOOL)sendApplyWithGesture:(NSString *)gesture;
- (BOOL)setCut:(NSString *)cutID included:(BOOL)included;
- (BOOL)selectAll:(BOOL)included;
- (BOOL)retryVerification;
- (void)cancel;
/// Stop polling and detach observers. This sends no cancellation or edit; the
/// owner calls cancel first when closing/switching should cancel active work.
- (void)detach;
@end

NS_ASSUME_NONNULL_END
