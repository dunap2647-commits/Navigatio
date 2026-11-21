#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NVDaemonServer : NSObject
- (BOOL)startOnPath:(NSString *)path error:(NSError **)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
