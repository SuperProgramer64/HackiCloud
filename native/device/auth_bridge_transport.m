#import "auth_bridge_transport.h"
#import "auth_bridge_data.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
static NSLock *ioLock;
static NSString *sessionNonce;
static int provider=-1;
static uint64_t sequence;
static BOOL readAll(int fd,void *p,size_t n){while(n){ssize_t k=read(fd,p,n);if(k<=0)return NO;p=(char*)p+k;n-=k;}return YES;}
static BOOL writeAll(int fd,const void *p,size_t n){while(n){ssize_t k=write(fd,p,n);if(k<=0)return NO;p=(const char*)p+k;n-=k;}return YES;}
static NSData *readFrame(int fd){uint32_t n;if(!readAll(fd,&n,4))return nil;n=ntohl(n);if(!n||n>32768)return nil;NSMutableData *d=[NSMutableData dataWithLength:n];return readAll(fd,d.mutableBytes,n)?d:nil;}
static BOOL writeFrame(int fd,NSData *d){if(!d.length||d.length>32768)return NO;uint32_t n=htonl((uint32_t)d.length);return writeAll(fd,&n,4)&&writeAll(fd,d.bytes,d.length);}
BOOL HAuthBridgeReady(void){return __atomic_load_n(&provider,__ATOMIC_ACQUIRE)>=0;}
BOOL HAuthBridgeStart(NSString *nonce){
 if(ioLock || nonce.length!=32)return NO;
 int listener=socket(AF_INET,SOCK_STREAM,0);if(listener<0)return NO;
 int reuse=1;setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
 struct sockaddr_in a={0};a.sin_len=sizeof(a);a.sin_family=AF_INET;a.sin_port=htons(19835);a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
 if(bind(listener,(struct sockaddr*)&a,sizeof(a)) || listen(listener,1)){close(listener);return NO;}
 sessionNonce=[nonce copy];ioLock=[NSLock new];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  for(;;){int peer=accept(listener,NULL,NULL);if(peer<0)break;
   @autoreleasepool{
    int one=1;struct timeval timeout={3,0};setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(peer,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    NSData *wire=readFrame(peer);id hello=wire?[NSJSONSerialization JSONObjectWithData:wire options:0 error:NULL]:nil;
    if(![hello isKindOfClass:NSDictionary.class] || ![hello[@"nonce"] isKindOfClass:NSString.class] || ![hello[@"nonce"] isEqual:sessionNonce]){close(peer);continue;}
    [ioLock lock];int previous=__atomic_load_n(&provider,__ATOMIC_RELAXED);if(previous>=0)close(previous);
    NSData *ready=[NSJSONSerialization dataWithJSONObject:@{@"ready":@YES} options:0 error:NULL];
    BOOL ok=writeFrame(peer,ready);__atomic_store_n(&provider,ok?peer:-1,__ATOMIC_RELEASE);if(!ok)close(peer);[ioLock unlock];
   }
  }close(listener);
 });return YES;
}
id HAuthBridgeFetch(void){
 if(!ioLock)return nil;[ioLock lock];int fd=__atomic_load_n(&provider,__ATOMIC_ACQUIRE);id data=nil;
 if(fd>=0){
  uint64_t request=++sequence;
  NSData *message=[NSJSONSerialization dataWithJSONObject:@{@"op":@"anisette",@"nonce":sessionNonce,@"request":@(request)} options:0 error:NULL];
  if(writeFrame(fd,message)){NSData *reply=readFrame(fd);if(reply)data=HAuthDataFromReply(reply,sessionNonce,request,NSDate.date.timeIntervalSince1970);}
  if(!data){close(fd);__atomic_store_n(&provider,-1,__ATOMIC_RELEASE);}
 }
 [ioLock unlock];return data;
}
