"""Reject replayed or mismatched signatures before handing them to native iCloud."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SRC = Path(__file__).resolve().parents[1] / 'native/device'
HARNESS = r'''
#import <Foundation/Foundation.h>
#import "nac_reply.h"
#include <assert.h>
int main(int argc,char **argv){@autoreleasepool{
 NSString *nonce=@"0123456789abcdef0123456789abcdef";
 NSString *digest=@"abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd";
 NSData *expected=[@"synthetic signature bytes for parser test" dataUsingEncoding:NSUTF8StringEncoding];
 NSMutableDictionary *d=[@{@"nonce":nonce,@"request":@7,@"issued":@1000,@"sha256":digest,@"signature":[expected base64EncodedStringWithOptions:0]} mutableCopy];
 NSString *test=[NSString stringWithUTF8String:argv[1]];
 if([test isEqual:@"wrong_nonce"])d[@"nonce"]=@"ffffffffffffffffffffffffffffffff";
 if([test isEqual:@"replay"])d[@"request"]=@6;
 if([test isEqual:@"fractional_request"])d[@"request"]=@7.5;
 if([test isEqual:@"boolean_request"])d[@"request"]=@YES;
 if([test isEqual:@"stale"])d[@"issued"]=@930;
 if([test isEqual:@"future"])d[@"issued"]=@1010;
 if([test isEqual:@"boolean_time"])d[@"issued"]=@YES;
 if([test isEqual:@"wrong_body"])d[@"sha256"]=@"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
 if([test isEqual:@"bad_base64"])d[@"signature"]=@"%%%notbase64%%%";
 if([test isEqual:@"empty_signature"])d[@"signature"]=@"";
 if([test isEqual:@"oversized"])d[@"signature"]=[@"A" stringByPaddingToLength:40000 withString:@"A" startingAtIndex:0];
 if([test isEqual:@"missing_signature"])[d removeObjectForKey:@"signature"];
 NSData *wire=[NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
 if([test isEqual:@"bad_json"])wire=[@"{" dataUsingEncoding:NSUTF8StringEncoding];
 if([test isEqual:@"array"])wire=[@"[]" dataUsingEncoding:NSUTF8StringEncoding];
 NSData *result=HNACSignatureFromReply(wire,nonce,7,digest,1000);
 assert([test isEqual:@"valid"]?[result isEqual:expected]:result==nil);
 return 0;
}}
'''


class NACReply(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        p = Path(cls.tmp.name)
        (p / 'check.m').write_text(HARNESS)
        cls.binary = p / 'check'
        subprocess.run(['clang', '-fobjc-arc', '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(SRC), str(p / 'check.m'), str(SRC / 'nac_reply.m'), '-o', str(cls.binary)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_returns_signature_bound_to_this_body_and_request(self):
        result = subprocess.run([str(self.binary), 'valid'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_replays_wrong_body_and_invalid_input(self):
        for case in ['wrong_nonce', 'replay', 'fractional_request', 'boolean_request', 'stale', 'future', 'boolean_time', 'wrong_body', 'bad_base64', 'empty_signature', 'oversized', 'missing_signature', 'bad_json', 'array']:
            with self.subTest(case=case):
                result = subprocess.run([str(self.binary), case], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
