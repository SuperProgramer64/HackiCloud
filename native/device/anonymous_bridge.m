/* AuthKit still authenticates with Apple. Only anonymous Anisette comes from the user's Mac over USB.
 * API interception reference: Martinvlba/hakios-xnu-kernel cdc5541 userland/src/inject_akd.c.
 * Own transport/validation; never reads account names, passwords, sessions or 2FA codes.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "auth_bridge_transport.h"
#import "bridge_lease.h"
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
static const char *configPath="/var/mobile/Library/Preferences/org.hackicloud.anonymous.json";
static NSString *leaseNonce;
static id (*originalRouted)(id,SEL,uint64_t,NSError **);
static id (*originalRaw)(id,SEL,uint64_t,NSError **);
static unsigned supplied,fallthroughs;
static id suppliedData(void){
 if(!HBridgeLeaseValid(configPath,leaseNonce,501,NO,NSDate.date.timeIntervalSince1970))return nil;
 id data=HAuthBridgeFetch();
 if(data)fprintf(stderr,"HackiCloud: anonymous data supplied %u\n",++supplied);
 else if(fallthroughs++<8)fprintf(stderr,"HackiCloud: provider unavailable; original implementation retained\n");
 return data;
}
static void status(const char *text){FILE*f=fopen("/var/mobile/Library/Logs/hackicloud-anonymous-status.txt","a");if(f){fprintf(f,"%s\n",text);fclose(f);}}
static id hookRouted(id self,SEL cmd,uint64_t dsid,NSError **error){
 if(dsid==UINT64_MAX-1){id data=suppliedData();if(data){status("routed anonymous data supplied");if(error)*error=nil;return data;}}
 else status("nonanonymous routed request retained original");
 return originalRouted(self,cmd,dsid,error);
}
static id hookRaw(id self,SEL cmd,uint64_t dsid,NSError **error){
 if(dsid==UINT64_MAX-1){id data=suppliedData();if(data){status("raw anonymous data supplied");if(error)*error=nil;return data;}}
 else status("nonanonymous raw request retained original");
 return originalRaw(self,cmd,dsid,error);
}
__attribute__((constructor))static void install(void){@autoreleasepool{
 if(strcmp(getprogname(),"akd"))return;
 status("constructor entered");
 NSDictionary *cfg=HBridgeLoadConfiguration(configPath,501,NO,NSDate.date.timeIntervalSince1970);
 if(!cfg)return;
 if(!dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",RTLD_NOW))return;
 Class cls=NSClassFromString(@"AKNativeAnisetteService");
 Method simple=class_getInstanceMethod(cls,NSSelectorFromString(@"_unsafe_anisetteDataWithRoutingInfoForDSID:withError:"));
 Method provision=class_getInstanceMethod(cls,NSSelectorFromString(@"_unsafe_anisetteDataForDSID:withError:"));
 if(!simple || !provision || strcmp(method_getTypeEncoding(simple),"@32@0:8Q16^@24") || strcmp(method_getTypeEncoding(provision),"@32@0:8Q16^@24")){
  status("unsupported method ABI; no hooks installed");return;
 }
 leaseNonce=cfg[@"nonce"];
 if(!HAuthBridgeStart(cfg[@"nonce"])){status("listener unavailable; no hooks installed");return;}
 originalRouted=(void*)method_setImplementation(simple,(IMP)hookRouted);
 originalRaw=(void*)method_setImplementation(provision,(IMP)hookRaw);
 status("two native service methods installed; anonymous DSID only; bounded USB provider");
}}
