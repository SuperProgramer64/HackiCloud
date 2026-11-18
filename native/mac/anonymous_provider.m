#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <sys/resource.h>
#include <unistd.h>
@interface NSObject (AOSStream)
+ (NSDictionary *)retrieveOTPHeadersForDSID:(NSString *)dsid;
@end
static BOOL writeAll(const void *p,size_t n){while(n){ssize_t k=write(1,p,n);if(k<=0)return NO;p=(const char*)p+k;n-=k;}return YES;}
int main(void){@autoreleasepool{
 struct rlimit noCore={0,0};setrlimit(RLIMIT_CORE,&noCore);alarm(1800);
 if(!dlopen("/System/Library/PrivateFrameworks/AOSKit.framework/AOSKit",RTLD_NOW))return 2;
 Class cls=NSClassFromString(@"AOSUtilities");if(![cls respondsToSelector:@selector(retrieveOTPHeadersForDSID:)])return 3;
 unsigned char op;
 while(read(0,&op,1)==1){@autoreleasepool{
  if(op==0)return 0;if(op!=1)return 4;alarm(10);
  NSDictionary *headers=[cls retrieveOTPHeadersForDSID:@"-2"];
  NSString *mid=headers[@"X-Apple-MD-M"],*otp=headers[@"X-Apple-MD"];
  if(![mid isKindOfClass:NSString.class]||![otp isKindOfClass:NSString.class]||!mid.length||!otp.length)return 5;
  NSDictionary *row=@{@"mid":mid,@"otp":otp,@"routing":@84215040,@"issued":@(NSDate.date.timeIntervalSince1970)};
  NSData *wire=[NSJSONSerialization dataWithJSONObject:row options:0 error:NULL];if(!wire.length||wire.length>32768)return 6;
  uint32_t size=htonl((uint32_t)wire.length);if(!writeAll(&size,4)||!writeAll(wire.bytes,wire.length))return 7;
  alarm(1800);
 }}return 0;
}}
