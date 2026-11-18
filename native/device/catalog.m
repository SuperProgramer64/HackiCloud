/* Anonymous catalog cache only. No Apple Account, password, SRP or download changes. */
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
@interface NSObject (HackiCloudCatalog)
- (id)initWithClientIdentifier:(id)client keychainAccessGroup:(id)group;
- (id)initWithClientIdentifier:(id)client keychainStore:(id)store;
- (id)initWithString:(id)text expirationDate:(id)date lifetime:(double)lifetime;
- (id)retrieveToken;
- (void)storeToken:(id)token;
- (NSString *)tokenString;
- (BOOL)isValid;
- (BOOL)isExpired;
- (NSDate *)expirationDate;
@end
@interface HackiCloudNoRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation HackiCloudNoRedirect
- (void)URLSession:(NSURLSession*)s task:(NSURLSessionTask*)t willPerformHTTPRedirection:(NSHTTPURLResponse*)r newRequest:(NSURLRequest*)q completionHandler:(void(^)(NSURLRequest*))done {done(nil);}
@end
static id cache(void){return [[NSClassFromString(@"AMSMediaTokenServiceKeychainStore") alloc] initWithClientIdentifier:@"appstore" keychainAccessGroup:@"apple"];}
static BOOL usable(id token){return token && [token isValid] && ![token isExpired] && [token expirationDate].timeIntervalSince1970>NSDate.date.timeIntervalSince1970+60;}
static int metadata(void){
 id token=[cache() retrieveToken];
 NSDictionary*data=@{@"present":@((BOOL)(token!=nil)),@"valid":@(usable(token)),@"expiry":@(token?[token expirationDate].timeIntervalSince1970:0)};
 NSData*wire=[NSJSONSerialization dataWithJSONObject:data options:0 error:NULL];if(!wire)return 3;
 printf("STATUS %.*s\n",(int)wire.length,(const char*)wire.bytes);return 0;
}
static int verify(NSString*token,const char*storefront){
 NSString*url=[NSString stringWithFormat:@"https://amp-api.apps.apple.com/v1/catalog/%s/apps/686449807?platform=iphone",storefront];
 NSMutableURLRequest*request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
 [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
 [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
 NSURLSessionConfiguration*config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
 config.HTTPCookieStorage=nil;config.URLCredentialStorage=nil;config.URLCache=nil;config.timeoutIntervalForRequest=25;
 NSURLSession*session=[NSURLSession sessionWithConfiguration:config delegate:[HackiCloudNoRedirect new] delegateQueue:nil];
 dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL good=NO;
 [[session dataTaskWithRequest:request completionHandler:^(NSData*data,NSURLResponse*response,NSError*error){@autoreleasepool{
  if(!error && [response isKindOfClass:NSHTTPURLResponse.class] && [(NSHTTPURLResponse*)response statusCode]==200 && data.length<2097152){
   id body=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
   if([body isKindOfClass:NSDictionary.class]){id rows=body[@"data"];if([rows isKindOfClass:NSArray.class] && [rows count]){id first=rows[0];good=[first isKindOfClass:NSDictionary.class] && [first[@"id"] isEqual:@"686449807"];}}
  }dispatch_semaphore_signal(done);
 }}]resume];
 BOOL timed=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))!=0;
 [session invalidateAndCancel];if(timed||!good){puts("CATALOG verification failed; response content omitted");return 11;}
 puts("CATALOG HTTP=200 item=686449807");return 0;
}
static BOOL receiveAll(int fd,void*data,size_t size){while(size){ssize_t n=recv(fd,data,size,0);if(n<=0)return NO;data=(char*)data+n;size-=(size_t)n;}return YES;}
static int install(const char*nonce,const char*storefront){
 if([cache() retrieveToken]){puts("Existing catalog entry unchanged");return 14;}
 int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return 4;
 struct sockaddr_in address={0};address.sin_len=sizeof(address);address.sin_family=AF_INET;address.sin_port=htons(19831);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
 if(bind(fd,(struct sockaddr*)&address,sizeof(address))||listen(fd,1)){close(fd);return 4;}
 puts("READY loopback-only 19831");int peer=accept(fd,NULL,NULL);close(fd);if(peer<0)return 5;
 struct timeval timeout={15,0};setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
 uint32_t size;if(!receiveAll(peer,&size,4)){close(peer);return 6;}size=ntohl(size);
 if(!size||size>32768){close(peer);return 7;}
 NSMutableData*input=[NSMutableData dataWithLength:size];if(!receiveAll(peer,input.mutableBytes,size)){close(peer);return 8;}close(peer);
 id row=[NSJSONSerialization JSONObjectWithData:input options:0 error:NULL];if(![row isKindOfClass:NSDictionary.class] || [row count]!=3)return 9;
 NSString*token=row[@"token"],*received=row[@"nonce"];id expiry=row[@"expiry"];
 NSCharacterSet*allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/="];
 double now=NSDate.date.timeIntervalSince1970;
 if(![received isKindOfClass:NSString.class] || ![received isEqualToString:[NSString stringWithUTF8String:nonce]] || ![token isKindOfClass:NSString.class] || token.length<16 || token.length>8192 || [token rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound || ![expiry isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)expiry)==CFBooleanGetTypeID() || !isfinite([expiry doubleValue]) || [expiry doubleValue]<now+60 || [expiry doubleValue]>now+60*86400)return 9;
 int result=verify(token,storefront);if(result)return result;
 if([cache() retrieveToken])return 14;
 id object=[[NSClassFromString(@"AMSMediaToken")alloc]initWithString:token expirationDate:[NSDate dateWithTimeIntervalSince1970:[expiry doubleValue]] lifetime:[expiry doubleValue]-now];if(!usable(object))return 15;
 id store=[[NSClassFromString(@"AMSMediaTokenServiceStore")alloc]initWithClientIdentifier:@"appstore" keychainStore:cache()];[store storeToken:object];
 id saved=[cache() retrieveToken];if(!usable(saved)||![[saved tokenString]isEqual:token])return 16;
 puts("Anonymous catalog token saved in native cache; value omitted");return metadata();
}
int main(int argc,char**argv){@autoreleasepool{
 alarm(75);setvbuf(stdout,NULL,_IONBF,0);
 if(argc<2||setgid(501)||setuid(501))return 2;
 if(!dlopen("/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices",RTLD_NOW))return 3;
 Class raw=NSClassFromString(@"AMSMediaTokenServiceKeychainStore"),store=NSClassFromString(@"AMSMediaTokenServiceStore");
 if(![raw instancesRespondToSelector:@selector(initWithClientIdentifier:keychainAccessGroup:)] || ![raw instancesRespondToSelector:@selector(retrieveToken)] || ![store instancesRespondToSelector:@selector(storeToken:)])return 3;
 if(argc==2&&!strcmp(argv[1],"status"))return metadata();
 const char*front=argc==3?argv[2]:argc==4?argv[3]:"";
 if(strlen(front)!=2 || front[0]<'a'||front[0]>'z'||front[1]<'a'||front[1]>'z')return 1;
 if(argc==3&&!strcmp(argv[1],"verify")){id token=[cache() retrieveToken];if(!usable(token))return 12;return verify([token tokenString],front);}
 if(argc==4&&!strcmp(argv[1],"install")){if(strlen(argv[2])!=32||strspn(argv[2],"0123456789abcdef")!=32)return 1;return install(argv[2],front);}
 return 1;
}}
