//
//  NVRouteManager.m
//  navigatiod
//

#import "NVRouteManager.h"
#import <Foundation/Foundation.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <net/if.h>
#import <netinet/in.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <spawn.h>

extern char **environ;

// === Определения, отсутствующие в iOS SDK ===
#ifndef PF_SYSTEM
#define PF_SYSTEM 32
#endif
#ifndef AF_SYS_CONTROL
#define AF_SYS_CONTROL 2
#endif
#ifndef SYSPROTO_CONTROL
#define SYSPROTO_CONTROL 2
#endif
#define CTLIOCGINFO 0xc0644e03UL
struct ctl_info {
    u_int32_t ctl_id;
    char ctl_name[96];
};
struct sockaddr_ctl {
    u_char sc_len;
    u_char sc_family;
    u_int16_t ss_sysaddr;
    u_int32_t sc_id;
    u_int32_t sc_unit;
    u_int32_t sc_reserved[5];
};
#define UTUN_CONTROL_NAME "com.apple.net.utun_control"
#define UTUN_OPT_IFNAME 2
// =============================================

#define kRollbackMarker @"/var/run/navigatiod.active"

@interface NVRouteManager ()
@property (nonatomic, assign) pid_t tun2socksPID;
@property (nonatomic, assign) int tunFD;
@property (nonatomic, assign) BOOL defaultRouteReplaced;
@property (nonatomic, strong) NSMutableArray *savedDNSServers;
@property (nonatomic, strong) NSString *savedDefaultGateway;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end

@implementation NVRouteManager

- (instancetype)init {
    if ((self = [super init])) {
        _tunFD = -1;
        _defaultRouteReplaced = NO;
        _ioQueue = dispatch_queue_create("com.navigatio.route.io", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// bringUpWithCoreInboundPort... (без изменений, кроме launchTun2Socks)
// ...

- (BOOL)launchTun2Socks:(uint16_t)port tun2socksPath:(NSString *)path error:(NSError **)error {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-1
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tun2socks not found at %@", path]}];
        return NO;
    }

    char portStr[16];
    snprintf(portStr, sizeof(portStr), "127.0.0.1:%hu", port);
    char *argv[] = {
        (char *)path.UTF8String,
        "-interface", (char *)_tunName.UTF8String,
        "-proxy", portStr,
        "-log", "/var/log/navigatio/tun2socks.log",
        NULL
    };

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.UTF8String, NULL, NULL, argv, environ);
    if (rc != 0) {
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-2
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"posix_spawn tun2socks failed: %s", strerror(rc)]}];
        return NO;
    }

    _tun2socksPID = pid;
    return YES;
}

// В forceRollback заменяем kill NSTask на kill PID
- (void)forceRollback {
    dispatch_async(_ioQueue, ^{
        if (_tun2socksPID > 0) {
            kill(_tun2socksPID, SIGTERM);
            usleep(200 * 1000);
            if (kill(_tun2socksPID, 0) == 0) kill(_tun2socksPID, SIGKILL);
            waitpid(_tun2socksPID, NULL, WNOHANG);
            _tun2socksPID = 0;
        }
        // ... остальное без изменений
    });
}

// runShell через posix_spawn (замена NSTask)
- (BOOL)runShell:(NSString *)command error:(NSError **)error {
    const char *sh = "/bin/sh";
    char *argv[] = { (char *)sh, "-c", (char *)command.UTF8String, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, sh, NULL, NULL, argv, environ);
    if (rc != 0) {
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:rc
            userInfo:@{NSLocalizedDescriptionKey: command}];
        return NO;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:WEXITSTATUS(status)
            userInfo:@{NSLocalizedDescriptionKey: command}];
        return NO;
    }
    return YES;
}

// createUTun использует определённые выше структуры, код остаётся прежним
// (замените #import <sys/kern_control.h> на эти определения)

@end
