//
//  NVRouteManager.m
//  navigatiod
//

#import "NVRouteManager.h"
#import <sys/ioctl.h>
#import <sys/kern_control.h> // Исправлено: заменено net/if_utun.h
#import <net/if.h>
#import <netinet/in.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>

// Определяем константы утуна вручную, так как они приватные
#ifndef UTUN_CONTROL_NAME
#define UTUN_CONTROL_NAME "com.apple.net.utun_control"
#endif
#ifndef UTUN_OPT_IFNAME
#define UTUN_OPT_IFNAME 2
#endif

#define kRouteDstDefault  @"0.0.0.0"
#define kRollbackMarker   @"/var/run/navigatiod.active"

@interface NVRouteManager ()
@property (nonatomic, strong) NSTask *tun2socksTask;
@property (nonatomic, assign) int tunFD;
@property (nonatomic, assign) BOOL defaultRouteReplaced;
@property (nonatomic, strong) NSMutableArray *savedDNSServers;
@property (nonatomic, strong) NSString *savedSearchDomains;
@property (nonatomic, strong) NSString *savedDefaultGateway;
@property (nonatomic, assign) uint32_t savedDefaultMetric;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@end

@implementation NVRouteManager

- (instancetype)init {
    if ((self = [super init])) {
        _tunFD = -1;
        _defaultRouteReplaced = NO;
        _savedDefaultMetric = 0;
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
        if (_tun2socksTask && [_tun2socksTask isRunning]) {
            kill([_tun2socksTask processIdentifier], SIGTERM);
            usleep(200 * 1000);
            if ([_tun2socksTask isRunning]) kill([_tun2socksTask processIdentifier], SIGKILL);
        }
        _tun2socksTask = nil;

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

    NSTask *task = [NSTask new];
    task.launchPath = path;
    task.arguments = @[@"-interface", _tunName,
                       @"-proxy", [NSString stringWithFormat:@"127.0.0.1:%hu", port],
                       @"-log", @"/var/log/navigatio/tun2socks.log"];
    task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:@"/var/log/navigatio/tun2socks.out.log"];
    task.standardError = [NSFileHandle fileHandleForWritingAtPath:@"/var/log/navigatio/tun2socks.err.log"];

    _tun2socksTask = task;
    BOOL ok = [task launch];
    if (!ok && error) {
        *error = [NSError errorWithDomain:@"NVRouteManager" code:-2
            userInfo:@{NSLocalizedDescriptionKey: @"tun2socks failed to launch"}];
    }
    return ok;
}

- (BOOL)replaceDefaultRoute:(NSError **)error {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/sbin/route";
    task.arguments = @[@"-n", @"get", @"default"];
    task.standardOutput = [NSPipe pipe];
    [task launch];
    NSData *out = [[task standardOutput] fileHandleForReading].availableData;
    [task waitUntilExit];
    NSString *result = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];

    NSString *gateway = nil;
    for (NSString *line in [result componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"   gateway: "]) {
            gateway = [line substringFromIndex:11];
            break;
        }
    }
    if (!gateway) { if (error) *error = [NSError errorWithDomain:@"NVRouteManager" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"no default gateway found"}]; return NO; }

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
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-c", command];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    [task launch];
    [task waitUntilExit];
    if (task.terminationStatus != 0 && error) {
        *error = [NSError errorWithDomain:@"NVRouteManager" code:(int)task.terminationStatus
            userInfo:@{NSLocalizedDescriptionKey: command}];
        return NO;
    }
    return YES;
}

- (void)dealloc {
    [self forceRollback];
}

@end
