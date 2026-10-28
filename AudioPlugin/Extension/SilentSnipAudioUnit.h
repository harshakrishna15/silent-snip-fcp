#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AUAudioUnitImplementation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
// The URL and immutable parameter snapshot are captured together. Saving this
// request cannot accidentally pick up later changes in this or another instance.
@interface SilentSnipAudioAnalysisRequest : NSObject
@property(nonatomic, readonly) NSURL *URL;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// Inject a temporary file URL in tests. Production uses the extension's local
// Application Support container; no preferences are written by render callbacks.
@interface SilentSnipAudioLastUsedSettingsStore : NSObject
- (instancetype)initWithFileURL:(NSURL *)fileURL;
- (nullable NSArray<NSNumber *> *)loadSettings;
- (BOOL)saveSettings:(NSArray<NSNumber *> *)settings error:(NSError **)error;
@end

@interface SilentSnipAudioUnit : AUAudioUnit
// Controls and the host share the same four stable parameters. Advertising
// them lets Final Cut serialize their values through XML imports and exports.
@property(nonatomic, readonly) AUParameterTree *analysisParameterTree;
- (BOOL)setAnalysisSettings:(NSArray<NSNumber *> *)settings error:(NSError **)error;
- (BOOL)setAnalysisSettings:(NSArray<NSNumber *> *)settings notifyHostEvenIfUnchanged:(BOOL)notifyHost error:(NSError **)error;
// Main-thread document notification after host parameter changes. Never call
// from the render callback; it does not change values or last-used defaults.
- (void)notifyHostOfParameterState;
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                    options:(AudioComponentInstantiationOptions)options
                              settingsStore:(SilentSnipAudioLastUsedSettingsStore *)settingsStore
                                      error:(NSError **)error;
// Constructs a request from this instance's actual AUParameter values. Does not
// launch another application. Dispatch requires a separately authorized action.
- (nullable SilentSnipAudioAnalysisRequest *)analysisRequestWithError:(NSError **)error;
// Call only after the user explicitly submits this request successfully.
- (BOOL)rememberSettingsForRequest:(SilentSnipAudioAnalysisRequest *)request error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
