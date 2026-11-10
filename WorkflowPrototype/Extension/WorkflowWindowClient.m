#import "WorkflowWindowClient.h"
#import "WorkflowReviewClient.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static NSString * const SSWindowCommand = @"local.silentsnip.workflow.window.v1";
static BOOL SSWindowInteger(id value, NSInteger expected) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] == (double)expected;
}

@interface SSWorkflowWindowClient ()
@property (nonatomic, copy) NSString *viewID;
@property (nonatomic, copy) NSString *nonce;
@property (nonatomic, copy) NSString *lastState;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) SSWorkflowReviewClient *launcher;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL launched;
@property (nonatomic) BOOL acknowledged;
@property (nonatomic) NSTimeInterval lastReply;
@property (nonatomic) NSTimeInterval nextAttach;
@property (nonatomic) NSUInteger attachFailures;
@property (nonatomic, copy) NSString *selectionProject;
@property (nonatomic, copy) NSString *selectionEpoch;
@property (nonatomic, copy) void (^selectionUpdate)(NSString *);
@property (nonatomic) NSTimeInterval lastSelectionReply;
@end

@implementation SSWorkflowWindowClient
- (instancetype)initWithViewID:(NSString *)viewID {
    self = [super init];
    if (self) { _viewID = [viewID copy]; _lastState = @"stopped"; }
    return self;
}
- (NSTimeInterval)now { return NSProcessInfo.processInfo.systemUptime; }
- (NSString *)state {
    if (self.active && self.launched && (!self.acknowledged || [self now] - self.lastReply > 2.5)) return @"unavailable";
    return self.lastState;
}
- (void)prepareHelper:(void (^)(NSError *))completion {
    self.launcher = [[SSWorkflowReviewClient alloc] initWithViewID:self.viewID update:^(NSDictionary *value) {} failure:^(NSString *message) {}];
    [self.launcher prepareWindowHelper:completion];
}
- (void)beginObserving {
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(receive:)
        name:[SSWindowCommand stringByAppendingFormat:@".%@", self.viewID] object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
}
- (void)endObserving { [NSDistributedNotificationCenter.defaultCenter removeObserver:self]; }
- (void)startTimer {
    __weak SSWorkflowWindowClient *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)stopTimer { [self.timer invalidate]; self.timer = nil; }
- (void)postObject:(NSString *)object name:(NSString *)name {
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:name object:object userInfo:nil deliverImmediately:YES];
}
- (void)send:(NSString *)command {
    if (!self.nonce) return;
    NSMutableDictionary *value = [@{@"version":@1, @"command":command, @"view":self.viewID, @"nonce":self.nonce} mutableCopy];
    if ([command isEqual:@"selection"]) {
        if (!self.selectionEpoch || !self.selectionProject.length) return;
        value[@"selectionEpoch"] = self.selectionEpoch;
        value[@"projectName"] = self.selectionProject;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (data.length <= 2048) [self postObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] name:SSWindowCommand];
}
- (void)observeSelectionInProject:(NSString *)projectName epoch:(NSString *)epoch
                         update:(void (^)(NSString *))update {
    self.selectionProject = [projectName lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 1024 ? projectName : nil;
    self.selectionEpoch = epoch;
    self.selectionUpdate = update;
    self.lastSelectionReply = 0;
    if (self.active && self.launched) [self send:@"selection"];
}
- (void)start {
    if (self.active) return;
    NSUUID *view = [[NSUUID alloc] initWithUUIDString:self.viewID];
    if (!view || ![view.UUIDString isEqual:self.viewID]) { self.lastState = @"unavailable"; return; }
    self.active = YES;
    self.launched = NO;
    self.acknowledged = NO;
    self.attachFailures = 0;
    self.nextAttach = 0;
    self.nonce = NSUUID.UUID.UUIDString;
    self.lastState = @"waiting";
    NSUInteger generation = ++self.generation;
    [self beginObserving];
    __weak SSWorkflowWindowClient *weakSelf = self;
    [self prepareHelper:^(NSError *error) {
        SSWorkflowWindowClient *owner = weakSelf;
        if (!owner.active || owner.generation != generation) return;
        if (error) {
            owner.lastState = @"unavailable";
            owner.active = NO;
            owner.nonce = nil;
            owner.launcher = nil;
            [owner endObserving];
            return;
        }
        owner.launched = YES;
        [owner send:@"attach"];
        [owner send:@"selection"];
        [owner startTimer];
    }];
}
- (void)tick {
    if (!self.active || !self.launched) return;
    if (self.lastSelectionReply > 0 && [self now] - self.lastSelectionReply > 2.5) {
        self.lastSelectionReply = 0;
        if (self.selectionUpdate) self.selectionUpdate(nil);
    }
    if (self.acknowledged || [self now] >= self.nextAttach) [self send:self.acknowledged ? @"renew" : @"attach"];
    [self send:@"selection"];
}
- (void)receive:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self receive:notification]; });
        return;
    }
    if (!self.active || !self.launched || notification.userInfo.count ||
        ![notification.name isEqual:[SSWindowCommand stringByAppendingFormat:@".%@", self.viewID]] ||
        ![notification.object isKindOfClass:NSString.class]) return;
    NSData *data = [notification.object dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > 2048) return;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class]) return;
    NSSet *keys = [NSSet setWithArray:[value allKeys]];
    NSSet *required = [NSSet setWithArray:@[@"version",@"protocol",@"command",@"view",@"nonce",@"accepted",@"state",@"width",@"height",@"corrections"]];
    NSMutableSet *allowed = [required mutableCopy];
    [allowed addObjectsFromArray:@[@"axCode", @"selectionEpoch", @"clipTitle"]];
    if (![required isSubsetOfSet:keys] || ![keys isSubsetOfSet:allowed] ||
        !SSWindowInteger(value[@"version"],1) || !SSWindowInteger(value[@"protocol"],1) ||
        !SSWindowInteger(value[@"width"],615) || !(SSWindowInteger(value[@"height"],704) || SSWindowInteger(value[@"height"],736)) ||
        ![value[@"view"] isEqual:self.viewID] || ![value[@"nonce"] isEqual:self.nonce] ||
        ![@[@"attach",@"renew",@"selection"] containsObject:value[@"command"]] ||
        ![value[@"accepted"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value[@"accepted"]) != CFBooleanGetTypeID() ||
        ![value[@"state"] isKindOfClass:NSString.class] || [value[@"state"] length] > 32) return;
    id count = value[@"corrections"];
    double numeric = [count isKindOfClass:NSNumber.class] ? [count doubleValue] : NAN;
    if (!isfinite(numeric) || numeric < 0 || numeric > 1000000000 || floor(numeric) != numeric ||
        CFGetTypeID((__bridge CFTypeRef)count) == CFBooleanGetTypeID()) return;
    id code = value[@"axCode"];
    if (code && (![code isKindOfClass:NSNumber.class] || !isfinite([code doubleValue]) ||
        floor([code doubleValue]) != [code doubleValue] || CFGetTypeID((__bridge CFTypeRef)code) == CFBooleanGetTypeID())) return;
    id title = value[@"clipTitle"];
    if (title && (![title isKindOfClass:NSString.class] || ![title length] ||
        [title lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 512 ||
        [title rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        ![value[@"accepted"] boolValue])) return;
    if (value[@"selectionEpoch"] && ![value[@"selectionEpoch"] isKindOfClass:NSString.class]) return;
    if ([value[@"command"] isEqual:@"selection"]) {
        if (self.selectionUpdate && [value[@"selectionEpoch"] isEqual:self.selectionEpoch]) {
            self.lastSelectionReply = [self now];
            self.selectionUpdate(title);
        }
        return;
    }
    if (title || value[@"selectionEpoch"]) return;
    self.acknowledged = [value[@"accepted"] boolValue];
    self.lastState = self.acknowledged ? value[@"state"] : @"unavailable";
    self.lastReply = [self now];
    // An expired or failed lease is retired by the helper. A still-visible
    // view recovers with a fresh nonce; delayed replies to the old lease drop.
    if (!self.acknowledged) {
        self.nonce = NSUUID.UUID.UUIDString;
        self.attachFailures = MIN(6, self.attachFailures + 1);
        self.nextAttach = [self now] + fmin(30, pow(2, self.attachFailures - 1));
    } else if ([self.lastState isEqual:@"fixed"]) {
        self.attachFailures = 0;
        self.nextAttach = 0;
    }
}
- (void)stop {
    if (!self.active) return;
    if (self.launched) [self send:@"detach"];
    self.active = NO;
    self.launched = NO;
    self.acknowledged = NO;
    self.attachFailures = 0;
    self.nextAttach = 0;
    self.generation += 1;
    [self stopTimer];
    [self endObserving];
    self.launcher = nil;
    self.nonce = nil;
    self.lastState = @"stopped";
    self.lastSelectionReply = 0;
}
- (void)dealloc {
    [self.timer invalidate];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    // The worker also expires any lease after 3.5 seconds if a host terminates
    // without delivering viewWillDisappear.
}
@end
