#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
#define NIPC_ERROR_INVALID_JSON   -1
#define NIPC_ERROR_UNAUTHORIZED   -2
#define NIPC_ERROR_BAD_METHOD     -3
#define NIPC_ERROR_INTERNAL       -4

NSString *NIPCResponseJSON(uint64_t mid, BOOL ok, NSDictionary *_Nullable result, NSString *_Nullable errorMessage, int errorCode);
NSDictionary *_Nullable NIPCDictionaryFromJSON(const char *bytes, NSError **error);
NS_ASSUME_NONNULL_END
