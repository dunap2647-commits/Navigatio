#import "NVCoreSupervisor.h"
#import "NIPCFrame.h"
#import <sys/wait.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
@interface NSTask : NSObject
@property (copy) NSString *launchPath;
@property (copy) NSArray<NSString *> *arguments;
@property (retain) id standardOutput;
@property (retain) id standardError;
@property (readonly) int processIdentifier;
@property (readonly, getter=isRunning) BOOL running;
@property (readonly) int terminationStatus;
@property (copy) void (^terminationHandler)(NSTask *);
• (void)launch;
• (void)waitUntilExit;
@end
@interface NVCoreSupervisor ()
@property (nonatomic, strong, nullable) NSTask *coreTask;
@property (nonatomic, strong, nullable) NSString *configPath;
@property (nonatomic, assign) int corePID;
@property (nonatomic, strong, nullable) dispatch_source_t watchdogSource;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end
@implementation NVCoreSupervisor
• (instancetype)init {
if ((self = [super init])) {
_ioQueue = dispatch_queue_create("com.navigatio.core.io", DISPATCH_QUEUE_SERIAL);
_corePath = [self defaultCorePath];
_coreType = [self detectCoreType];
_lastError = nil;
}
return self;
}
• (NSString *)defaultCorePath {
NSArray *candidates = @[
@"/usr/local/lib/navigatio/bin/sing-box",
@"/usr/local/lib/navigatio/bin/xray",
@"/usr/bin/sing-box",
@"/usr/bin/xray"
];
for (NSString *p in candidates) {
if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
}
return candidates.firstObject;
}
• (NVCoreType)detectCoreType {
if ([_corePath rangeOfString:@"sing-box"].location != NSNotFound) return NVCoreTypeSingBox;
return NVCoreTypeXray;
}
• (BOOL)isRunning {
return (_coreTask != nil && [_coreTask isRunning]);
}
• (BOOL)startWithConfig:(NSDictionary *)config coreType:(NVCoreType)type error:(NSError **)error {
if (self.isRunning) {
_lastError = @"Core already running";
if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-1 userInfo:@{NSLocalizedDescriptionKey: _lastError}];
return NO;
}_coreType = type;
_corePath = (type == NVCoreTypeSingBox) ? @"/usr/local/lib/navigatio/bin/sing-box" : @"/usr/local/lib/navigatio/bin/xray";if (![[NSFileManager defaultManager] isExecutableFileAtPath:_corePath]) {
_lastError = [NSString stringWithFormat:@"Core binary not found at %@", _corePath];
if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-2 userInfo:@{NSLocalizedDescriptionKey: _lastError}];
return NO;
}NSError *writeError = nil;
NSData *json = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&writeError];
if (!json) {
_lastError = writeError.localizedDescription;
if (error) *error = writeError;
return NO;
}_configPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"navigatio-core-%d.json", getpid()]];
if (![json writeToFile:_configPath atomically:YES]) {
_lastError = @"Failed to write core config";
if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-3 userInfo:@{NSLocalizedDescriptionKey: _lastError}];
return NO;
}[[NSFileManager defaultManager] createDirectoryAtPath:@"/var/log/navigatio" withIntermediateDirectories:YES attributes:nil error:nil];
[[NSFileManager defaultManager] createFileAtPath:@"/var/log/navigatio/core.out.log" contents:nil attributes:nil];
[[NSFileManager defaultManager] createFileAtPath:@"/var/log/navigatio/core.err.log" contents:nil attributes:nil];NSTask *task = [NSTask new];
task.launchPath = _corePath;
if (_coreType == NVCoreTypeSingBox) {
task.arguments = @[@"run", @"-c", _configPath];
} else {
task.arguments = @[@"-config", _configPath];
}
task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:@"/var/log/navigatio/core.out.log"];
task.standardError = [NSFileHandle fileHandleForWritingAtPath:@"/var/log/navigatio/core.err.log"];_coreTask = task;
__weak typeof(self) weakSelf = self;
task.terminationHandler = ^(NSTask *t) {
dispatch_async(weakSelf.ioQueue, ^{
[weakSelf coreDidExitWithCode:(int)t.terminationStatus];
});
};@try {
[task launch];
} @catch (NSException *ex) {
_lastError = ex.reason ?: @"Failed to launch core process";
if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-4 userInfo:@{NSLocalizedDescriptionKey: _lastError}];
return NO;
}_corePID = task.processIdentifier;_watchdogSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _ioQueue);
dispatch_source_set_timer(_watchdogSource, dispatch_walltime(NULL, 0), 5ull * NSEC_PER_SEC, 0);
dispatch_source_set_event_handler(_watchdogSource, ^{
typeof(self) strongSelf = weakSelf;
if (strongSelf && strongSelf.coreTask && ![strongSelf.coreTask isRunning]) {
[strongSelf coreDidExitWithCode:(int)strongSelf.coreTask.terminationStatus];
}
});
dispatch_resume(_watchdogSource);usleep(300 * 1000);
if (error) *error = nil;
_lastError = nil;
return YES;
}
• (void)stop {
dispatch_sync(_ioQueue, ^{
if (_watchdogSource) {
dispatch_source_cancel(_watchdogSource);
_watchdogSource = nil;
}
if (_coreTask && [_coreTask isRunning]) {
kill(_corePID, SIGTERM);
for (int i = 0; i < 20; i++) {
if (![_coreTask isRunning]) break;
usleep(100 * 1000);
}
if ([_coreTask isRunning]) kill(_corePID, SIGKILL);
}
_coreTask = nil;
_corePID = 0;
if (_configPath) {
[[NSFileManager defaultManager] removeItemAtPath:_configPath error:nil];
_configPath = nil;
}
});
}
• (void)coreDidExitWithCode:(int)code {
if (code != 0 && code != SIGTERM && code != SIGKILL) {
_lastError = [NSString stringWithFormat:@"Core exited unexpectedly with code %d", code];
NSLog(@"navigatiod: %@", _lastError);
}
_corePID = 0;
_coreTask = nil;
}
• (NSNumber *)tcpPingHost:(NSString *)host port:(uint16_t)port error:(NSError **)error {
if (!host || host.length == 0 || port == 0) {
if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-7 userInfo:@{NSLocalizedDescriptionKey: @"Invalid host or port"}];
return nil;
}int fd = socket(AF_INET, SOCK_STREAM, 0);
if (fd < 0) {
if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
return nil;
}int on = 1;
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));struct sockaddr_in addr = {0};
addr.sin_family = AF_INET;
addr.sin_port = htons(port);
if (inet_pton(AF_INET, host.UTF8String, &addr.sin_addr) != 1) {
struct addrinfo hints = {0}, *res = NULL;hints.ai_family = AF_INET;
hints.ai_socktype = SOCK_STREAM;
if (getaddrinfo(host.UTF8String, NULL, &hints, &res) != 0 || !res) {
close(fd);
if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"DNS resolution failed"}];
return nil;
}
addr.sin_addr = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
freeaddrinfo(res);
}int flags = fcntl(fd, F_GETFL, 0);
fcntl(fd, F_SETFL, flags | O_NONBLOCK);struct timeval start;
gettimeofday(&start, NULL);int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
if (rc < 0 && errno != EINPROGRESS) {
close(fd);
if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
return nil;
}fd_set wfds;
FD_ZERO(&wfds);
FD_SET(fd, &wfds);
struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
rc = select(fd + 1, NULL, &wfds, NULL, &timeout);
if (rc <= 0) {
close(fd);
if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-6 userInfo:@{NSLocalizedDescriptionKey: @"TCP connect timeout"}];
return nil;
}int so_error = 0;
socklen_t len = sizeof(so_error);
getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &len);
close(fd);if (so_error != 0) {
if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:so_error userInfo:nil];
return nil;
}struct timeval end;
gettimeofday(&end, NULL);
long ms = (end.tv_sec - start.tv_sec) * 1000 + (end.tv_usec - start.tv_usec) / 1000;
return @(ms);
}
• (NSDictionary *)status {
return @{
@"running": @(self.isRunning),
@"coreType": @(_coreType),
@"corePath": _corePath ?: [NSNull null],
@"pid": _corePID > 0 ? @(_corePID) : [NSNull null],
@"lastError": _lastError ?: [NSNull null]
};
}
@end
