#import "bridge_lease.h"
/* Scope: own diagnostic probe, or Preferences with explicit owner consent and expiring gate.
 * Genuine AAAbsintheSigner on owner's Mac; no fabricated signature, account result or TLS changes.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import "nac_reply.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <dlfcn.h>
#include <unistd.h>
static const char *gate="/var/mobile/Library/Preferences/org.hackicloud.signer.json";
static NSString *nonce;
static BOOL allowAccount;
static NSLock *ioLock;
static int provider=-1;
static uint64_t sequence;
static void (*original)(id,SEL,NSData *,void (^)(NSData *,NSError *));
static void status(const char *s){FILE*f=fopen("/var/mobile/Library/Logs/hackicloud-signer-status.txt","a");if(f){fprintf(f,"%s\n",s);fclose(f);}}
static BOOL readAll(int fd,void *p,size_t n){while(n){ssize_t k=read(fd,p,n);if(k<=0)return NO;p=(char*)p+k;n-=k;}return YES;}
static BOOL writeAll(int fd,const void *p,size_t n){while(n){ssize_t k=write(fd,p,n);if(k<=0)return NO;p=(const char*)p+k;n-=k;}return YES;}
static NSData *readFrame(int fd){uint32_t n;if(!readAll(fd,&n,4))return nil;n=ntohl(n);if(!n||n>32768)return nil;NSMutableData*d=[NSMutableData dataWithLength:n];return readAll(fd,d.mutableBytes,n)?d:nil;}
static BOOL sendJSON(int fd,id obj){NSData*d=[NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];if(!d.length||d.length>1500000)return NO;uint32_t n=htonl((uint32_t)d.length);return writeAll(fd,&n,4)&&writeAll(fd,d.bytes,d.length);}
static NSData *signature(NSData *body){
 [ioLock lock];int fd=__atomic_load_n(&provider,__ATOMIC_ACQUIRE);NSData *result=nil;
 if(fd>=0 && HBridgeLeaseValid(gate,nonce,501,allowAccount,NSDate.date.timeIntervalSince1970)){
  uint64_t request=++sequence;unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(body.bytes,(CC_LONG)body.length,hash);
  NSMutableString *digest=[NSMutableString new];for(unsigned i=0;i<sizeof(hash);i++)[digest appendFormat:@"%02x",hash[i]];
  if(sendJSON(fd,@{@"op":@"nac-sign",@"nonce":nonce,@"request":@(request),@"body":[body base64EncodedStringWithOptions:0]})){
   NSData *wire=readFrame(fd);if(wire)result=HNACSignatureFromReply(wire,nonce,request,digest,NSDate.date.timeIntervalSince1970);
  }
  if(!result){close(fd);__atomic_store_n(&provider,-1,__ATOMIC_RELEASE);}
 }
 [ioLock unlock];return result;
}
static void hook(id self,SEL cmd,NSData *body,void (^completion)(NSData *,NSError *)){
 BOOL eligible=completion && [body isKindOfClass:NSData.class] && body.length && body.length<=1048576 &&
  HBridgeLeaseValid(gate,nonce,501,allowAccount,NSDate.date.timeIntervalSince1970) && __atomic_load_n(&provider,__ATOMIC_ACQUIRE)>=0;
 if(!allowAccount)eligible=eligible && [body isEqual:[@"HakiOS anonymous NAC capability test; no account data" dataUsingEncoding:NSUTF8StringEncoding]];
 if(!eligible){original(self,cmd,body,completion);return;}
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
  NSData *result=signature(body);
  if(result){status("native Mac signature returned; values omitted");completion(result,nil);}
  else {status("provider unavailable or invalid reply; using original signer");original(self,cmd,body,completion);}
 }});
}
__attribute__((constructor))static void install(void){@autoreleasepool{
 BOOL diagnostic=!strcmp(getprogname(),"hakios_iosnacprobe");if(!diagnostic && strcmp(getprogname(),"Preferences"))return;
 NSDictionary *cfg=HBridgeLoadConfiguration(gate,501,!diagnostic,NSDate.date.timeIntervalSince1970);
 if(!cfg)return;
 nonce=cfg[@"nonce"];allowAccount=!diagnostic;
 if(!dlopen("/System/Library/PrivateFrameworks/AppleAccount.framework/AppleAccount",RTLD_NOW))return;
 Method method=class_getInstanceMethod(NSClassFromString(@"AAAbsintheSigner"),@selector(signatureForData:completion:));
 if(!method||strcmp(method_getTypeEncoding(method),"v32@0:8@16@?24"))return;
 int listener=socket(AF_INET,SOCK_STREAM,0);if(listener<0)return;int one=1;setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
 struct sockaddr_in a={0};a.sin_len=sizeof(a);a.sin_family=AF_INET;a.sin_port=htons(19836);a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
 if(bind(listener,(struct sockaddr*)&a,sizeof(a))||listen(listener,1)){close(listener);return;}
 ioLock=[NSLock new];original=(void*)method_setImplementation(method,(IMP)hook);
 status(diagnostic?"diagnostic listener ready; synthetic data only":"Preferences listener ready; owner-authorized session; payload logging disabled");
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{for(;;){int peer=accept(listener,NULL,NULL);if(peer<0)break;@autoreleasepool{
  struct timeval timeout={3,0};setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(peer,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
  NSData *w=readFrame(peer);id hello=w?[NSJSONSerialization JSONObjectWithData:w options:0 error:NULL]:nil;
  if(![hello isKindOfClass:NSDictionary.class]||![hello[@"nonce"] isEqual:nonce]){close(peer);continue;}
  timeout.tv_sec=40;setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(peer,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
  [ioLock lock];int prior=__atomic_load_n(&provider,__ATOMIC_RELAXED);if(prior>=0)close(prior);
  BOOL ok=sendJSON(peer,@{@"ready":@YES});__atomic_store_n(&provider,ok?peer:-1,__ATOMIC_RELEASE);if(!ok)close(peer);[ioLock unlock];
 }}close(listener);});
 if(diagnostic){NSDate*limit=[NSDate dateWithTimeIntervalSinceNow:12];while(__atomic_load_n(&provider,__ATOMIC_ACQUIRE)<0 && limit.timeIntervalSinceNow>0)usleep(10000);}
}}
