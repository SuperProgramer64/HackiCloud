#import <Foundation/Foundation.h>
#include <sys/types.h>
BOOL HBridgeLeaseValid(const char*,NSString*,uid_t,BOOL,NSTimeInterval);
/* Loading a dormant listener is allowed after expiry; using it still requires a fresh lease. */
NSDictionary *HBridgeLoadConfiguration(const char*,uid_t,BOOL,NSTimeInterval);
BOOL HBridgePrivateFlagEnabled(const char*,uid_t);
