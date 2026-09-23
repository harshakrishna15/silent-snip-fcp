#import "CutdownAudioUnit.h"
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>

namespace {
static_assert(std::atomic<float>::is_always_lock_free, "Audio parameter storage must be lock free");
constexpr float defaults[] = {-40.f, .5f, .1f, .1f};
constexpr float minimums[] = {-80.f, .0001f, 0.f, 0.f};
constexpr float maximums[] = {0.f, 10.f, 2.f, 2.f};
struct RenderStorage {
    std::array<std::atomic<float>, 4> values;
    std::array<std::vector<float>, 2> scratch;
    struct { UInt32 mNumberBuffers; AudioBuffer mBuffers[2]; } input;
    UInt32 channels = 0;
    AUAudioFrameCount maxFrames = 0;
    bool allocated = false;
    RenderStorage() { for (size_t i=0; i<4; ++i) values[i].store(defaults[i]); }
};
BOOL fail(NSError **error, OSStatus code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
BOOL validSettings(id settings) {
    if (![settings isKindOfClass:NSArray.class] || [settings count] != 4) return NO;
    for (NSUInteger i=0; i<4; ++i) {
        id value = settings[i];
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
        double number = [value doubleValue];
        if (!std::isfinite(number) || number < minimums[i] || number > maximums[i]) return NO;
    }
    return YES;
}
}

@interface CutdownAudioAnalysisRequest ()
@property(nonatomic, readwrite) NSURL *URL;
@property(nonatomic, copy) NSArray<NSNumber *> *settings;
- (instancetype)initWithURL:(NSURL *)URL settings:(NSArray<NSNumber *> *)settings;
@end
@implementation CutdownAudioAnalysisRequest
- (instancetype)initWithURL:(NSURL *)URL settings:(NSArray<NSNumber *> *)settings {
    if ((self = [super init])) { _URL = [URL copy]; _settings = [settings copy]; }
    return self;
}
@end

@implementation CutdownAudioLastUsedSettingsStore {
    NSURL *_fileURL;
}
- (instancetype)initWithFileURL:(NSURL *)fileURL {
    if ((self = [super init])) _fileURL = [fileURL copy];
    return self;
}
- (NSArray<NSNumber *> *)loadSettings {
    NSData *data = [NSData dataWithContentsOfURL:_fileURL];
    if (!data) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![plist isKindOfClass:NSDictionary.class] || ![plist[@"version"] isEqual:@1] || !validSettings(plist[@"values"])) return nil;
    return [plist[@"values"] copy];
}
- (BOOL)saveSettings:(NSArray<NSNumber *> *)settings error:(NSError **)error {
    if (!validSettings(settings)) return fail(error,kAudio_ParamError,@"The last-used audio settings are invalid.");
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"version":@1,@"values":settings}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtURL:_fileURL.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    // Each writer replaces one complete snapshot atomically. No per-field merging.
    return [data writeToURL:_fileURL options:NSDataWritingAtomic error:error];
}
@end

// Use Apple's own parameter-state codec on the private tree so existing presets
// and FCPXML effectState archives retain their exact format. This object is never
// registered with a host and never allocates or renders audio.
@interface CutdownAudioStateCodec : AUAudioUnit
@property(nonatomic) AUParameterTree *stateTree;
@end
@implementation CutdownAudioStateCodec
- (AUParameterTree *)parameterTree { return self.stateTree; }
@end

@implementation CutdownAudioUnit {
    AUAudioUnitBusArray *_inputs;
    AUAudioUnitBusArray *_outputs;
    AUParameterTree *_tree;
    AUParameterTree *_hostTree;
    CutdownAudioStateCodec *_stateCodec;
    RenderStorage *_storage;
    CutdownAudioLastUsedSettingsStore *_settingsStore;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                    options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *file = [[support URLByAppendingPathComponent:@"Cutdown Audio" isDirectory:YES] URLByAppendingPathComponent:@"LastUsedSettings.plist"];
    return [self initWithComponentDescription:description options:options
        settingsStore:[[CutdownAudioLastUsedSettingsStore alloc] initWithFileURL:file] error:error];
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                    options:(AudioComponentInstantiationOptions)options
                              settingsStore:(CutdownAudioLastUsedSettingsStore *)settingsStore error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (!self) return nil;
    _settingsStore = settingsStore;
    _storage = new RenderStorage();
    NSArray<NSNumber *> *lastUsed = [_settingsStore loadSettings];
    // Existing instances subsequently receive their own values through the AU
    // host's fullState restoration. Restoration never writes these defaults.
    if (lastUsed) for (NSUInteger i=0; i<4; ++i) _storage->values[i].store(lastUsed[i].floatValue);
    self.maximumFramesToRender = 4096;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    AUAudioUnitBus *input = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    AUAudioUnitBus *output = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!input || !output) return nil;
    input.supportedChannelCounts = @[@1,@2];
    output.supportedChannelCounts = @[@1,@2];
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[input]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[output]];
    NSArray *identifiers = @[@"threshold",@"minimum",@"before",@"after"];
    NSArray *names = @[@"Silence Threshold",@"Minimum Silence",@"Before Speech",@"After Speech"];
    NSMutableArray *parameters = [NSMutableArray array];
    for (NSUInteger i=0; i<4; ++i) {
        AUParameter *parameter = [AUParameterTree createParameterWithIdentifier:identifiers[i] name:names[i]
            address:i+1 min:minimums[i] max:maximums[i]
            unit:i==0 ? kAudioUnitParameterUnit_Decibels : kAudioUnitParameterUnit_Seconds unitName:nil
            flags:kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable valueStrings:nil dependentParameters:nil];
        parameter.value = _storage->values[i].load();
        [parameters addObject:parameter];
    }
    _tree = [AUParameterTree createTreeWithChildren:parameters];
    _hostTree = [AUParameterTree createTreeWithChildren:@[]];
    _stateCodec = [[CutdownAudioStateCodec alloc] initWithComponentDescription:description options:options error:error];
    if (!_stateCodec) return nil;
    _stateCodec.stateTree = _tree;
    // Parameter callbacks are independent of audio and never launch the helper.
    __weak CutdownAudioUnit *weakSelf = self;
    _tree.implementorValueObserver = ^(AUParameter *parameter, AUValue value) {
        CutdownAudioUnit *unit = weakSelf;
        if (unit && parameter.address >= 1 && parameter.address <= 4)
            unit->_storage->values[parameter.address-1].store(value, std::memory_order_relaxed);
    };
    _tree.implementorValueProvider = ^AUValue(AUParameter *parameter) {
        CutdownAudioUnit *unit = weakSelf;
        return unit && parameter.address >= 1 && parameter.address <= 4
            ? unit->_storage->values[parameter.address-1].load(std::memory_order_relaxed) : NAN;
    };
    return self;
}
- (void)dealloc { delete _storage; }
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (AUParameterTree *)parameterTree { return _hostTree; }
- (AUParameterTree *)analysisParameterTree { return _tree; }
- (BOOL)setAnalysisSettings:(NSArray<NSNumber *> *)settings error:(NSError **)error {
    if (!validSettings(settings)) return fail(error, kAudio_ParamError, @"Invalid analysis settings.");
    BOOL changed = NO;
    for (NSUInteger i=0; i<4; i++)
        changed |= [_tree parameterWithAddress:i+1].value != settings[i].floatValue;
    if (!changed) return YES;
    [self willChangeValueForKey:@"fullState"];
    [self willChangeValueForKey:@"fullStateForDocument"];
    [self willChangeValueForKey:@"allParameterValues"];
    for (NSUInteger i=0; i<4; i++) [_tree parameterWithAddress:i+1].value = settings[i].floatValue;
    [self didChangeValueForKey:@"allParameterValues"];
    [self didChangeValueForKey:@"fullStateForDocument"];
    [self didChangeValueForKey:@"fullState"];
    return YES;
}
- (NSDictionary *)fullState { return _stateCodec.fullState; }
- (void)setFullState:(NSDictionary *)state { _stateCodec.fullState = state; }
- (NSDictionary *)fullStateForDocument { return self.fullState; }
- (void)setFullStateForDocument:(NSDictionary *)state { self.fullState = state; }
- (NSArray<NSNumber *> *)channelCapabilities { return @[@1,@1,@2,@2]; }
- (BOOL)canProcessInPlace { return YES; }
- (NSTimeInterval)latency { return 0; }
- (NSTimeInterval)tailTime { return 0; }
- (BOOL)shouldChangeToFormat:(AVAudioFormat *)format forBus:(AUAudioUnitBus *)bus {
    return !self.renderResourcesAllocated && format.commonFormat == AVAudioPCMFormatFloat32 &&
        !format.isInterleaved && (format.channelCount == 1 || format.channelCount == 2) && format.sampleRate > 0;
}
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    AVAudioFormat *input = _inputs[0].format, *output = _outputs[0].format;
    if (input.channelCount != output.channelCount || input.sampleRate != output.sampleRate ||
        input.commonFormat != AVAudioPCMFormatFloat32 || output.commonFormat != AVAudioPCMFormatFloat32 ||
        input.isInterleaved || output.isInterleaved || input.channelCount < 1 || input.channelCount > 2)
        return fail(error, kAudioUnitErr_FormatNotSupported, @"Cutdown requires matching mono or stereo Float32 audio.");
    if (!self.maximumFramesToRender || self.maximumFramesToRender > 1048576)
        return fail(error, kAudioUnitErr_TooManyFramesToProcess, @"Unsupported audio buffer capacity.");
    _storage->channels = input.channelCount;
    _storage->maxFrames = self.maximumFramesToRender;
    for (UInt32 c=0; c<_storage->channels; ++c) _storage->scratch[c].resize(_storage->maxFrames);
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    _storage->allocated = true;
    return YES;
}
- (void)deallocateRenderResources {
    _storage->allocated = false;
    for (auto &buffer : _storage->scratch) std::vector<float>().swap(buffer);
    [super deallocateRenderResources];
}
- (AUInternalRenderBlock)internalRenderBlock {
    RenderStorage *state = _storage;
    // Audio rendering uses only preallocated C++ storage and the host pull block.
    // No Objective-C messages, allocation, locks, I/O, or UI actions occur here.
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
        AUAudioFrameCount frames, NSInteger outputBus, AudioBufferList *output,
        const AURenderEvent *events, AURenderPullInputBlock pullInput) {
        if (!state->allocated) return kAudioUnitErr_Uninitialized;
        if (outputBus != 0) return kAudioUnitErr_InvalidElement;
        if (frames > state->maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
        if (!pullInput) return kAudioUnitErr_NoConnection;
        if (!output || output->mNumberBuffers != state->channels) return kAudioUnitErr_FormatNotSupported;
        const UInt32 bytes = frames * sizeof(float);
        for (UInt32 c=0; c<state->channels; ++c) {
            if (output->mBuffers[c].mData && output->mBuffers[c].mDataByteSize < bytes) return kAudio_ParamError;
        }
        for (const AURenderEvent *event=events; event; event=event->head.next) {
            if ((event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp) &&
                event->parameter.parameterAddress >= 1 && event->parameter.parameterAddress <= 4)
                state->values[event->parameter.parameterAddress-1].store(event->parameter.value, std::memory_order_relaxed);
        }
        state->input.mNumberBuffers = state->channels;
        for (UInt32 c=0; c<state->channels; ++c) state->input.mBuffers[c] = {1,bytes,state->scratch[c].data()};
        AudioBufferList *input = reinterpret_cast<AudioBufferList *>(&state->input);
        AUAudioUnitStatus result = pullInput(flags,timestamp,frames,0,input);
        if (result != noErr) return result;
        if (input->mNumberBuffers != state->channels) return kAudioUnitErr_FormatNotSupported;
        for (UInt32 c=0; c<state->channels; ++c) {
            if (!input->mBuffers[c].mData || input->mBuffers[c].mDataByteSize < bytes) return kAudio_ParamError;
            AudioBuffer &destination = output->mBuffers[c];
            if (!destination.mData) destination.mData = input->mBuffers[c].mData;
            else if (destination.mData != input->mBuffers[c].mData)
                std::memmove(destination.mData,input->mBuffers[c].mData,bytes);
            destination.mNumberChannels = 1;
            destination.mDataByteSize = bytes;
        }
        return noErr;
    };
}
- (CutdownAudioAnalysisRequest *)analysisRequestWithError:(NSError **)error {
    NSArray *keys = @[@"threshold",@"minimum",@"before",@"after"];
    NSMutableArray<NSNumber *> *settings = [NSMutableArray arrayWithCapacity:4];
    NSMutableArray *query = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"request" value:NSUUID.UUID.UUIDString]];
    for (NSUInteger i=0; i<4; ++i) {
        AUParameter *parameter = [_tree parameterWithAddress:i+1];
        float value = parameter.value;
        if (!parameter || !std::isfinite(value) || value < minimums[i] || value > maximums[i]) {
            fail(error,kAudio_ParamError,@"Could not read all four valid settings from this audio effect."); return nil;
        }
        [settings addObject:@(value)];
        [query addObject:[NSURLQueryItem queryItemWithName:keys[i] value:@(value).stringValue]];
    }
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"cutdown"; components.host = @"analyze"; components.queryItems = query;
    return [[CutdownAudioAnalysisRequest alloc] initWithURL:components.URL settings:settings];
}
- (BOOL)rememberSettingsForRequest:(CutdownAudioAnalysisRequest *)request error:(NSError **)error {
    return [_settingsStore saveSettings:request.settings error:error];
}
@end
