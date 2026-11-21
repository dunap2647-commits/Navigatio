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
