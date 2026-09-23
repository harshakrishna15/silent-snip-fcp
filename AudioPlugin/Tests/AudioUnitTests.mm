#import "../Extension/CutdownAudioUnit.h"
#include <cassert>
#include <cmath>
#include <cstring>
#include <array>
#include <vector>

static NSURL *testDirectory;
static CutdownAudioLastUsedSettingsStore *store(NSString *name) {
    return [[CutdownAudioLastUsedSettingsStore alloc] initWithFileURL:[testDirectory URLByAppendingPathComponent:name]];
}
static CutdownAudioUnit *makeUnit(UInt32 channels=2, CutdownAudioLastUsedSettingsStore *settingsStore=nil) {
    AudioComponentDescription description = {'aufx','ctdn','Ctdn',0,0};
    NSError *error = nil;
    CutdownAudioUnit *unit = [[CutdownAudioUnit alloc] initWithComponentDescription:description options:0
        settingsStore:settingsStore ?: store(@"empty.plist") error:&error];
    assert(unit && !error);
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:channels];
    assert([unit.inputBusses[0] setFormat:format error:&error]);
    assert([unit.outputBusses[0] setFormat:format error:&error]);
    return unit;
}
static void setValues(CutdownAudioUnit *unit, NSArray<NSNumber *> *values) {
    for (NSUInteger i=0;i<4;++i) [unit.analysisParameterTree parameterWithAddress:i+1].value = values[i].floatValue;
}
static void expectValues(CutdownAudioUnit *unit, NSArray<NSNumber *> *values) {
    for (NSUInteger i=0;i<4;++i) assert([unit.analysisParameterTree parameterWithAddress:i+1].value == values[i].floatValue);
}
static void checkLastUsedSettings(void) {
    NSArray *factory = @[@-40,@.5,@.1,@.1], *analyzed = @[@-32,@.75,@.125,@.25], *other = @[@-55,@1.25,@.5,@.75];
    CutdownAudioLastUsedSettingsStore *preferences = store(@"last-used.plist");
    CutdownAudioUnit *first = makeUnit(2,preferences), *existing = makeUnit(1,preferences);
    expectValues(first,factory); expectValues(existing,factory);
    NSDictionary *originalState = first.fullStateForDocument;
    setValues(first,analyzed);
    NSError *error = nil;
    CutdownAudioAnalysisRequest *request = [first analysisRequestWithError:&error];
    assert(request && !error);
    // Capturing, editing and restoring state must not change new-instance defaults.
    expectValues(makeUnit(2,preferences),factory);
    setValues(first,other);
    assert([first rememberSettingsForRequest:request error:&error] && !error);
    // The remembered snapshot is the one submitted, not the later parameter values.
    CutdownAudioUnit *newUnit = makeUnit(2,store(@"last-used.plist"));
    expectValues(newUnit,analyzed); expectValues(existing,factory); expectValues(first,other);
    first.fullStateForDocument = originalState;
    expectValues(first,factory);
    newUnit.fullState = originalState;
    expectValues(newUnit,factory);
    expectValues(makeUnit(1,preferences),analyzed);
    // Invalid requests cannot replace a valid saved snapshot.
    [existing.analysisParameterTree parameterWithAddress:1].value = NAN;
    assert(![existing analysisRequestWithError:&error] && error);
    error = nil;
    assert((![preferences saveSettings:@[@-40,@(NAN),@.1,@.1] error:&error] && error));
    expectValues(makeUnit(2,preferences),analyzed);
    // A user's other local store remains independent.
    expectValues(makeUnit(2,store(@"separate.plist")),factory);
    // Reject malformed, partial, wrong-version, boolean and out-of-range values
    // as a whole; never combine pieces of a damaged snapshot with defaults.
    NSURL *corruptURL = [testDirectory URLByAppendingPathComponent:@"corrupt.plist"];
    NSArray *invalid = @[
        @{@"version":@2,@"values":analyzed},
        @{@"version":@1,@"values":@[@-32,@.75]},
        @{@"version":@1,@"values":@[@"-32",@.75,@.125,@.25]},
        @{@"version":@1,@"values":@[@YES,@.75,@.125,@.25]},
        @{@"version":@1,@"values":@[@-81,@.75,@.125,@.25]},
        @{@"version":@1,@"values":@[@-32,@.75,@.125,@3]}
    ];
    for (NSDictionary *plist in invalid) {
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nullptr];
        assert([data writeToURL:corruptURL options:NSDataWritingAtomic error:nullptr]);
        expectValues(makeUnit(2,store(@"corrupt.plist")),factory);
    }
    assert([[@"not a property list" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:corruptURL atomically:YES]);
    expectValues(makeUnit(2,store(@"corrupt.plist")),factory);
    // Surface a filesystem error instead of claiming preferences were saved.
    CutdownAudioLastUsedSettingsStore *unwritable = [[CutdownAudioLastUsedSettingsStore alloc] initWithFileURL:testDirectory];
    error = nil;
    assert(![unwritable saveSettings:analyzed error:&error] && error);
}
static void checkRender(UInt32 channels, bool silence, bool hostBuffers, bool inPlace) {
    CutdownAudioUnit *unit = makeUnit(channels);
    unit.maximumFramesToRender = 4096;
    NSError *error = nil;
    assert([unit allocateRenderResourcesAndReturnError:&error] && !error);
    AUInternalRenderBlock render = unit.internalRenderBlock;
    for (AUAudioFrameCount frames : {0u,1u,17u,256u,4096u}) {
        std::array<std::vector<float>,2> source, result;
        for (UInt32 c=0;c<channels;++c) {
            source[c].resize(frames+1); result[c].assign(frames+1,123.5f);
            for (UInt32 i=0;i<frames;++i) source[c][i] = silence ? 0 : std::sin(float(i)*.31f) * (c ? -1.8f : 1.3f);
            if (frames>2 && !silence) source[c][2] = -0.f;
            if (inPlace) std::memcpy(result[c].data(),source[c].data(),frames*sizeof(float));
        }
        struct { UInt32 count; AudioBuffer buffers[2]; } buffers;
        buffers.count = channels;
        for (UInt32 c=0;c<channels;++c) buffers.buffers[c] = {1,static_cast<UInt32>(frames*sizeof(float)),hostBuffers?result[c].data():nullptr};
        __block int pulls = 0;
        auto *src = &source; auto *dst = &result;
        AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,
            AUAudioFrameCount count,NSInteger bus,AudioBufferList *data) {
            assert(bus==0 && count==frames && data->mNumberBuffers==channels);
            ++pulls;
            for (UInt32 c=0;c<channels;++c) {
                if (inPlace) data->mBuffers[c].mData = (*dst)[c].data();
                else std::memcpy(data->mBuffers[c].mData,(*src)[c].data(),frames*sizeof(float));
                data->mBuffers[c].mDataByteSize = frames*sizeof(float);
            }
            if (silence) *flags |= kAudioUnitRenderAction_OutputIsSilence;
            return noErr;
        };
        AudioTimeStamp timestamp = {}; timestamp.mFlags = kAudioTimeStampSampleTimeValid; timestamp.mSampleTime = 8192;
        AudioUnitRenderActionFlags flags = 0;
        auto *output = reinterpret_cast<AudioBufferList *>(&buffers);
        assert(render(&flags,&timestamp,frames,0,output,nullptr,pull)==noErr && pulls==1);
        assert((flags & kAudioUnitRenderAction_OutputIsSilence) == (silence?kAudioUnitRenderAction_OutputIsSilence:0));
        for (UInt32 c=0;c<channels;++c) {
            assert(output->mBuffers[c].mDataByteSize==frames*sizeof(float));
            assert(std::memcmp(output->mBuffers[c].mData,source[c].data(),frames*sizeof(float))==0);
            if (hostBuffers) assert(result[c][frames]==123.5f);
        }
        assert(render(&flags,&timestamp,4097,0,output,nullptr,pull)==kAudioUnitErr_TooManyFramesToProcess);
        assert(render(&flags,&timestamp,frames,0,output,nullptr,nil)==kAudioUnitErr_NoConnection);
        AURenderPullInputBlock failPull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *, const AudioTimeStamp *, AUAudioFrameCount,NSInteger,AudioBufferList *) { return kAudioUnitErr_CannotDoInCurrentContext; };
        assert(render(&flags,&timestamp,frames,0,output,nullptr,failPull)==kAudioUnitErr_CannotDoInCurrentContext);
    }
    assert(unit.latency==0 && unit.tailTime==0);
    [unit deallocateRenderResources];
}
int main(void) {
    @autoreleasepool {
        testDirectory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:
            [@"CutdownAudioTests-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        assert([NSFileManager.defaultManager createDirectoryAtURL:testDirectory withIntermediateDirectories:YES attributes:nil error:nullptr]);
        checkLastUsedSettings();
        for (UInt32 channels : {1u,2u}) for (bool silence : {false,true}) {
            checkRender(channels,silence,true,false);
            checkRender(channels,silence,false,false);
            checkRender(channels,silence,true,true);
        }
        CutdownAudioUnit *first=makeUnit(), *second=makeUnit();
        float expected[] = {-32.f,.75f,.125f,.25f};
        for (NSUInteger i=0;i<4;++i) [first.analysisParameterTree parameterWithAddress:i+1].value = expected[i];
        assert([second.analysisParameterTree parameterWithAddress:1].value == -40);
        NSDictionary *state=first.fullStateForDocument;
        assert(state);
        second.fullStateForDocument=state;
        for (NSUInteger i=0;i<4;++i) assert([second.analysisParameterTree parameterWithAddress:i+1].value==expected[i]);
        NSError *error=nil;
        NSURL *url=[second analysisRequestWithError:&error].URL;
        assert(url && !error);
        NSMutableDictionary *query=[NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) query[item.name]=item.value;
        assert([query[@"threshold"] floatValue]==-32 && [query[@"minimum"] floatValue]==.75 && [query[@"before"] floatValue]==.125 && [query[@"after"] floatValue]==.25);
        [second.analysisParameterTree parameterWithAddress:1].value=NAN;
        assert([second analysisRequestWithError:&error]==nil && error);
        CutdownAudioUnit *mismatch=makeUnit(1);
        AVAudioFormat *stereo=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        assert([mismatch.outputBusses[0] setFormat:stereo error:&error]);
        assert(![mismatch allocateRenderResourcesAndReturnError:&error]);
        assert([NSFileManager.defaultManager removeItemAtURL:testDirectory error:nullptr]);
        puts("PASS: 60 exact mono/stereo render cases; per-instance state; new-instance last-used defaults; immutable request snapshots; document restoration; isolated on-disk persistence; malformed/invalid values and write failures; exact nondefault requests. User preferences untouched.");
    }
}
