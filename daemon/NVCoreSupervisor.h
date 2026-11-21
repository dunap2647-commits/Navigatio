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
