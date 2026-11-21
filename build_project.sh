#!/bin/bash
set -e

echo "1. Создаю структуру директорий..."
mkdir -p layout/DEBIAN \
         layout/Library/LaunchDaemons \
         layout/usr/local/lib/navigatio/bin \
         layout/usr/local/lib/navigatio/geo \
         common \
         daemon \
         app/Sources/IPC \
         docs

echo "2. Записываю корневые файлы (Makefile, control)..."

cat << 'EOF' > Makefile
export ARCHS = arm64
export TARGET = iphone:clang:latest:12.0
export THEOS_PACKAGE_SCHEME =
export THEOS_DEVICE_IP := 192.168.1.10

INSTALL_TARGET_PROCESSES = navigatiod

# app временно закомментирован, пока не готовы файлы интерфейса
SUBPROJECTS += common daemon

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
EOF

cat << 'EOF' > control
Package: com.navigatio.proxy
Name: Navigatio
Version: 0.1.0
Architecture: iphoneos-arm
Description: Lightweight anti-DPI proxy client & daemon for iOS 12
Maintainer: Navigatio Dev
Author: Navigatio Dev
Section: Networking
Depends: firmware (>= 12.0)
EOF

echo "3. Записываю LaunchDaemon и скрипты установки (postinst, postrm)..."

cat << 'EOF' > layout/Library/LaunchDaemons/com.navigatio.daemon.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://apple.com">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.navigatio.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/libexec/navigatiod</string>
        <string>--socket</string><string>/var/run/navigatiod.sock</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>/var/log/navigatio/daemon.out.log</string>
    <key>StandardErrorPath</key><string>/var/log/navigatio/daemon.err.log</string>
</dict>
</plist>
EOF

cat << 'EOF' > layout/DEBIAN/postinst
#!/bin/sh
mkdir -p /var/log/navigatio
chown root:wheel /usr/libexec/navigatiod
chmod 755 /usr/libexec/navigatiod
chmod 644 /Library/LaunchDaemons/com.navigatio.daemon.plist
chown root:wheel /Library/LaunchDaemons/com.navigatio.daemon.plist
launchctl unload /Library/LaunchDaemons/com.navigatio.daemon.plist 2>/dev/null || true
launchctl load -w /Library/LaunchDaemons/com.navigatio.daemon.plist
exit 0
EOF

cat << 'EOF' > layout/DEBIAN/postrm
#!/bin/sh
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    launchctl unload /Library/LaunchDaemons/com.navigatio.daemon.plist 2>/dev/null || true
    rm -f /var/run/navigatiod.sock /var/run/navigatiod.active
fi
exit 0
EOF

chmod 755 layout/DEBIAN/postinst layout/DEBIAN/postrm

echo "4. Записываю общий модуль (common/)..."

cat << 'EOF' > common/Makefile
LIBRARY_NAME = navigatioipc
navigatioipc_LINKAGE_TYPE = static
navigatioipc_ARCHIVE_EXTENSION = a
navigatioipc_FILES = NIPCFrame.c NIPCMessage.m
navigatioipc_CFLAGS = -fobjc-arc -I.
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk
EOF

cat << 'EOF' > common/NIPCFrame.h
#ifndef NIPCFRAME_H
#define NIPCFRAME_H
#include <sys/types.h>
#include <stddef.h>

#define NIPC_SOCKET_PATH "/var/run/navigatiod.sock"
#define NIPC_MAX_FRAME   (256 * 1024)

int nipc_send_frame(int fd, const void *data, size_t len);
int nipc_recv_frame(int fd, char *out, size_t cap, size_t *outLen);

#endif
EOF

cat << 'EOF' > common/NIPCFrame.c
#include "NIPCFrame.h"
#include <sys/socket.h>
#include <errno.h>
#include <arpa/inet.h>

static int read_exact(int fd, void *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, (char *)buf + got, len - got, 0);
        if (n == 0) return -1;
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        got += (size_t)n;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, (const char *)buf + sent, len - sent, 0);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        sent += (size_t)n;
    }
    return 0;
}

int nipc_send_frame(int fd, const void *data, size_t len) {
    if (len == 0 || len > NIPC_MAX_FRAME) return -1;
    uint32_t be = htonl((uint32_t)len);
    if (write_exact(fd, &be, 4) != 0) return -1;
    return write_exact(fd, data, len);
}

int nipc_recv_frame(int fd, char *out, size_t cap, size_t *outLen) {
    uint32_t be = 0;
    if (read_exact(fd, &be, 4) != 0) return -1;
    uint32_t len = ntohl(be);
    if (len == 0 || len > NIPC_MAX_FRAME || (size_t)len + 1 > cap) return -1;
    if (read_exact(fd, out, len) != 0) return -1;
    out[len] = '\0';
    if (outLen) *outLen = len;
    return 0;
}
EOF

cat << 'EOF' > common/NIPCMessage.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
#define NIPC_ERROR_INVALID_JSON   -1
#define NIPC_ERROR_UNAUTHORIZED   -2
#define NIPC_ERROR_BAD_METHOD     -3
#define NIPC_ERROR_INTERNAL       -4

NSString *NIPCResponseJSON(uint64_t mid, BOOL ok, NSDictionary *_Nullable result, NSString *_Nullable errorMessage, int errorCode);
NSDictionary *_Nullable NIPCDictionaryFromJSON(const char *bytes, NSError **error);
NS_ASSUME_NONNULL_END
EOF

cat << 'EOF' > common/NIPCMessage.m
#import "NIPCMessage.h"

NSDictionary *NIPCDictionaryFromJSON(const char *bytes, NSError **error) {
    NSData *data = [NSData dataWithBytes:bytes length:strlen(bytes)];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
}

NSString *NIPCResponseJSON(uint64_t mid, BOOL ok, NSDictionary *result, NSString *errorMessage, int errorCode) {
    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    root[@"id"] = @(mid);
    root[@"ok"] = @(ok);
    if (ok) {
        root[@"result"] = result ?: @{};
    } else {
        root[@"error"] = @{ @"code": @(errorCode),
                            @"message": errorMessage ?: @"unknown error" };
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{\"ok\":false}";
}
EOF

echo "5. Записываю модуль демона (daemon/) с исправлениями под iOS 12 SDK..."

cat << 'EOF' > daemon/Makefile
export ARCHS = arm64
TARGET = iphone:clang:latest:12.0

TOOL_NAME = navigatiod
navigatiod_INSTALL_PATH = /usr/libexec
navigatiod_FILES = main.m NVDaemonServer.m NVCoreSupervisor.m NVRouteManager.m \
                   ../common/NIPCFrame.c ../common/NIPCMessage.m
navigatiod_CFLAGS = -fobjc-arc -I../common -Wall -Wextra -Wno-unused-parameter
navigatiod_FRAMEWORKS = Foundation Security SystemConfiguration
navigatiod_CODESIGN_FLAGS = -S=entitlements.plist

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk
EOF

cat << 'EOF' > daemon/entitlements.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://apple.com">
<plist version="1.0">
<dict>
    <key>platform-application</key>
    <true/>
    <key>com.apple.private.security.no-container</key>
    <true/>
    <key>com.apple.private.security.no-sandbox</key>
    <true/>
    <key>com.apple.private.security.storage.AppDataContainers</key>
    <true/>
    <key>com.apple.private.network.socket-delegate</key>
    <true/>
</dict>
</plist>
EOF

cat << 'EOF' > daemon/NVDaemonServer.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NVDaemonServer : NSObject
- (BOOL)startOnPath:(NSString *)path error:(NSError **)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
EOF

cat << 'EOF' > daemon/main.m
#import <Foundation/Foundation.h>
#import <signal.h>
#import "NIPCFrame.h"
#import "NVDaemonServer.h"

static NVDaemonServer *gServer = nil;
static dispatch_source_t gTermSource;

static void handleSignal(int sig) {
    (void)sig;
    if (gTermSource) dispatch_source_merge_data(gTermSource, 1);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *socketPath = @NIPC_SOCKET_PATH;
        for (int i = 1; i < argc - 1; i++) {
            if (strcmp(argv[i], "--socket") == 0) {
                socketPath = [NSString stringWithUTF8String:argv[i + 1]];
            }
        }

        gServer = [NVDaemonServer new];
        NSError *err = nil;
        if (![gServer startOnPath:socketPath error:&err]) {
            fprintf(stderr, "navigatiod: cannot bind %s: %s\n",
                    socketPath.UTF8String, err.localizedDescription.UTF8String);
            return 1;
        }

        gTermSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0,
                                             dispatch_get_main_queue());
        dispatch_source_set_event_handler(gTermSource, ^{
            [gServer stop];
            CFRunLoopStop(CFRunLoopGetMain());
        });
        dispatch_resume(gTermSource);

        signal(SIGTERM, handleSignal);
        signal(SIGINT,  handleSignal);
        signal(SIGPIPE, SIG_IGN);

        CFRunLoopRun();
        return 0;
    }
}
EOF

cat << 'EOF' > daemon/NVCoreSupervisor.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NVCoreType) {
    NVCoreTypeXray = 0,
    NVCoreTypeSingBox = 1
};

@interface NVCoreSupervisor : NSObject

@property (nonatomic, readonly, strong) NSString *corePath;
@property (nonatomic, readonly) NVCoreType coreType;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, copy, nullable) NSString *lastError;

- (BOOL)startWithConfig:(NSDictionary *)config coreType:(NVCoreType)type error:(NSError **)error;
- (void)stop;
- (nullable NSNumber *)tcpPingHost:(NSString *)host port:(uint16_t)port error:(NSError **)error;
- (NSDictionary *)status;
- (void)coreDidExitWithCode:(int)code;

@end

NS_ASSUME_NONNULL_END
EOF

cat << 'EOF' > daemon/NVCoreSupervisor.m
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
EOF
cat << 'EOF' > daemon/NVRouteManager.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, NVRouteError) {
NVRouteErrorNone = 0,
NVRouteErrorTunCreate = -1,
NVRouteErrorTunSetup = -2,
NVRouteErrorRouteAdd = -3,
NVRouteErrorDNS = -4,
NVRouteErrorTun2Socks = -5,
NVRouteErrorRollback = -6
};
@interface NVRouteManager : NSObject
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, readonly, copy, nullable) NSString *tunName;
@property (nonatomic, readonly, copy, nullable) NSString *lastError;
@property (nonatomic, readonly) int lastErrorCode;
• (BOOL)bringUpWithCoreInboundPort:(uint16_t)port
serverAddress:(nullable NSString *)serverIP
tun2socksPath:(NSString *)path
error:(NSError **)error;
• (void)tearDown;
• (void)forceRollback;
• (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
EOF
cat << 'EOF' > daemon/NVRouteManager.m
#import "NVRouteManager.h"
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <net/if.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#ifndef AF_SYSTEM
#define AF_SYSTEM 32
#define PF_SYSTEM AF_SYSTEM
#endif
#ifndef SYSPROTO_CONTROL
#define SYSPROTO_CONTROL 2
#endif
#ifndef AF_SYS_CONTROL
#define AF_SYS_CONTROL 2
#endif
#ifndef UTUN_CONTROL_NAME
#define UTUN_CONTROL_NAME "com.apple.net.utun_control"
#endif
#ifndef UTUN_OPT_IFNAME
#define UTUN_OPT_IFNAME 2
#endif
#ifndef CTLIOCGINFO
#define CTLIOCGINFO 0xc0644e03UL
#endif
struct nv_ctl_info {
uint32_t ctl_id;
char ctl_name[96];
};
struct nv_sockaddr_ctl {
uint8_t sc_len;
uint8_t sc_family;
uint16_t ss_sysaddr;
uint32_t sc_id;
uint32_t sc_unit;
uint32_t sc_reserved[5];
};
@interface NSTask : NSObject
@property (copy) NSString *launchPath;
@property (copy) NSArray<NSString *> *arguments;
@property (retain) id standardOutput;
@property (retain) id standardError;
@property (readonly) int processIdentifier;
@property (readonly, getter=isRunning) BOOL running;
@property (readonly) int terminationStatus;
• (void)launch;
• (void)waitUntilExit;
@end
#define kRollbackMarker @"/var/run/navigatiod.active"
@interface NVRouteManager ()
@property (nonatomic, strong, nullable) NSTask *tun2socksTask;
@property (nonatomic, assign) int tunFD;
@property (nonatomic, assign) BOOL defaultRouteReplaced;
@property (nonatomic, copy, nullable) NSString *savedDefaultGateway;
@property (nonatomic, copy, nullable) NSString *bypassServerIP;
@property (nonatomic, strong, nullable) NSArray<NSString *> *savedDNSServers;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end
@implementation NVRouteManager
• (instancetype)init {
if ((self = [super init])) {
_tunFD = -1;
_defaultRouteReplaced = NO;
_ioQueue = dispatch_queue_create("com.navigatio.route.io", DISPATCH_QUEUE_SERIAL);
}
return self;
}
• (BOOL)bringUpWithCoreInboundPort:(uint16_t)port
serverAddress:(NSString *)serverIP
tun2socksPath:(NSString *)tun2socksPath
error:(NSError **)error {
@try {
[self forceRollback];
_bypassServerIP = serverIP;NSError *setupErr = nil;
NSString *tunName = [self createUTun:&setupErr];
if (!tunName) {
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:NVRouteErrorTunCreate userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot create utun"}];
return NO;
}
_tunName = tunName;if (![self configureInterface:_tunName error:&setupErr]) {
[self forceRollback];
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:NVRouteErrorTunSetup userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot configure utun"}];
return NO;
}if (![self launchTun2Socks:port tun2socksPath:tun2socksPath error:&setupErr]) {
[self forceRollback];
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:NVRouteErrorTun2Socks userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot launch tun2socks"}];
return NO;
}if (![self replaceDefaultRoute:&setupErr]) {
[self forceRollback];
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:NVRouteErrorRouteAdd userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot replace default route"}];
return NO;
}if (![self updateDNS:&setupErr]) {
[self forceRollback];
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:NVRouteErrorDNS userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot set DNS"}];
return NO;
}[@"1" writeToFile:kRollbackMarker atomically:YES encoding:NSUTF8StringEncoding error:nil];
_active = YES;
return YES;
} @catch (NSException *e) {
[self forceRollback];
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:NVRouteErrorRollback userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"Exception"}];
return NO;
}
}
• (void)tearDown {
[self forceRollback];
}
• (void)forceRollback {
dispatch_sync(_ioQueue, ^{
if (_tun2socksTask && [_tun2socksTask isRunning]) {
kill([_tun2socksTask processIdentifier], SIGTERM);
usleep(200 * 1000);
if ([_tun2socksTask isRunning]) kill([_tun2socksTask processIdentifier], SIGKILL);
}
_tun2socksTask = nil;if (_tunFD >= 0) { close(_tunFD); _tunFD = -1; }if (_tunName) {
[self deleteInterface:_tunName];
_tunName = nil;
}if (_defaultRouteReplaced) {
[self restoreDefaultRoute];
_defaultRouteReplaced = NO;
}[self restoreDNS];
[[NSFileManager defaultManager] removeItemAtPath:kRollbackMarker error:nil];
_active = NO;
});
}
• (NSDictionary *)diagnostics {
return @{
@"active": @(_active),
@"tunName": _tunName ?: [NSNull null],
@"error": _lastError ?: [NSNull null],
@"errorCode": @(_lastErrorCode)
};
}
• (NSString *)createUTun:(NSError **)error {
int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
if (fd < 0) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return nil; }struct nv_ctl_info ci = {0};
strlcpy(ci.ctl_name, UTUN_CONTROL_NAME, sizeof(ci.ctl_name));
if (ioctl(fd, CTLIOCGINFO, &ci) != 0) {
int err = errno; close(fd);
if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
return nil;
}struct nv_sockaddr_ctl sc = {0};sc.sc_id = ci.ctl_id;
sc.sc_len = sizeof(sc);
sc.sc_family = AF_SYSTEM;sc.ss_sysaddr = AF_SYS_CONTROL;
sc.sc_unit = 0;if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) != 0) {
int err = errno; close(fd);
if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
return nil;
}char ifname[32] = {0};
socklen_t ifnameLen = sizeof(ifname);
if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &ifnameLen) == 0 && strlen(ifname) > 0) {
_tunFD = fd;
return [NSString stringWithUTF8String:ifname];
}_tunFD = fd;
return @"utun0";
}
• (BOOL)configureInterface:(NSString *)ifname error:(NSError **)error {
NSString *cmd = [NSString stringWithFormat:@"ifconfig %@ 10.255.0.1 10.255.0.2 mtu 1500 up", ifname];
return [self runShell:cmd error:error];
}
• (BOOL)launchTun2Socks:(uint16_t)port tun2socksPath:(NSString *)path error:(NSError **)error {
if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tun2socks not found at %@", path]}];
return NO;
}[[NSFileManager defaultManager] createFileAtPath:@"/var/log/navigatio/tun2socks.out.log" contents:nil attributes:nil];
[[NSFileManager defaultManager] createFileAtPath:@"/var/log/navigatio/tun2socks.err.log" contents:nil attributes:nil];NSTask *task = [NSTask new];
task.launchPath = path;
task.arguments = @[@"-device", _tunName,
@"-proxy", [NSString stringWithFormat:@"socks5://127.0.0.1:%hu", port]];
task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:@"/var/log/navigatio/tun2socks.out.log"];
task.standardError = [NSFileHandle fileHandleForWritingAtPath:@"/var/log/navigatio/tun2socks.err.log"];_tun2socksTask = task;
@try {
[task launch];
return YES;
} @catch (NSException *ex) {
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-2 userInfo:@{NSLocalizedDescriptionKey: ex.reason ?: @"tun2socks failed"}];
return NO;
}
}
• (BOOL)replaceDefaultRoute:(NSError **)error {
NSTask *task = [[NSTask alloc] init];
task.launchPath = @"/usr/sbin/route";
task.arguments = @[@"-n", @"get", @"default"];
NSPipe *pipe = [NSPipe pipe];
task.standardOutput = pipe;
[task launch];
NSData *out = [pipe fileHandleForReading].readDataToEndOfFile;
[task waitUntilExit];
NSString *result = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];NSString *gateway = nil;
for (NSString *line in [result componentsSeparatedByString:@"\n"]) {
NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
if ([trimmed hasPrefix:@"gateway:"]) {
gateway = [[trimmed substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
break;
}
}
if (!gateway || gateway.length == 0) {
if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"no default gateway found"}];
return NO;
}_savedDefaultGateway = gateway;if (_bypassServerIP && _bypassServerIP.length > 0) {
[self runShell:[NSString stringWithFormat:@"route add -host %@ %@", _bypassServerIP, gateway] error:nil];
}if (![self runShell:@"route delete default" error:error]) return NO;
if (![self runShell:[NSString stringWithFormat:@"route add default -interface %@", _tunName] error:error]) return NO;_defaultRouteReplaced = YES;
return YES;
}
• (void)restoreDefaultRoute {
[self runShell:@"route delete default" error:nil];
if (_savedDefaultGateway) {
[self runShell:[NSString stringWithFormat:@"route add default %@", _savedDefaultGateway] error:nil];
}
if (_bypassServerIP && _bypassServerIP.length > 0) {
[self runShell:[NSString stringWithFormat:@"route delete -host %@", _bypassServerIP] error:nil];
}
_savedDefaultGateway = nil;
}
• (BOOL)updateDNS:(NSError **)error {
NSString *content = [NSString stringWithContentsOfFile:@"/etc/resolv.conf" encoding:NSUTF8StringEncoding error:nil];
if (content) {
NSMutableArray *servers = [NSMutableArray array];
for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
if ([line hasPrefix:@"nameserver "]) {
[servers addObject:[line stringByReplacingOccurrencesOfString:@"nameserver " withString:@""]];
}
}
_savedDNSServers = servers;
}NSString *newConf = @"nameserver 1.1.1.1\nnameserver 8.8.8.8\n";
NSError *wErr = nil;
if (![newConf writeToFile:@"/etc/resolv.conf" atomically:YES encoding:NSUTF8StringEncoding error:&wErr]) {
if (error) *error = wErr;
return NO;
}
return YES;
}
• (void)restoreDNS {
if (_savedDNSServers.count > 0) {
NSMutableString *lines = [NSMutableString string];
for (NSString *s in _savedDNSServers) {
[lines appendFormat:@"nameserver %@\n", s];
}
[lines writeToFile:@"/etc/resolv.conf" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
}
• (BOOL)deleteInterface:(NSString *)ifname {
return [self runShell:[NSString stringWithFormat:@"ifconfig %@ down", ifname] error:nil];
}
• (BOOL)runShell:(NSString *)command error:(NSError **)error {
NSTask *task = [[NSTask alloc] init];
task.launchPath = @"/bin/sh";
task.arguments = @[@"-c", command];
[task launch];
[task waitUntilExit];
if (task.terminationStatus != 0 && error) {
*error = [NSError errorWithDomain:@"NVRouteManager" code:(int)task.terminationStatus userInfo:@{NSLocalizedDescriptionKey: command}];
return NO;
}
return YES;
}
• (void)dealloc {
[self forceRollback];
}
@end
EOF
cat << 'EOF' > daemon/NVDaemonServer.m
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
• (instancetype)init {
if ((self = [super init])) {
_listenFD = -1;
_ioQueue = dispatch_queue_create("com.navigatio.daemon.ipc", DISPATCH_QUEUE_CONCURRENT);
_supervisor = [NVCoreSupervisor new];
_routeManager = [NVRouteManager new];
}
return self;
}
• (BOOL)startOnPath:(NSString *)path error:(NSError **)error {
struct stat st;
mode_t oldMask = umask(0077);
if (stat(path.fileSystemRepresentation, &st) == 0) unlink(path.fileSystemRepresentation);int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
if (fd < 0) { umask(oldMask); if (error) *error = [self posixError]; return NO; }struct sockaddr_un addr = {0};
addr.sun_family = AF_UNIX;
strncpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path) - 1);
if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
listen(fd, 16) != 0) {
int err = errno; close(fd); umask(oldMask);
if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
return NO;
}
umask(oldMask);
chown(path.fileSystemRepresentation, 0, 501);
chmod(path.fileSystemRepresentation, 0660);
_listenFD = fd;_acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _ioQueue);
__weak typeof(self) weakSelf = self;
dispatch_source_set_event_handler(_acceptSource, ^{ [weakSelf acceptOne]; });
dispatch_resume(_acceptSource);
return YES;
}
• (NSError *)posixError {
return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
}
• (void)acceptOne {
struct sockaddr_un peer; socklen_t len = sizeof(peer);
int client = accept(_listenFD, (struct sockaddr *)&peer, &len);
if (client < 0) return;uid_t uid = 0; gid_t gid = 0;
if (getpeereid(client, &uid, &gid) != 0 || uid != 501) {
close(client);
return;
}
dispatch_async(_ioQueue, ^{ [self handleClient:client]; });
}
• (void)handleClient:(int)client {
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
• (NSString *)responseForRequest:(NSDictionary *)request {
if (!request) return NIPCResponseJSON(0, NO, nil, @"invalid JSON", NIPC_ERROR_INVALID_JSON);
uint64_t mid = [request[@"id"] unsignedLongLongValue];
NSString *method = request[@"method"];
NSDictionary *params = request[@"params"];
if (![params isKindOfClass:[NSDictionary class]]) params = @{};if ([method isEqualToString:@"status"]) {
return NIPCResponseJSON(mid, YES, [_supervisor status], nil, 0);
}
if ([method isEqualToString:@"connect"]) {
NSError *err = nil;
NSDictionary *config = params[@"config"];
NSString *serverIP = params[@"serverAddress"];
uint16_t socksPort = [params[@"socksPort"] unsignedShortValue] ?: 10808;
NVCoreType type = [params[@"coreType"] integerValue];if (![config isKindOfClass:[NSDictionary class]]) {
return NIPCResponseJSON(mid, NO, nil, @"Missing config dictionary", NIPC_ERROR_INVALID_JSON);
}
if (![_supervisor startWithConfig:config coreType:type error:&err]) {
return NIPCResponseJSON(mid, NO, nil, err.localizedDescription ?: @"core start failed", NIPC_ERROR_INTERNAL);
}
if (![_routeManager bringUpWithCoreInboundPort:socksPort
serverAddress:serverIP
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
• (void)stop {
if (_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; }
if (_listenFD >= 0) { close(_listenFD); _listenFD = -1; }
[_routeManager tearDown];
[_supervisor stop];
}
@end
EOF
echo "6. Записываю клиент IPC для будущего приложения (app/Sources/IPC/)..."
cat << 'EOF' > app/Sources/IPC/NVIPCClient.swift
import Foundation
public enum NIPCError: LocalizedError {
case daemonUnreachable
case protocolFailure(String)
public var errorDescription: String? {
switch self {
case .daemonUnreachable: return "Демон Navigatio не отвечает. Проверьте, что он установлен и запущен."
case .protocolFailure(let m): return m
}
}
}
public final class NVIPCClient {
public static let shared = NVIPCClient()
private let queue = DispatchQueue(label: "com.navigatio.ipc.client")
private var nextID: UInt64 = 1
private let socketPath = NIPC_SOCKET_PATH
private init() {}
public func call(_ method: String,
params: [String: Any] = [:],
completion: @escaping (Result<[String: Any], Error>) -> Void) {
queue.async {
let id = self.nextID
self.nextID += 1
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
DispatchQueue.main.async { completion(.failure(NIPCError.daemonUnreachable)) }
return
}
defer { close(fd) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { p in
_ = strcpy(p, self.socketPath)
}
}
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) {
$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
}
}
guard connected else {
self.deliver(.failure(NIPCError.daemonUnreachable), completion)
return
}
let payload: [String: Any] = ["id": id, "method": method, "params": params]
guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []),
nipc_send_frame(fd, (encoded as NSData).bytes, encoded.count) == 0 else {
self.deliver(.failure(NIPCError.protocolFailure("Не удалось отправить запрос демону")), completion)
return
}
let cap = Int(NIPC_MAX_FRAME) + 1
let buffer = UnsafeMutablePointer.allocate(capacity: cap)
defer { buffer.deallocate() }
var received: Int = 0
let recvResult = nipc_recv_frame(fd, buffer, cap, &received)
guard recvResult == 0 else {
self.deliver(.failure(NIPCError.protocolFailure("Демон закрыл соединение до ответа")), completion)
return
}
let data = Data(bytes: buffer, count: received)
guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
self.deliver(.failure(NIPCError.protocolFailure("Некорректный ответ демона")), completion)
return
}
if let ok = obj["ok"] as? Bool, ok {
let result = obj["result"] as? [String: Any] ?? [:]
self.deliver(.success(result), completion)
} else {
let errorDict = obj["error"] as? [String: Any]
let message = errorDict?["message"] as? String ?? "Неизвестная ошибка демона"
self.deliver(.failure(NIPCError.protocolFailure(message)), completion)
}
}
}
private func deliver(_ result: Result<[String: Any], Error>,
_ completion: @escaping (Result<[String: Any], Error>) -> Void) {
DispatchQueue.main.async { completion(result) }
}
}
EOF
echo "=== Все файлы разложены и исправлены! ==="
echo "Теперь можно запускать: make package"

---

### Что дальше после запуска скрипта:
Сразу в том же окне терминала введите:
```bash
make package
