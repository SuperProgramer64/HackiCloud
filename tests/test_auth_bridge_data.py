"""Validate the USB reply before constructing the actual native AuthKit object."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'native/device'

HARNESS = r'''
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <assert.h>
#include "auth_bridge_data.h"
@interface NSObject (FixtureRead)
- (NSString *)machineID;
- (NSString *)oneTimePassword;
- (unsigned long long)routingInfo;
@end
int main(int argc,char **argv){@autoreleasepool{
 assert(dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",RTLD_NOW));
 NSString *nonce=@"0123456789abcdef0123456789abcdef";
 NSString *mid=[@"A" stringByPaddingToLength:80 withString:@"A" startingAtIndex:0];
 NSString *otp=[@"B" stringByPaddingToLength:40 withString:@"B" startingAtIndex:0];
 NSMutableDictionary *d=[@{@"nonce":nonce,@"request":@7,@"issued":@1000,@"routing":@123,@"mid":mid,@"otp":otp} mutableCopy];
 NSString *test=[NSString stringWithUTF8String:argv[1]];
 if([test isEqual:@"wrong_nonce"])d[@"nonce"]=@"ffffffffffffffffffffffffffffffff";
 if([test isEqual:@"wrong_request"])d[@"request"]=@8;
 if([test isEqual:@"stale"])d[@"issued"]=@970;
 if([test isEqual:@"future"])d[@"issued"]=@1010;
 if([test isEqual:@"missing_otp"])[d removeObjectForKey:@"otp"];
 if([test isEqual:@"wrong_type"])d[@"mid"]=@42;
 if([test isEqual:@"header_injection"])d[@"otp"]=@"AAA\r\nAnother: header";
 if([test isEqual:@"oversized"])d[@"mid"]=[@"A" stringByPaddingToLength:40000 withString:@"A" startingAtIndex:0];
 NSData *json=[NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
 if([test isEqual:@"array"])json=[@"[]" dataUsingEncoding:NSUTF8StringEncoding];
 if([test isEqual:@"bad_json"])json=[@"{" dataUsingEncoding:NSUTF8StringEncoding];
 id data=HAuthDataFromReply(json,nonce,7,1000);
 if([test isEqual:@"valid"]){assert(data);assert([[data machineID] isEqual:mid]);assert([[data oneTimePassword] isEqual:otp]);assert([data routingInfo]==123);}
 else assert(data==nil);
 return 0;
}}
'''


class AuthBridgeData(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        p = Path(cls.tmp.name)
        (p / 'check.m').write_text(HARNESS)
        cls.binary = p / 'check'
        subprocess.run(['clang', '-fobjc-arc', '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(SRC), str(p / 'check.m'), str(SRC / 'auth_bridge_data.m'), '-o', str(cls.binary)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_native_fields_from_fresh_authenticated_reply(self):
        r = subprocess.run([str(self.binary), 'valid'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_reject_invalid_replies(self):
        for case in ['wrong_nonce', 'wrong_request', 'stale', 'future', 'missing_otp', 'wrong_type', 'header_injection', 'oversized', 'array', 'bad_json']:
            with self.subTest(case=case):
                r = subprocess.run([str(self.binary), case], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
