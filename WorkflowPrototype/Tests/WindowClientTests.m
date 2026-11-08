#import <Foundation/Foundation.h>
#import "../Extension/WorkflowWindowClient.h"
#import "../Extension/WorkflowReviewClient.h"
#import <stdio.h>
#import <stdlib.h>

static NSUInteger checks, groups, cleanupCalls;
static void require(BOOL condition, NSString *message) {
    checks += 1;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(EXIT_FAILURE); }
}
static void unexpectedBoundary(void) {
    fprintf(stderr, "FAIL: An offline window test reached an unmocked external boundary\n"); abort();
}

// Include the actual transport with an offline center substitution. Its
// dealloc cleanup is isolated too; missed observer/post overrides fail here.
@interface SSOfflineWindowNotificationCenter : NSObject
+ (instancetype)defaultCenter;
- (void)removeObserver:(id)observer;
- (void)addObserver:(id)observer selector:(SEL)selector name:(NSString *)name object:(NSString *)object suspensionBehavior:(NSNotificationSuspensionBehavior)behavior;
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)info deliverImmediately:(BOOL)immediate;
@end
@implementation SSOfflineWindowNotificationCenter
+ (instancetype)defaultCenter { static SSOfflineWindowNotificationCenter *center; if (!center) center = [self new]; return center; }
- (void)removeObserver:(id)observer { cleanupCalls += 1; }
- (void)addObserver:(id)observer selector:(SEL)selector name:(NSString *)name object:(NSString *)object suspensionBehavior:(NSNotificationSuspensionBehavior)behavior { unexpectedBoundary(); }
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)info deliverImmediately:(BOOL)immediate { unexpectedBoundary(); }
@end
#define NSDistributedNotificationCenter SSOfflineWindowNotificationCenter
#import "../Extension/WorkflowWindowClient.m"
#undef NSDistributedNotificationCenter

// The real quiet helper launcher is never linked or instantiated.
@implementation SSWorkflowReviewClient
- (instancetype)initWithViewID:(NSString *)viewID update:(void (^)(NSDictionary *))update failure:(void (^)(NSString *))failure { unexpectedBoundary(); return nil; }
- (NSString *)requestID { unexpectedBoundary(); return nil; }
- (BOOL)busy { unexpectedBoundary(); return NO; }
- (BOOL)canApply { unexpectedBoundary(); return NO; }
- (BOOL)canChangeSelection { unexpectedBoundary(); return NO; }
- (BOOL)canCancel { unexpectedBoundary(); return NO; }
- (BOOL)canUpdateCuts { unexpectedBoundary(); return NO; }
- (BOOL)canHighlight { unexpectedBoundary(); return NO; }
- (void)markSettingsDirty { unexpectedBoundary(); }
- (BOOL)updateCutsWithSettings:(NSDictionary *)settings gesture:(NSString *)gesture { unexpectedBoundary(); return NO; }
- (BOOL)automaticallyUpdateCutsWithSettings:(NSDictionary *)settings edit:(NSString *)edit { unexpectedBoundary(); return NO; }
- (BOOL)highlightCut:(NSString *)cutID { unexpectedBoundary(); return NO; }
- (BOOL)verifyExistingResultURL:(NSURL *)resultURL libraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID
                  projectName:(NSString *)projectName gesture:(NSString *)gesture { unexpectedBoundary(); return NO; }
- (BOOL)startWithLibraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID projectName:(NSString *)projectName settings:(NSDictionary *)settings gesture:(NSString *)gesture { unexpectedBoundary(); return NO; }
- (BOOL)sendApplyWithGesture:(NSString *)gesture { unexpectedBoundary(); return NO; }
- (BOOL)setCut:(NSString *)cutID included:(BOOL)included { unexpectedBoundary(); return NO; }
- (BOOL)selectAll:(BOOL)included { unexpectedBoundary(); return NO; }
- (BOOL)retryVerification { unexpectedBoundary(); return NO; }
- (void)cancel { unexpectedBoundary(); }
- (void)detach { unexpectedBoundary(); }
- (void)prepareWindowHelper:(void (^)(NSError *))completion { unexpectedBoundary(); }
@end

@interface SSOfflineWindowClient : SSWorkflowWindowClient
@property (nonatomic) NSTimeInterval clock;
@property (nonatomic) NSUInteger preparations, observationStarts, observationStops, timerStarts, timerStops;
@property (nonatomic) BOOL observing, timerActive;
@property (nonatomic, strong) NSMutableArray<void (^)(NSError *)> *completions;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *posts;
- (void)completeHelper:(NSError *)error;
@end
@implementation SSOfflineWindowClient
- (instancetype)initWithViewID:(NSString *)viewID {
    self = [super initWithViewID:viewID];
    if (self) { _clock = 100; _completions = [NSMutableArray new]; _posts = [NSMutableArray new]; }
    return self;
}
- (NSTimeInterval)now { return self.clock; }
- (void)prepareHelper:(void (^)(NSError *))completion { self.preparations += 1; [self.completions addObject:[completion copy]]; }
- (void)completeHelper:(NSError *)error {
    require(self.completions.count > 0, @"A helper completion belongs to a captured offline launch");
    void (^completion)(NSError *) = self.completions.firstObject;
    [self.completions removeObjectAtIndex:0]; completion(error);
}
- (void)beginObserving { self.observationStarts += 1; self.observing = YES; }
- (void)endObserving { self.observationStops += 1; self.observing = NO; }
- (void)startTimer { self.timerStarts += 1; self.timerActive = YES; }
- (void)stopTimer { self.timerStops += 1; self.timerActive = NO; }
- (void)postObject:(NSString *)object name:(NSString *)name {
    NSData *data = [object dataUsingEncoding:NSUTF8StringEncoding];
    id packet = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    require([packet isKindOfClass:NSDictionary.class] && data.length <= 1024, @"Outgoing lease commands are bounded JSON");
    [self.posts addObject:@{@"name":name, @"packet":packet}];
}
@end

static NSString * const View = @"2686A7A1-BC05-4885-82A2-C9EE8A096F45";
static NSString * const Command = @"local.silentsnip.workflow.window.v1";
static SSOfflineWindowClient *client(void) { return [[SSOfflineWindowClient alloc] initWithViewID:View]; }
static SSOfflineWindowClient *readyClient(void) { SSOfflineWindowClient *value = client(); [value start]; [value completeHelper:nil]; return value; }
static NSDictionary *packet(SSOfflineWindowClient *value, NSUInteger index) { return value.posts[index][@"packet"]; }
static NSMutableDictionary *reply(SSOfflineWindowClient *value) {
    return [@{@"version":@1, @"protocol":@1, @"command":@"attach", @"view":View,
        @"nonce":packet(value,0)[@"nonce"], @"accepted":@YES, @"state":@"fixed",
        @"width":@615, @"height":@736, @"corrections":@1} mutableCopy];
}
static void receiveObject(SSOfflineWindowClient *value, id object, NSString *name, NSDictionary *info) {
    [value receive:[NSNotification notificationWithName:name object:object userInfo:info]];
}
static void receiveReply(SSOfflineWindowClient *value, id response) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingFragmentsAllowed error:nil];
    receiveObject(value, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], [Command stringByAppendingFormat:@".%@",View], nil);
}
static void rejectAndCheckRetryDelay(SSOfflineWindowClient *value, NSTimeInterval delay) {
    NSDictionary *previous = value.posts.lastObject[@"packet"];
    NSMutableDictionary *negative = reply(value); negative[@"nonce"] = previous[@"nonce"]; negative[@"accepted"] = @NO;
    NSUInteger posts = value.posts.count, launches = value.preparations;
    NSTimeInterval deadline = value.clock + delay;
    receiveReply(value, negative); [value tick];
    require([value.state isEqual:@"unavailable"] && value.posts.count == posts,
        @"Negative acknowledgments cannot immediately retry a retired attachment");
    value.clock = deadline - 0.001; [value tick];
    require(value.posts.count == posts, @"A failed attachment stays quiet until its retry deadline");
    value.clock = deadline; [value tick];
    NSDictionary *retry = value.posts.lastObject[@"packet"];
    require(value.posts.count == posts + 1 && [retry[@"command"] isEqual:@"attach"] &&
        ![retry[@"nonce"] isEqual:previous[@"nonce"]] && value.preparations == launches,
        @"The retry deadline sends one fresh attach without relaunching the helper");
}

static void attachRenewDetachAndFreshNonce(void) {
    SSOfflineWindowClient *value = client();
    require([value.state isEqual:@"stopped"], @"A new lease is stopped");
    [value start]; [value start]; [value tick];
    require(value.preparations == 1 && value.observing && value.posts.count == 0 && !value.timerActive && [value.state isEqual:@"waiting"],
        @"Start is idempotent and sends nothing before the quiet launch completes");
    [value completeHelper:nil]; NSDictionary *attach = packet(value,0);
    require([attach[@"command"] isEqual:@"attach"] && [attach[@"version"] isEqual:@1] && [attach[@"view"] isEqual:View] &&
        [value.posts[0][@"name"] isEqual:Command] && [[NSSet setWithArray:attach.allKeys] isEqual:[NSSet setWithArray:@[@"version",@"command",@"view",@"nonce"]]] &&
        [[NSUUID alloc] initWithUUIDString:attach[@"nonce"]] != nil, @"Attach carries only the canonical view, fresh nonce, version, and command");
    require(value.timerStarts == 1 && [value.state isEqual:@"unavailable"], @"An unacknowledged launch cannot claim verified sizing");
    [value tick]; require([packet(value,1)[@"command"] isEqual:@"attach"], @"Unacknowledged ticks retry attach");
    receiveReply(value,reply(value)); [value tick];
    require([value.state isEqual:@"fixed"] && [packet(value,2)[@"command"] isEqual:@"renew"], @"A validated acknowledgment permits renew");
    [value stop]; [value stop]; [value tick];
    require(value.posts.count == 4 && [packet(value,3)[@"command"] isEqual:@"detach"] && [packet(value,3)[@"nonce"] isEqual:attach[@"nonce"]] &&
        !value.observing && !value.timerActive && value.timerStops == 1 && [value.state isEqual:@"stopped"], @"Stop sends one matching detach and revokes observation and timer");
    for (NSDictionary *post in value.posts)
        require([[NSSet setWithArray:[post[@"packet"] allKeys]] isEqual:[NSSet setWithArray:@[@"version",@"command",@"view",@"nonce"]]],
            @"Attach retries, renew, and detach retain the exact strict worker lease envelope");
    [value start]; [value completeHelper:nil];
    require(![packet(value,4)[@"nonce"] isEqual:attach[@"nonce"]], @"A new visible lease uses a fresh nonce");
    [value stop]; groups += 1;
}
static void delayedLaunchAndOldGenerationCannotAttach(void) {
    SSOfflineWindowClient *value = client(); [value start]; [value stop]; [value completeHelper:nil];
    require(value.posts.count == 0 && value.timerStarts == 0 && !value.observing && [value.state isEqual:@"stopped"], @"A launch completing after stop cannot attach or start a timer");
    [value start]; [value stop]; [value start]; [value completeHelper:nil];
    require(value.posts.count == 0 && [value.state isEqual:@"waiting"], @"An older launch generation cannot attach the next visible lease");
    [value completeHelper:nil]; require(value.posts.count == 1 && value.timerStarts == 1 && value.observing, @"Only the current launch completion attaches");
    [value stop]; groups += 1;
}
static void launchFailureIsQuietAndRetryable(void) {
    SSOfflineWindowClient *value = client(); [value start];
    [value completeHelper:[NSError errorWithDomain:@"test.launch" code:1 userInfo:nil]];
    require([value.state isEqual:@"unavailable"] && !value.observing && value.posts.count == 0 && value.timerStarts == 0, @"Launch failure stays quiet and ends observation");
    [value start]; [value completeHelper:nil];
    require(value.preparations == 2 && value.posts.count == 1 && value.timerStarts == 1, @"A later visible reconnect retries launch failure");
    [value stop]; groups += 1;
}
static void invalidViewIdentityNeverLaunches(void) {
    for (NSString *view in @[@"",@"not-a-uuid",View.lowercaseString,[View stringByAppendingString:@" "]]) {
        SSOfflineWindowClient *value = [[SSOfflineWindowClient alloc] initWithViewID:view]; [value start]; [value tick]; [value stop];
        require(value.preparations == 0 && value.observationStarts == 0 && value.posts.count == 0 && [value.state isEqual:@"unavailable"], @"Noncanonical view identities cannot launch or observe");
    }
    groups += 1;
}
static void replyEnvelopeAndPayloadValidation(void) {
    SSOfflineWindowClient *value = readyClient(); NSMutableDictionary *valid = reply(value); NSMutableArray *invalid = [NSMutableArray new];
    for (NSString *key in valid.allKeys) { NSMutableDictionary *changed = [valid mutableCopy]; [changed removeObjectForKey:key]; [invalid addObject:changed]; }
    NSDictionary *badValues = @{@"version":@[@YES,@2,@1.5,@"1"], @"protocol":@[@YES,@2,@0,@"1"],
        @"command":@[@"detach",@"unknown",@1], @"view":@[@"wrong",View.lowercaseString,@1], @"nonce":@[NSUUID.UUID.UUIDString,@1],
        @"accepted":@[@1,@0,@"true"], @"state":@[@1,[@"x" stringByPaddingToLength:33 withString:@"x" startingAtIndex:0]],
        @"width":@[@YES,@614,@615.5,@"615"], @"height":@[@YES,@735,@736.5,@"736"],
        @"corrections":@[@YES,@-1,@0.5,@1000000001,@"1"], @"axCode":@[@YES,@0.5,@"0"]};
    for (NSString *key in badValues) for (id item in badValues[key]) { NSMutableDictionary *changed = [valid mutableCopy]; changed[key] = item; [invalid addObject:changed]; }
    NSMutableDictionary *extra = [valid mutableCopy]; extra[@"unknown"] = @1; [invalid addObject:extra];
    [invalid addObjectsFromArray:@[@[],@"not a dictionary",@1,NSNull.null]];
    for (id item in invalid) { receiveReply(value,item); require([value.state isEqual:@"unavailable"], @"Malformed, stale, wrong-protocol, unknown-key, and mistyped replies cannot verify a lease"); }
    NSString *name = [Command stringByAppendingFormat:@".%@",View];
    NSData *data = [NSJSONSerialization dataWithJSONObject:valid options:0 error:nil]; NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (id object in @[@1,@"",@"{bad json",[json stringByPaddingToLength:2049 withString:@" " startingAtIndex:0]]) {
        receiveObject(value,object,name,nil); require([value.state isEqual:@"unavailable"], @"Wrong objects, invalid JSON, and oversized packets are ignored");
    }
    receiveObject(value,json,@"wrong.channel",nil); receiveObject(value,json,name,@{@"injected":@YES});
    require([value.state isEqual:@"unavailable"], @"Wrong channels and attached userInfo cannot acknowledge sizing");
    valid[@"axCode"] = @-25204; valid[@"corrections"] = @0; receiveReply(value,valid);
    require([value.state isEqual:@"fixed"], @"An exact bounded reply remains accepted after invalid traffic");
    [value stop]; groups += 1;
}
static void staleRepliesAndTimeoutCannotClaimCurrentSizing(void) {
    SSOfflineWindowClient *value = readyClient(); NSMutableDictionary *old = reply(value); receiveReply(value,old); value.clock += 2.5;
    require([value.state isEqual:@"fixed"], @"An acknowledgment stays valid at the timeout boundary"); value.clock += 0.01;
    require([value.state isEqual:@"unavailable"], @"Missing heartbeat acknowledgments expire sizing verification");
    receiveReply(value,old); require([value.state isEqual:@"fixed"], @"A current valid acknowledgment restores availability");
    [value stop]; receiveReply(value,old); require([value.state isEqual:@"stopped"], @"Late replies cannot revive a stopped lease");
    [value start]; [value completeHelper:nil]; receiveReply(value,old);
    require([value.state isEqual:@"unavailable"], @"An old nonce cannot acknowledge a new lease");
    NSMutableDictionary *negative = [old mutableCopy]; negative[@"nonce"] = value.posts.lastObject[@"packet"][@"nonce"]; negative[@"accepted"] = @NO;
    NSUInteger beforeRetry = value.posts.count;
    receiveReply(value,negative); [value tick];
    require(value.posts.count == beforeRetry, @"The first rejected lease waits before attempting its replacement");
    value.clock += 1; [value tick];
    NSDictionary *recovery = value.posts.lastObject[@"packet"];
    require([value.state isEqual:@"unavailable"] && [recovery[@"command"] isEqual:@"attach"] &&
        ![recovery[@"nonce"] isEqual:negative[@"nonce"]] && [[NSUUID alloc] initWithUUIDString:recovery[@"nonce"]] != nil,
        @"Rejected attach stays unavailable and retries with a fresh nonce rather than renewing a retired lease");
    NSMutableDictionary *late = [negative mutableCopy]; late[@"accepted"] = @YES;
    receiveReply(value,late);
    require([value.state isEqual:@"unavailable"], @"A late success for the rejected nonce cannot acknowledge its replacement");
    late[@"nonce"] = recovery[@"nonce"]; receiveReply(value,late); [value tick];
    require([value.state isEqual:@"fixed"] && [value.posts.lastObject[@"packet"][@"command"] isEqual:@"renew"] &&
        [value.posts.lastObject[@"packet"][@"nonce"] isEqual:recovery[@"nonce"]],
        @"A matching fresh acknowledgment recovers sizing and renews only the replacement lease");
    [value stop]; groups += 1;
}
static void negativeAcknowledgmentsBackOffAndFixedAcknowledgmentsResetBudget(void) {
    SSOfflineWindowClient *value = readyClient();
    for (NSNumber *delay in @[@1,@2,@4,@8,@16,@30,@30]) rejectAndCheckRetryDelay(value, delay.doubleValue);
    NSMutableDictionary *fixed = reply(value); fixed[@"nonce"] = value.posts.lastObject[@"packet"][@"nonce"];
    receiveReply(value, fixed); [value tick];
    require([value.state isEqual:@"fixed"] && [value.posts.lastObject[@"packet"][@"command"] isEqual:@"renew"] && value.preparations == 1,
        @"Successful readback acknowledgment recovers the lease without a helper relaunch");
    rejectAndCheckRetryDelay(value, 1);
    NSDictionary *last = value.posts.lastObject[@"packet"];
    NSMutableDictionary *negative = reply(value); negative[@"nonce"] = last[@"nonce"]; negative[@"accepted"] = @NO;
    receiveReply(value,negative);
    [value stop]; [value start]; [value completeHelper:nil];
    require([value.posts.lastObject[@"packet"][@"command"] isEqual:@"attach"] && value.preparations == 2,
        @"A new visible session starts immediately despite the prior session's pending backoff");
    rejectAndCheckRetryDelay(value, 1);
    [value stop]; groups += 1;
}
int main(void) {
    @autoreleasepool {
        attachRenewDetachAndFreshNonce(); delayedLaunchAndOldGenerationCannotAttach(); launchFailureIsQuietAndRetryable();
        invalidViewIdentityNeverLaunches(); replyEnvelopeAndPayloadValidation(); staleRepliesAndTimeoutCannotClaimCurrentSizing();
        negativeAcknowledgmentsBackOffAndFixedAcknowledgmentsResetBudget();
    }
    require(cleanupCalls > 0, @"Deallocation also uses the offline notification-center replacement");
    printf("Passed %lu window-client groups (%lu assertions); no helpers, notifications, timers, windows, or Final Cut used.\n", (unsigned long)groups,(unsigned long)checks);
    return EXIT_SUCCESS;
}
