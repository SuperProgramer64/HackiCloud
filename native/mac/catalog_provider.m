/* Demand-only native AMS control. Anonymous account; RAM-only token storage; never prints token values. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
@interface NSObject (AMSCatalogSPI)
+ (id)createBagForSubProfile;
+ (id)promiseWithResult:(id)value;
- (id)initWithClientIdentifier:(id)client keychainStore:(id)store patBasedToken:(BOOL)pat;
- (id)initWithIdentifier:(id)identifier keychainAccessGroup:(id)group keychainAddFunc:(OSStatus (*)(CFDictionaryRef,CFTypeRef*))add keychainCopyFunc:(OSStatus (*)(CFDictionaryRef,CFTypeRef*))copy keychainDeleteFunc:(OSStatus (*)(CFDictionaryRef))del;
- (id)initWithClientIdentifier:(id)client tokenStore:(id)store patBasedTokenStore:(id)patStore bag:(id)bag fetcherClass:(Class)fetcher;
- (void)setAccount:(id)account;
- (id)fetchMediaToken;
- (id)resultWithTimeout:(double)seconds error:(NSError **)error;
- (NSString *)tokenString;
- (NSDate *)expirationDate;
@end
static unsigned copies,adds,deletes;
static OSStatus isolatedCopy(CFDictionaryRef q,CFTypeRef *result){copies++;if(result)*result=NULL;return errSecItemNotFound;}
static OSStatus isolatedAdd(CFDictionaryRef q,CFTypeRef *result){adds++;if(result)*result=NULL;return errSecSuccess;}
static OSStatus isolatedDelete(CFDictionaryRef q){deletes++;return errSecSuccess;}
static void reportError(NSError *error){
 for(unsigned i=0;error && i<5;i++,error=error.userInfo[NSUnderlyingErrorKey])printf("error domain=%s code=%ld http=%s\n",error.domain.UTF8String,(long)error.code,[error.userInfo[@"AMSStatusCode"] description].UTF8String?:"none");
}
int main(int argc,char **argv){@autoreleasepool{
 setvbuf(stdout,NULL,_IONBF,0);alarm(50);
 if(!dlopen("/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices",RTLD_NOW))return 2;
 Class svc=NSClassFromString(@"AMSMediaTokenService"),storeClass=NSClassFromString(@"AMSMediaTokenServiceStore");
 if(![svc respondsToSelector:@selector(createBagForSubProfile)] || ![storeClass instancesRespondToSelector:@selector(initWithClientIdentifier:keychainStore:patBasedToken:)])return 3;
 Class kc=NSClassFromString(@"AMSMediaTokenServiceKeychainStore");
 id mem=[[kc alloc] initWithIdentifier:@"HackiCloud.AnonymousCatalog" keychainAccessGroup:@"HackiCloud.AnonymousCatalog" keychainAddFunc:isolatedAdd keychainCopyFunc:isolatedCopy keychainDeleteFunc:isolatedDelete];
 id pat=[[kc alloc] initWithIdentifier:@"HackiCloud.AnonymousCatalog.PAT" keychainAccessGroup:@"HackiCloud.AnonymousCatalog" keychainAddFunc:isolatedAdd keychainCopyFunc:isolatedCopy keychainDeleteFunc:isolatedDelete];
 puts("Isolated keychain callbacks: no system Keychain reads/writes/deletes");
 id store=[[storeClass alloc] initWithClientIdentifier:@"appstore" keychainStore:mem patBasedToken:NO];
 id patStore=[[storeClass alloc] initWithClientIdentifier:@"appstore" keychainStore:pat patBasedToken:YES];
 id bag=[svc createBagForSubProfile];
 printf("bag present=%d\n",bag!=nil);
 id service=[[svc alloc] initWithClientIdentifier:@"appstore" tokenStore:store patBasedTokenStore:patStore bag:bag fetcherClass:Nil];
 [service setAccount:nil];
 NSError *error=nil;id promise=[service fetchMediaToken];
 printf("fetch promise=%d\n",promise!=nil);
 id token=[promise resultWithTimeout:35 error:&error];
 printf("RESULT token=%d error=%d\n",token!=nil,error!=nil);
 if(error)reportError(error);
 if(token && argc==2 && !strcmp(argv[1],"--pipe")){NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"token":[token tokenString],@"expiry":@([[token expirationDate] timeIntervalSince1970])} options:0 error:NULL];printf("TOKENJSON %.*s\n",(int)data.length,(const char*)data.bytes);}
 if(token)printf("anonymous catalog token bytes=%lu expires=%s\n",(unsigned long)[[token tokenString] length],[[token expirationDate] description].UTF8String);
 printf("isolated callbacks copy=%u add=%u delete=%u\n",copies,adds,deletes);return token?0:4;
}}
