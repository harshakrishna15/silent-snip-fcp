#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// A short-lived size lease for this visible Final Cut-hosted view. Only the
/// helper can find and size its matching native window; no media or settings
/// are sent. Closing the view revokes the lease.
@interface SSWorkflowWindowClient : NSObject
@property (nonatomic, readonly, copy) NSString *state;
/// Display-only selection metadata. It grants no Analyze or Apply authority.
@property (nonatomic, copy, nullable) void (^presentationHandler)(NSDictionary *presentation);
- (instancetype)initWithViewID:(NSString *)viewID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)start;
- (void)stop;
- (void)updateProjectName:(nullable NSString *)projectName;
@end
NS_ASSUME_NONNULL_END
