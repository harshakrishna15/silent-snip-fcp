#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AUAudioUnitImplementation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
// The URL and immutable parameter snapshot are captured together. Saving this
// request cannot accidentally pick up later changes in this or another instance.
@interface CutdownAudioAnalysisRequest : NSObject
@property(nonatomic, readonly) NSURL *URL;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// Inject a temporary file URL in tests. Production uses the extension's local
// Application Support container; no preferences are written by render callbacks.
@interface CutdownAudioLastUsedSettingsStore : NSObject
- (instancetype)initWithFileURL:(NSURL *)fileURL;
- (nullable NSArray<NSNumber *> *)loadSettings;
- (BOOL)saveSettings:(NSArray<NSNumber *> *)settings error:(NSError **)error;
@end

@interface CutdownAudioUnit : AUAudioUnit
// Private to Cutdown's custom view. The host-facing parameterTree is empty.
@property(nonatomic, readonly) AUParameterTree *analysisParameterTree;
- (BOOL)setAnalysisSettings:(NSArray<NSNumber *> *)settings error:(NSError **)error;
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                    options:(AudioComponentInstantiationOptions)options
                              settingsStore:(CutdownAudioLastUsedSettingsStore *)settingsStore
                                      error:(NSError **)error;
// Constructs a request from this instance's actual AUParameter values. Does not
// launch another application. Dispatch requires a separately authorized action.
- (nullable NSURL *)analysisRequestURLWithError:(NSError **)error;
- (nullable CutdownAudioAnalysisRequest *)analysisRequestWithError:(NSError **)error;
// Call only after the user explicitly submits this request successfully.
- (BOOL)rememberSettingsForRequest:(CutdownAudioAnalysisRequest *)request error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
