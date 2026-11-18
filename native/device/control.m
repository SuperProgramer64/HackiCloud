/* Root-only configuration of this project's two hooks. No account or credential access. */
#import <Foundation/Foundation.h>
#import "bridge_lease.h"
#include "mapping.h"
#include <sys/sysctl.h>
#include <sys/stat.h>
int proc_listallpids(void*,int);
int proc_name(int,void*,unsigned);
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <sys/time.h>
static const char*paths[]={"/var/mobile/Library/Preferences/org.hackicloud.anonymous.json","/var/mobile/Library/Preferences/org.hackicloud.signer.json"};
static const char*legacyPaths[]={"/var/mobile/Library/Preferences/hakios.auth-usb.json","/var/mobile/Library/Preferences/hakios.nac-usb.json"};
static BOOL writeConfig(unsigned which,NSString*nonce,double expiry,const char*path){
 NSDictionary*config=which?@{@"nonce":nonce,@"expires":@(expiry),@"allow_account":@YES}:@{@"nonce":nonce,@"expires":@(expiry)};
 NSData*data=[NSJSONSerialization dataWithJSONObject:config options:0 error:NULL];
 char temp[256];snprintf(temp,sizeof(temp),"%s.%d.new",path,getpid());
 int fd=open(temp,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600);if(fd<0)return NO;
 BOOL ok=write(fd,data.bytes,data.length)==(ssize_t)data.length&&!fchown(fd,501,501)&&!fsync(fd);close(fd);
 if(ok)ok=!rename(temp,path);if(!ok)unlink(temp);return ok;
}
static int map(BOOL enable){
 char before[8192]={0},after[8192]={0},check[8192]={0};size_t n=sizeof(before);
 if(sysctlbyname("kern.exec_inject",before,&n,NULL,0)||!memchr(before,0,n))return 3;
 int r=hcloud_mapping(before,after,sizeof(after),enable);if(r){puts(r==2?"Conflicting hooks already target akd or Preferences; nothing replaced":"Mapping exceeds capacity");return 4;}
 if(sysctlbyname("kern.exec_inject",NULL,NULL,after,strlen(after)+1))return 5;
 n=sizeof(check);return sysctlbyname("kern.exec_inject",check,&n,NULL,0)||strcmp(after,check)?6:0;
}
int main(int argc,char**argv){@autoreleasepool{
 if(geteuid()!=0||argc<2)return 1;
 if(!strcmp(argv[1],"sync-clock")){
  if(argc!=3)return 1;char*end=NULL;long long epoch=strtoll(argv[2],&end,10);if(!end||*end||epoch<1760000000LL||epoch>4102444800LL)return 1;
  struct timeval now;gettimeofday(&now,NULL);long long delta=(long long)now.tv_sec-epoch;
  if(delta>30||delta< -30){struct timeval fixed={(time_t)epoch,0};if(settimeofday(&fixed,NULL))return 12;puts("Clock synchronized with owner Mac");}else puts("Clock already synchronized");return 0;
 }
 if(!strcmp(argv[1],"legacy-info")){
  NSMutableArray*values=[NSMutableArray new];for(unsigned i=0;i<2;i++){NSDictionary*d=HBridgeLoadConfiguration(legacyPaths[i],501,i==1,NSDate.date.timeIntervalSince1970);if(!d)return 9;[values addObject:d[@"nonce"]];}
  NSData*j=[NSJSONSerialization dataWithJSONObject:@{@"anonymous":values[0],@"signer":values[1]} options:0 error:NULL];fwrite(j.bytes,1,j.length,stdout);puts("");return 0;
 }
 if(!strcmp(argv[1],"legacy-renew")){
  if(argc!=4)return 1;
  for(unsigned i=0;i<2;i++){NSString*nonce=[NSString stringWithUTF8String:argv[i+2]];NSDictionary*d=HBridgeLoadConfiguration(legacyPaths[i],501,i==1,NSDate.date.timeIntervalSince1970);if(![d[@"nonce"]isEqual:nonce])return 9;}
  for(unsigned i=0;i<2;i++)if(!writeConfig(i,[NSString stringWithUTF8String:argv[i+2]],NSDate.date.timeIntervalSince1970+7190,legacyPaths[i]))return 11;
  puts("Existing iCloud bridge permissions renewed; values omitted");return 0;
 }
 if(!strcmp(argv[1],"status")){char value[8192]={0};size_t n=sizeof(value);if(sysctlbyname("kern.exec_inject",value,&n,NULL,0))return 2;puts(strstr(value,HC_ANON)&&strstr(value,HC_SIGN)?"HackiCloud mappings present":"HackiCloud mappings absent");return 0;}
 if(!strcmp(argv[1],"remove")){int r=map(NO);if(r)return r;for(unsigned i=0;i<2;i++)unlink(paths[i]);puts("Own mappings and permissions removed; loaded hooks fall back to native behavior");return 0;}
 if(!strcmp(argv[1],"restart-auth")){int pids[2048];int n=proc_listallpids(pids,sizeof(pids));BOOL found=NO;for(int i=0;i<n&&i<2048;i++){char name[64]={0};if(proc_name(pids[i],name,sizeof(name))>0&&!strcmp(name,"akd")){if(kill(pids[i],SIGKILL))return 8;found=YES;}}puts(found?"Authentication daemon restart requested":"Authentication daemon not running; hook loads on next launch");return 0;}
 if(argc!=4||(strcmp(argv[1],"install")&&strcmp(argv[1],"renew")))return 1;
 NSString*nonce=[NSString stringWithUTF8String:argv[2]];if(nonce.length!=32||[nonce rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]invertedSet]].location!=NSNotFound)return 1;
 char*end=NULL;long seconds=strtol(argv[3],&end,10);if(!end||*end||seconds<60||seconds>7200)return 1;
 if(!strcmp(argv[1],"renew")){
  for(unsigned i=0;i<2;i++){NSDictionary*d=HBridgeLoadConfiguration(paths[i],501,i==1,NSDate.date.timeIntervalSince1970);if(![d[@"nonce"]isEqual:nonce])return 9;}
 }else{
  if(access("/var/jb/usr/bin/hackicloud_anonymous",R_OK)||access("/var/jb/usr/bin/hackicloud_signer",R_OK))return 10;
  int r=map(YES);if(r)return r;
 }
 BOOL ok=writeConfig(0,nonce,NSDate.date.timeIntervalSince1970+seconds,paths[0])&&writeConfig(1,nonce,NSDate.date.timeIntervalSince1970+seconds,paths[1]);
 if(!ok){if(!strcmp(argv[1],"install"))map(NO);for(unsigned i=0;i<2;i++)unlink(paths[i]);return 11;}
 puts("Private temporary permissions updated; configuration values omitted");return 0;
}}
