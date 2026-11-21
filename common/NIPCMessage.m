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
