#import <CoreAudioKit/CoreAudioKit.h>
#import <AudioToolbox/AUAudioUnitImplementation.h>

NS_ASSUME_NONNULL_BEGIN

// Resolve the containing app of this exact extension, rather than a competing
// legacy URL handler or another copy discovered by Launch Services.
FOUNDATION_EXPORT NSURL * _Nullable SilentSnipContainingApplicationURL(NSURL *extensionURL);

// Final Cut hosts this view in the effect's Controls window. Only explicit
// button clicks dispatch requests; creating/rendering/restoring an AU does not.
@interface SilentSnipAudioUnitFactory : AUViewController <AUAudioUnitFactory>
@end

NS_ASSUME_NONNULL_END
