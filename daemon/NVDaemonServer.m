#import "NVDaemonServer.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import "NIPCFrame.h"
#import "NIPCMessage.h"
#import "NVCoreSupervisor.h"
#import "NVRouteManager.h"

@implementation NVDaemonServer {
    int _listenFD;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _ioQueue;
    NVCoreSupervisor *_supervisor;
    NVRouteManager *_routeManager;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _ioQueue = dispatch_queue_create("com.navigatio.daemon.ipc", DISPATCH_QUEUE_CONCURRENT);
        _supervisor = [NVCoreSupervisor new];
        _routeManager = [NVRouteManager new];
    }
    return self;
}

- (BOOL)startOnPath:(NSString *)path error:(NSError **)error {
    struct stat st;
    mode_t oldMask = umask(0077);
    if (stat(path.fileSystemRepresentation, &st) == 0) unlink(path.fileSystemRepresentation);
    
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { umask(oldMask); if (error) *error = [self posixError]; return NO; }
    
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
        int err = errno; close(fd); umask(oldMask);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
        return NO;
    }
    
    umask(oldMask);
    chown(path.fileSystemRepresentation, 0, 501);
    chmod(path.fileSystemRepresentation, 0660);
    _listenFD = fd;
    
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _ioQueue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{ [weakSelf acceptOne]; });
    dispatch_resume(_acceptSource);
    return YES;
}

- (NSError *)posixError {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
}

- (void)acceptOne {
    struct sockaddr_un peer; socklen_t len = sizeof(peer);
    int client = accept(_listenFD, (struct sockaddr *)&peer, &len);
    if (client < 0) return;
    
    uid_t uid = 0; gid_t gid = 0;
    if (getpeereid(client, &uid, &gid) != 0 || uid != 501) {
        close(client);
        return;
    }
    dispatch_async(_ioQueue, ^{ [self handleClient:client]; });
}

- (void)handleClient:(int)client {
    char *buf = malloc(NIPC_MAX_FRAME + 1);
    if (!buf) { close(client); return; }
    size_t len = 0;
    if (nipc_recv_frame(client, buf, NIPC_MAX_FRAME + 1, &len) == 0) {
        NSError *jsonError = nil;
        NSDictionary *request = NIPCDictionaryFromJSON(buf, &jsonError);
        NSString *response = [self responseForRequest:request];
        nipc_send_frame(client, response.UTF8String, strlen(response.UTF8String));
    }
    free(buf);
    close(client);
}

- (NSString *)responseForRequest:(NSDictionary *)request {
    if (!request) return NIPCResponseJSON(0, NO, nil, @"invalid JSON", NIPC_ERROR_INVALID_JSON);
    
    uint64_t mid = [request[@"id"] unsignedLongLongValue];
    NSString *method = request[@"method"];
    NSDictionary *params = request[@"params"];
    if (![params isKindOfClass:[NSDictionary class]]) params = @{};

    if ([method isEqualToString:@"status"]) {
        return NIPCResponseJSON(mid, YES, [_supervisor status], nil, 0);
    }
    if ([method isEqualToString:@"connect"]) {
        NSError *err = nil;
        NSDictionary *config = params[@"config"];
        uint16_t socksPort = [params[@"socksPort"] unsignedShortValue] ?: 10808;
        NVCoreType type = [params[@"coreType"] integerValue];
        
        if (![config isKindOfClass:[NSDictionary class]]) {
            return NIPCResponseJSON(mid, NO, nil, @"Missing config dictionary", NIPC_ERROR_INVALID_JSON);
        }
        if (![_supervisor startWithConfig:config coreType:type error:&err]) {
            return NIPCResponseJSON(mid, NO, nil, err.localizedDescription ?: @"core start failed", NIPC_ERROR_INTERNAL);
        }
        // Исправлено: убран аргумент serverAddress
        if (![_routeManager bringUpWithCoreInboundPort:socksPort
                                        tun2socksPath:@"/usr/local/lib/navigatio/bin/tun2socks"
                                               error:&err]) {
            [_supervisor stop];
            return NIPCResponseJSON(mid, NO, nil, err.localizedDescription ?: @"route setup failed", NIPC_ERROR_INTERNAL);
        }
        return NIPCResponseJSON(mid, YES, [_supervisor status], nil, 0);
    }
    if ([method isEqualToString:@"disconnect"]) {
        [_routeManager tearDown];
        [_supervisor stop];
        return NIPCResponseJSON(mid, YES, [_supervisor status], nil, 0);
    }
    if ([method isEqualToString:@"ping"]) {
        NSError *err = nil;
        NSNumber *ms = [_supervisor tcpPingHost:params[@"address"] port:[params[@"port"] unsignedShortValue] error:&err];
        if (!ms) return NIPCResponseJSON(mid, NO, nil, err.localizedDescription ?: @"timeout", NIPC_ERROR_INTERNAL);
        return NIPCResponseJSON(mid, YES, @{ @"latencyMs": ms }, nil, 0);
    }
    return NIPCResponseJSON(mid, NO, nil, [NSString stringWithFormat:@"unknown method %@", method], NIPC_ERROR_BAD_METHOD);
}

- (void)stop {
    if (_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; }
    if (_listenFD >= 0) { close(_listenFD); _listenFD = -1; }
    [_routeManager tearDown];
    [_supervisor stop];
}

@end
