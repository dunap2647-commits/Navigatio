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
#import <sys/wait.h>

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

- (BOOL)bringUpWithCoreInboundPort:(uint16_t)port
                         tun2socksPath:(NSString *)tun2socksPath
                            error:(NSError **)error {
    @try {
        [self forceRollback];

        NSError *setupErr = nil;
        NSString *tunName = [self createUTun:&setupErr];
        if (!tunName) {
            if (error) *error = [NSError errorWithDomain:@"NVRouteManager"
                                                    code:NVRouteErrorTunCreate
                                                userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot create utun"}];
            return NO;
        }
        _tunName = tunName;

        if (![self configureInterface:_tunName error:&setupErr]) {
            [self forceRollback];
            if (error) *error = [NSError errorWithDomain:@"NVRouteManager"
                                                  code:NVRouteErrorTunSetup
                                               userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot configure utun"}];
            return NO;
        }

        if (![self launchTun2Socks:port tun2socksPath:tun2socksPath error:&setupErr]) {
            [self forceRollback];
            if (error) *error = [NSError errorWithDomain:@"NVRouteManager"
                                                  code:NVRouteErrorTun2Socks
                                               userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot launch tun2socks"}];
            return NO;
        }

        if (![self replaceDefaultRoute:&setupErr]) {
            [self forceRollback];
            if (error) *error = [NSError errorWithDomain:@"NVRouteManager"
                                                  code:NVRouteErrorRouteAdd
                                               userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot replace default route"}];
            return NO;
        }

        if (![self updateDNS:&setupErr]) {
            [self forceRollback];
            if (error) *error = [NSError errorWithDomain:@"NVRouteManager"
                                                  code:NVRouteErrorDNS
                                               userInfo:@{NSLocalizedDescriptionKey: setupErr.localizedDescription ?: @"cannot set DNS"}];
            return NO;
        }

        [[NSFileManager defaultManager] createFileAtPath:kRollbackMarker contents:[NSData data] attributes:nil];
        _active = YES;
        return YES;
    } @catch (NSException *e) {
        [self forceRollback];
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager"
                                                code:NVRouteErrorRollback
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unexpected exception: %@", e.reason]}];
        return NO;
    }
}

- (void)tearDown {
    [self forceRollback];
}

- (void)forceRollback {
    dispatch_async(_ioQueue, ^{
        if (_tun2socksPID > 0) {
            kill(_tun2socksPID, SIGTERM);
            usleep(200 * 1000);
            if (kill(_tun2socksPID, 0) == 0) kill(_tun2socksPID, SIGKILL);
            waitpid(_tun2socksPID, NULL, WNOHANG);
            _tun2socksPID = 0;
        }

        if (_tunFD >= 0) { close(_tunFD); _tunFD = -1; }

        if (_tunName) {
            [self deleteInterface:_tunName];
            _tunName = nil;
        }

        if (_defaultRouteReplaced) {
            [self restoreDefaultRoute];
            _defaultRouteReplaced = NO;
        }

        [self restoreDNS];
        [[NSFileManager defaultManager] removeItemAtPath:kRollbackMarker error:nil];
        _active = NO;
    });
}

- (NSDictionary *)diagnostics {
    return @{
        @"active": @(_active),
        @"tunName": _tunName ?: [NSNull null],
        @"error": _lastError ?: [NSNull null],
        @"errorCode": @(_lastErrorCode)
    };
}

#pragma mark - Private

- (NSString *)createUTun:(NSError **)error {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return nil; }

    struct ctl_info ci = {0};
    strlcpy(ci.ctl_name, UTUN_CONTROL_NAME, sizeof(ci.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &ci) != 0) { 
        close(fd); 
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; 
        return nil; 
    }

    struct sockaddr_ctl sc = {0};
    sc.sc_id = ci.ctl_id;
    sc.sc_len = sizeof(sc);
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_unit = 0;

    if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) != 0) { 
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; 
        return nil; 
    }

    int unit = 0;
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, NULL, &(socklen_t){0}) == 0) {
        /* unit already assigned by kernel */
    }

    struct ifreq ifr = {0};
    ifr.ifr_data = (caddr_t)&unit;
    if (ioctl(fd, SIOCGIFNAME, &ifr) == 0) {
        _tunFD = fd;
        return [NSString stringWithUTF8String:ifr.ifr_name];
    }

    for (int u = 0; u < 32; u++) {
        char name[16];
        snprintf(name, sizeof(name), "utun%d", u);
        int testFD = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
        if (testFD < 0) continue;
        if (ioctl(testFD, SIOCGIFNAME, &(struct ifreq){.ifr_name = {0}}) == 0 && strncmp(name, "utun", 4) == 0) {
            _tunFD = testFD;
            close(fd);
            return [NSString stringWithUTF8String:name];
        }
        close(testFD);
    }

    _tunFD = fd;
    return [NSString stringWithFormat:@"utun%d", unit];
}

- (BOOL)configureInterface:(NSString *)ifname error:(NSError **)error {
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "ifconfig %s 10.255.0.1 10.255.0.2 up", ifname.UTF8String);
    return [self runShell:cmd error:error];
}

- (BOOL)launchTun2Socks:(uint16_t)port tun2socksPath:(NSString *)path error:(NSError **)error {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-1
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tun2socks not found at %@", path]}];
        return NO;
    }

    char portStr[32];
    snprintf(portStr, sizeof(portStr), "127.0.0.1:%hu", port);
    
    char *argv[] = {
        (char *)path.UTF8String,
        "-interface", (char *)_tunName.UTF8String,
        "-proxy", portStr,
        "-log", "/var/log/navigatio/tun2socks.log",
        NULL
    };

    posix_spawn_file_actions_t file_actions;
    posix_spawn_file_actions_init(&file_actions);
    posix_spawn_file_actions_addopen(&file_actions, STDOUT_FILENO, "/var/log/navigatio/tun2socks.out.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&file_actions, STDERR_FILENO, "/var/log/navigatio/tun2socks.err.log", O_WRONLY|O_CREAT|O_APPEND, 0644);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.UTF8String, &file_actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&file_actions);

    if (rc != 0) {
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-2
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"posix_spawn tun2socks failed: %s", strerror(rc)]}];
        return NO;
    }

    _tun2socksPID = pid;
    return YES;
}

- (BOOL)replaceDefaultRoute:(NSError **)error {
    NSString *result = nil;
    const char *sh = "/bin/sh";
    char *argv[] = { (char *)sh, "-c", "/usr/sbin/route -n get default 2>&1", NULL };
    
    FILE *fp = popen("/usr/sbin/route -n get default 2>&1", "r");
    if (fp) {
        char buf[512];
        NSMutableString *outStr = [NSMutableString string];
        while (fgets(buf, sizeof(buf), fp)) {
            [outStr appendString:[NSString stringWithUTF8String:buf]];
        }
        pclose(fp);
        result = outStr;
    }
    
    if (!result) {
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"failed to run route"}];
        return NO;
    }

    NSString *gateway = nil;
    for (NSString *line in [result componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"   gateway: "]) {
            gateway = [line substringFromIndex:11];
            break;
        }
    }
    if (!gateway) { 
        if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"no default gateway found"}]; 
        return NO; 
    }

    _savedDefaultGateway = gateway;

    if (![self runShell:[NSString stringWithFormat:@"route add -host 127.0.0.1 -interface lo0"] error:error]) return NO;

    if (![self runShell:[NSString stringWithFormat:@"route delete default %@", gateway] error:error]) return NO;
    if (![self runShell:[NSString stringWithFormat:@"route add default %@", _tunName] error:error]) return NO;

    _defaultRouteReplaced = YES;
    return YES;
}

- (void)restoreDefaultRoute {
    if (_savedDefaultGateway) {
        [self runShell:[NSString stringWithFormat:@"route delete default %@", _tunName ?: @"utun0"] error:nil];
        [self runShell:[NSString stringWithFormat:@"route add default %@", _savedDefaultGateway] error:nil];
    } else {
        [self runShell:[NSString stringWithFormat:@"route delete default %@", _tunName ?: @"utun0"] error:nil];
    }
    _savedDefaultGateway = nil;
}

- (BOOL)updateDNS:(NSError **)error {
    NSError *rErr = nil;
    NSString *content = [NSString stringWithContentsOfFile:@"/etc/resolv.conf" encoding:NSUTF8StringEncoding error:&rErr];
    if (!rErr && content) {
        _savedDNSServers = [NSMutableArray array]; 
        for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"nameserver "]) {
                [_savedDNSServers addObject:[line stringByReplacingOccurrencesOfString:@"nameserver " withString:@""]];
            }
        }
    }

    NSString *newConf = @"nameserver 127.0.0.1\noptions timeout:2 attempts:3\n";
    NSError *wErr = nil;
    if (![newConf writeToFile:@"/etc/resolv.conf" atomically:YES encoding:NSUTF8StringEncoding error:&wErr]) {
        if (error) *error = wErr; return NO;
    }
    return YES;
}

- (void)restoreDNS {
    if (_savedDNSServers.count > 0) {
        NSMutableString *lines = [NSMutableString string];
        for (NSString *s in _savedDNSServers) {
            [lines appendFormat:@"nameserver %@\n", s];
        }
        [lines writeToFile:@"/etc/resolv.conf" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:@"/etc/resolv.conf" error:nil];
    }
}

- (BOOL)deleteInterface:(NSString *)ifname {
    return [self runShell:[NSString stringWithFormat:@"ifconfig %s down", ifname.UTF8String] error:nil];
}

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

- (void)dealloc {
    [self forceRollback];
}

@end
