#import <CoreAudioKit/CoreAudioKit.h>
#import <AudioToolbox/AUAudioUnitImplementation.h>

NS_ASSUME_NONNULL_BEGIN

// Final Cut hosts this view in the effect's Controls window. Only explicit
// button clicks dispatch requests; creating/rendering/restoring an AU does not.
@interface CutdownAudioUnitFactory : AUViewController <AUAudioUnitFactory>
@end

NS_ASSUME_NONNULL_END
