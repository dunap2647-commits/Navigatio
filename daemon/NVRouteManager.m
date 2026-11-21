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
