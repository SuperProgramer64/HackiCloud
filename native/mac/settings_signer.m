/* Owner-authorized USB relay. Input and native signature remain in RAM; never log either. */
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <sys/resource.h>
#include <unistd.h>
@interface NSObject (NACPipe)
+ (id)sharedSigner;
- (void)signatureForData:(NSData *)data completion:(void (^)(NSData *,NSError *))completion;
@end
static unsigned done;
static BOOL readAll(int fd,void *p,size_t n){while(n){ssize_t k=read(fd,p,n);if(k<=0)return NO;p=(char*)p+k;n-=k;}return YES;}
static BOOL writeAll(int fd,const void *p,size_t n){while(n){ssize_t k=write(fd,p,n);if(k<=0)return NO;p=(const char*)p+k;n-=k;}return YES;}
int main(void){@autoreleasepool{
 struct rlimit noCore={0,0};setrlimit(RLIMIT_CORE,&noCore);alarm(40);
 uint32_t net;if(!readAll(0,&net,4))return 2;uint32_t size=ntohl(net);if(!size||size>1048576)return 3;
 NSMutableData *body=[NSMutableData dataWithLength:size];if(!readAll(0,body.mutableBytes,size))return 4;
 if(!dlopen("/System/Library/PrivateFrameworks/AppleAccount.framework/AppleAccount",RTLD_NOW))return 5;
 id signer=[NSClassFromString(@"AAAbsintheSigner") sharedSigner];
 [signer signatureForData:body completion:^(NSData *signature,NSError *error){
  BOOL ok=signature.length>=16 && signature.length<=16384 && !error;
  if(ok){uint32_t count=htonl((uint32_t)signature.length);ok=writeAll(1,&count,4)&&writeAll(1,signature.bytes,signature.length);}
  __atomic_store_n(&done,ok?1:2,__ATOMIC_RELEASE);
 }];
 NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:35];
 while(!__atomic_load_n(&done,__ATOMIC_ACQUIRE) && limit.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
 memset(body.mutableBytes,0,body.length);return done==1?0:6;
}}
