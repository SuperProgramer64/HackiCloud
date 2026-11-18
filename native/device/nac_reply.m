#import "nac_reply.h"
#include <math.h>
static BOOL numeric(id value) { return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID(); }
NSData *HNACSignatureFromReply(NSData *wire, NSString *nonce, uint64_t request, NSString *digest, NSTimeInterval now) {
 if(!wire.length || wire.length>32768 || nonce.length!=32 || digest.length!=64 || !request || !isfinite(now))return nil;
 id d=[NSJSONSerialization JSONObjectWithData:wire options:0 error:NULL];
 if(![d isKindOfClass:NSDictionary.class] || [d count]!=5)return nil;
 if(![d[@"nonce"] isKindOfClass:NSString.class] || ![d[@"nonce"] isEqual:nonce] ||
    ![d[@"sha256"] isKindOfClass:NSString.class] || ![d[@"sha256"] isEqual:digest] ||
    !numeric(d[@"request"]) || !numeric(d[@"issued"]))return nil;
 double seq=[d[@"request"] doubleValue],age=now-[d[@"issued"] doubleValue];
 if(!isfinite(seq) || floor(seq)!=seq || [d[@"request"] unsignedLongLongValue]!=request || !isfinite(age) || age>60 || age< -5)return nil;
 id encoded=d[@"signature"];if(![encoded isKindOfClass:NSString.class])return nil;
 NSData *sig=[[NSData alloc] initWithBase64EncodedString:encoded options:0];
 return sig.length>=16 && sig.length<=16384?sig:nil;
}
