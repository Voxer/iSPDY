#import <Foundation/Foundation.h>
#import "Kiwi.h"
#import <SenTestingKit/SenTestingKit.h>
#import <ispdy.h>

SPEC_BEGIN(ISpdySpec)
  describe(@"ISpdy server", ^{
    __block ISpdy* c;
    beforeAll(^{
      c = [[ISpdy alloc] init: kISpdyV2];
      BOOL r = [c connect:@"localhost" port:3232 secure: NO];
      [[theValue(r) should] equal:theValue(YES)];
    });

    afterAll(^{
      c = nil;
    });

    context(@"connecting", ^{
      it(@"should not fail", ^{
        ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];
        [c send: req];
        [req writeString: @"hello world"];
        [req end];
      });
    });
  });
SPEC_END

int main() {
  @autoreleasepool {
    SenSelfTestMain();
  }
  return 0;
}
