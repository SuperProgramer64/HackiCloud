#import "bridge_lease.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
static NSDictionary *readPrivate(const char *path,uid_t owner){
 if(!path)return nil;
 int fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);if(fd<0)return nil;struct stat st;
 if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=owner||(st.st_mode&077)||st.st_size<=0||st.st_size>1024){close(fd);return nil;}
 char bytes[1025];ssize_t n=read(fd,bytes,sizeof(bytes));close(fd);if(n!=st.st_size)return nil;
 id d=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:(NSUInteger)n]options:0 error:NULL];
 return [d isKindOfClass:NSDictionary.class]?d:nil;
}
static BOOL trueBoolean(id value){return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()&&[value boolValue];}
NSDictionary *HBridgeLoadConfiguration(const char *path,uid_t owner,BOOL account,NSTimeInterval now){
 if(!isfinite(now))return nil;
 NSDictionary *d=readPrivate(path,owner);id nonce=d[@"nonce"];
 if(![nonce isKindOfClass:NSString.class]||[nonce length]!=32||[nonce rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]invertedSet]].location!=NSNotFound)return nil;
 id expiry=d[@"expires"];if(![expiry isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)expiry)==CFBooleanGetTypeID())return nil;
 double end=[expiry doubleValue];if(!isfinite(end)||end<=0||end>now+7200)return nil;
 if(account&&!trueBoolean(d[@"allow_account"]))return nil;
 return d;
}
BOOL HBridgeLeaseValid(const char *path,NSString *nonce,uid_t owner,BOOL account,NSTimeInterval now){
 NSDictionary *d=HBridgeLoadConfiguration(path,owner,account,now);
 return d&&[nonce isKindOfClass:NSString.class]&&[d[@"nonce"]isEqual:nonce]&&[d[@"expires"]doubleValue]>now;
}
BOOL HBridgePrivateFlagEnabled(const char *path,uid_t owner){
 return trueBoolean(readPrivate(path,owner)[@"enabled"]);
}
