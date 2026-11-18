#import "auth_bridge_data.h"
#include <math.h>
@interface NSObject (AuthBridgeFields)
- (void)setMachineID:(NSString *)mid;
- (void)setOneTimePassword:(NSString *)otp;
- (void)setRoutingInfo:(unsigned long long)routing;
@end
static BOOL number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID();
}
static BOOL header(id value) {
    if(![value isKindOfClass:NSString.class] || [value length]<16 || [value length]>2048)return NO;
    return [[NSData alloc] initWithBase64EncodedString:value options:0].length>0;
}
id HAuthDataFromReply(NSData *wire, NSString *nonce, uint64_t request, NSTimeInterval now) {
    if(!wire.length || wire.length>32768 || nonce.length!=32 || !request || !isfinite(now))return nil;
    id body=[NSJSONSerialization JSONObjectWithData:wire options:0 error:NULL];
    if(![body isKindOfClass:NSDictionary.class])return nil;
    id peer=body[@"nonce"],sequence=body[@"request"],issued=body[@"issued"],routing=body[@"routing"];
    if(![peer isKindOfClass:NSString.class] || ![peer isEqual:nonce] || !number(sequence) ||
       [sequence unsignedLongLongValue]!=request || !number(issued) || !number(routing))return nil;
    double age=now-[issued doubleValue],r=[routing doubleValue];
    if(!isfinite(age) || age>20 || age< -5 || !isfinite(r) || r<=0 || r>UINT32_MAX || floor(r)!=r)return nil;
    if(!header(body[@"mid"]) || !header(body[@"otp"]))return nil;
    Class cls=NSClassFromString(@"AKAnisetteData");
    if(![cls instancesRespondToSelector:@selector(setMachineID:)] ||
       ![cls instancesRespondToSelector:@selector(setOneTimePassword:)] ||
       ![cls instancesRespondToSelector:@selector(setRoutingInfo:)])return nil;
    id data=[cls new];
    [data setMachineID:body[@"mid"]];[data setOneTimePassword:body[@"otp"]];[data setRoutingInfo:[routing unsignedLongLongValue]];
    return data;
}
