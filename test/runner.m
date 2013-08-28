#import <Foundation/Foundation.h>
#import "Kiwi.h"
#import <SenTestingKit/SenTestingKit.h>
#import <ispdy.h>

SPEC_BEGIN(ISpdySpec)

describe(@"ISpdy server", ^{
  __block ISpdy* conn;

  beforeAll(^{
    conn = [[ISpdy alloc] init: kISpdyV2];
    BOOL r = [conn connect:@"localhost" port:3232 secure: NO];
    [[theValue(r) should] equal:theValue(YES)];
  });

  afterAll(^{
    conn = nil;
  });

  context(@"connecting", ^{
    it(@"should not fail", ^{
      __block BOOL ended = NO;
      __block NSString* received = nil;

      ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];

      id mock = [KWMock mockForProtocol: @protocol(ISpdyRequestDelegate)];
      [mock stub: @selector(handleEnd:) withBlock: ^id (NSArray* args) {
        ended = YES;
        return nil;
      }];

      id (^onInput)(NSArray*) = ^id (NSArray* args) {
        [[theValue(ended) shouldNot] equal: theValue(YES)];
        [[theValue([args count]) should] equal: theValue(2)];

        NSData* input = [args objectAtIndex: 1];
        NSString* str = [[NSString alloc] initWithData: input
                                              encoding: NSUTF8StringEncoding];
        if (received == nil)
          received = str;
        else
          received = [received stringByAppendingString: str];

        return nil;
      };
      [mock stub: @selector(request:handleInput:) withBlock: onInput];
      [req setDelegate: mock];

      NSString* body = @"Hello strange world";
      [conn send: req];
      [req writeString: body];
      [req end];

      [[expectFutureValue(theValue(ended)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(received) shouldEventually] equal: body];
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
