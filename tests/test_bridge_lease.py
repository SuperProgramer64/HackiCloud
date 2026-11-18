"""A running bridge accepts owner-authorized renewal without daemon/UI restarts."""
from pathlib import Path
import subprocess,tempfile,unittest
SRC=Path(__file__).resolve().parents[1]/'native/device'
HARNESS=r'''#import <Foundation/Foundation.h>
#import "bridge_lease.h"
#include <assert.h>
#include <sys/stat.h>
#include <unistd.h>
int main(int argc,char**argv){@autoreleasepool{
 NSString *path=[NSString stringWithUTF8String:argv[1]],*nonce=@"0123456789abcdef0123456789abcdef";
 NSMutableDictionary *cfg=[@{@"nonce":nonce,@"expires":@1100,@"allow_account":@YES}mutableCopy];
 void(^save)(void)=^{[[NSJSONSerialization dataWithJSONObject:cfg options:0 error:NULL]writeToFile:path atomically:YES];chmod(path.fileSystemRepresentation,0600);};
 save();assert(HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid(),YES,1000));assert(!HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid()+1,YES,1000));
 cfg[@"expires"]=@990;save();assert(!HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid(),YES,1000));assert(HBridgeLoadConfiguration(path.fileSystemRepresentation,geteuid(),YES,1000));
 cfg[@"expires"]=@1200;save();assert(HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid(),YES,1000));
 chmod(path.fileSystemRepresentation,0644);assert(!HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid(),YES,1000));save();
 NSString *link=[path stringByAppendingString:@".link"];symlink(path.fileSystemRepresentation,link.fileSystemRepresentation);assert(!HBridgeLeaseValid(link.fileSystemRepresentation,nonce,geteuid(),YES,1000));
 cfg[@"nonce"]=@"ffffffffffffffffffffffffffffffff";save();assert(!HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid(),YES,1000));cfg[@"nonce"]=nonce;
 for(id bad in @[@YES,@1000,@8201,@"1200",[NSNull null]]){cfg[@"expires"]=bad;save();assert(!HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid(),YES,1000));}
 cfg[@"expires"]=@1200;cfg[@"allow_account"]=@1;save();assert(!HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid(),YES,1000));assert(HBridgeLeaseValid(path.fileSystemRepresentation,nonce,geteuid(),NO,1000));
 cfg[@"expires"]=@990;cfg[@"allow_account"]=@YES;save();assert(HBridgeLoadConfiguration(path.fileSystemRepresentation,geteuid(),YES,1000));
 cfg[@"nonce"]=@"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";save();assert(!HBridgeLoadConfiguration(path.fileSystemRepresentation,geteuid(),YES,1000));cfg[@"nonce"]=nonce;
 for(id bad in @[@YES,@0,@8201,@"1200",[NSNull null]]){cfg[@"expires"]=bad;save();assert(!HBridgeLoadConfiguration(path.fileSystemRepresentation,geteuid(),YES,1000));}
 cfg[@"expires"]=@990;cfg[@"enabled"]=@YES;save();assert(HBridgePrivateFlagEnabled(path.fileSystemRepresentation,geteuid()));
 for(id bad in @[@NO,@1,@"true",[NSNull null]]){cfg[@"enabled"]=bad;save();assert(!HBridgePrivateFlagEnabled(path.fileSystemRepresentation,geteuid()));}
 cfg[@"enabled"]=@YES;save();chmod(path.fileSystemRepresentation,0644);assert(!HBridgePrivateFlagEnabled(path.fileSystemRepresentation,geteuid()));
 assert(!HBridgePrivateFlagEnabled(link.fileSystemRepresentation,geteuid()));
 return 0;
}}'''
class BridgeLease(unittest.TestCase):
 def test_renewal_identity_permissions_expiry_and_consent(self):
  with tempfile.TemporaryDirectory()as d:
   p=Path(d);(p/'check.m').write_text(HARNESS)
   subprocess.run(['clang','-fobjc-arc','-fblocks','-fsanitize=address,undefined','-framework','Foundation','-I',str(SRC),str(p/'check.m'),str(SRC/'bridge_lease.m'),'-o',str(p/'check')],check=True,capture_output=True)
   r=subprocess.run([str(p/'check'),str(p/'lease')],capture_output=True,text=True);self.assertEqual(r.returncode,0,r.stderr)
