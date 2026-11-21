//
//  NVCoreSupervisor.m
//  navigatiod
//

#import "NVCoreSupervisor.h"
#import "NIPCFrame.h"
#import <Foundation/Foundation.h>
#import <sys/wait.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <spawn.h>
#import <netdb.h>       // Исправлено: добавлено для struct addrinfo
#import <sys/time.h>    // Исправлено: добавлено для gettimeofday

extern char **environ;

@interface NVCoreSupervisor ()
@property (nonatomic, assign) pid_t corePID;
@property (nonatomic, strong) NSString *configPath;
@property (nonatomic, strong) dispatch_source_t watchdogSource;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end

@implementation NVCoreSupervisor

- (instancetype)init {
    if ((self = [super init])) {
        _ioQueue = dispatch_queue_create("com.navigatio.core.io", DISPATCH_QUEUE_SERIAL);
        _corePath = [self defaultCorePath];
        _coreType = [self detectCoreType];
        _lastError = nil;
    }
    return self;
}

- (NSString *)defaultCorePath {
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

- (NVCoreType)detectCoreType {
    if ([_corePath rangeOfString:@"sing-box"].location != NSNotFound) return NVCoreTypeSingBox;
    return NVCoreTypeXray;
}

- (BOOL)startWithConfig:(NSDictionary *)config coreType:(NVCoreType)type error:(NSError **)error {
    if (_running) { _lastError = @"Core already running"; if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-1 userInfo:@{NSLocalizedDescriptionKey: _lastError}]; return NO; }

    _coreType = type;
    _corePath = (type == NVCoreTypeSingBox) ? @"/usr/local/lib/navigatio/bin/sing-box" : @"/usr/local/lib/navigatio/bin/xray";

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:_corePath]) {
        _lastError = [NSString stringWithFormat:@"Core binary not found at %@", _corePath];
        if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-2 userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }

    NSError *writeError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingSortedKeys error:&writeError];
    if (!json) { _lastError = writeError.localizedDescription; if (error) *error = writeError; return NO; }

    _configPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"navigatio-core-%d.json", getpid()]];
    if (![json writeToFile:_configPath atomically:YES]) {
        _lastError = @"Failed to write core config";
        if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-3 userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }

    const char *exe = _corePath.UTF8String;
    const char *arg1 = (_coreType == NVCoreTypeSingBox) ? "run" : "-config";
    const char *arg2 = _configPath.UTF8String;
    char *argv[] = { (char *)exe, (char *)arg1, (char *)arg2, NULL };

    posix_spawn_file_actions_t file_actions;
    posix_spawn_file_actions_init(&file_actions);
    posix_spawn_file_actions_addopen(&file_actions, STDOUT_FILENO, "/var/log/navigatio/core.out.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&file_actions, STDERR_FILENO, "/var/log/navigatio/core.err.log", O_WRONLY|O_CREAT|O_APPEND, 0644);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, &file_actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&file_actions);

    if (rc != 0) {
        _lastError = [NSString stringWithFormat:@"posix_spawn failed: %s", strerror(rc)];
        if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-4 userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }

    _corePID = pid;

    _watchdogSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _ioQueue);
    dispatch_source_set_timer(_watchdogSource, dispatch_walltime(NULL, 0), 5ull * NSEC_PER_SEC, 0);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_watchdogSource, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.corePID <= 0) return;
        int status;
        pid_t r = waitpid(strongSelf.corePID, &status, WNOHANG);
        if (r == strongSelf.corePID) {
            [strongSelf coreDidExitWithCode:WEXITSTATUS(status)];
        }
    });
    dispatch_resume(_watchdogSource);

    usleep(300 * 1000);

    if (error) *error = nil;
    _lastError = nil;
    _running = YES;
    return YES;
}

- (void)stop {
    dispatch_async(_ioQueue, ^{
        if (_watchdogSource) {
            dispatch_source_cancel(_watchdogSource);
            _watchdogSource = nil;
        }
        if (_corePID > 0) {
            kill(_corePID, SIGTERM);
            for (int i = 0; i < 20; i++) {
                if (waitpid(_corePID, NULL, WNOHANG) == _corePID) break;
                usleep(100 * 1000);
            }
            if (waitpid(_corePID, NULL, WNOHANG) != _corePID) {
                kill(_corePID, SIGKILL);
                waitpid(_corePID, NULL, 0);
            }
        }
        _corePID = 0;
        _running = NO;
        if (_configPath) {
            [[NSFileManager defaultManager] removeItemAtPath:_configPath error:nil];
            _configPath = nil;
        }
    });
}

- (void)coreDidExitWithCode:(int)code {
    if (code != 0 && code != SIGTERM && code != SIGKILL) {
        _lastError = [NSString stringWithFormat:@"Core exited unexpectedly with code %d", code];
        NSLog(@"navigatiod: %@", _lastError);
    }
    _corePID = 0;
    _running = NO;
}

- (NSNumber *)tcpPingHost:(NSString *)host port:(uint16_t)port error:(NSError **)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return nil; }

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host.UTF8String, &addr.sin_addr) != 1) {
        struct addrinfo hints = {0}, *res = NULL;
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(host.UTF8String, NULL, &hints, &res) != 0 || !res) {
            close(fd);
            if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"DNS resolution failed"}];
            return nil;
        }
        addr.sin_addr = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
        freeaddrinfo(res);
    }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct timeval start;
    gettimeofday(&start, NULL);

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return nil;
    }

    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);
    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    rc = select(fd + 1, NULL, &wfds, NULL, &timeout);
    if (rc <= 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:@"NVCoreSupervisor" code:-6 userInfo:@{NSLocalizedDescriptionKey: @"TCP connect timeout"}];
        return nil;
    }

    int so_error = 0;
    socklen_t len = sizeof(so_error);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &len);
    close(fd);

    if (so_error != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:so_error userInfo:nil];
        return nil;
    }

    struct timeval end;
    gettimeofday(&end, NULL);
    long ms = (end.tv_sec - start.tv_sec) * 1000 + (end.tv_usec - start.tv_usec) / 1000;
    return @(ms);
}

- (NSDictionary *)status {
    return @{
        @"running": @(_running),
        @"coreType": @(_coreType),
        @"corePath": _corePath ?: [NSNull null],
        @"pid": _corePID > 0 ? @(_corePID) : [NSNull null],
        @"lastError": _lastError ?: [NSNull null]
    };
}

@end
