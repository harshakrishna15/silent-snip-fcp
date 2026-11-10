#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// A short-lived size lease for this visible Final Cut-hosted view. Only the
/// helper can find and size its matching native window; no media or settings
/// are sent. Closing the view revokes the lease.
@interface SSWorkflowWindowClient : NSObject
@property (nonatomic, readonly, copy) NSString *state;
- (instancetype)initWithViewID:(NSString *)viewID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)start;
- (void)stop;
/// Read-only title reports are bound to this visible project's epoch.
- (void)observeSelectionInProject:(nullable NSString *)projectName epoch:(nullable NSString *)epoch
                         update:(void (^ _Nullable)(NSString * _Nullable title))update;
@end
NS_ASSUME_NONNULL_END
