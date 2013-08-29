#import <Foundation/Foundation.h>
#import "Kiwi.h"
#import <SenTestingKit/SenTestingKit.h>
#import <ispdy.h>

SPEC_BEGIN(ISpdySpec)

describe(@"ISpdy server", ^{
  __block ISpdy* conn;

  beforeEach(^{
    conn = [[ISpdy alloc] init: kISpdyV2];
    BOOL r = [conn connect:@"localhost" port:3232 secure: NO];
    [[theValue(r) should] equal:theValue(YES)];
  });

  afterEach(^{
    conn = nil;
  });

  context(@"sending requests to echo server", ^{
    it(@"should return body that was sent", ^{
      __block BOOL got_response = NO;
      __block BOOL ended = NO;
      __block NSString* received = nil;

      // Perform POST request to echo server
      ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];

      // Concatenate all input into one string
      id (^onInput)(NSArray*) = ^id (NSArray* args) {
        [[theValue(ended) shouldNot] equal: theValue(YES)];
        [[theValue(got_response) should] equal: theValue(YES)];
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

      // Verify headers
      id (^onResponse)(NSArray*) = ^id (NSArray* args) {
        [[theValue(ended) shouldNot] equal: theValue(YES)];
        [[theValue(got_response) shouldNot] equal: theValue(YES)];
        [[theValue([args count]) should] equal: theValue(2)];

        got_response = true;
        ISpdyResponse* resp = [args objectAtIndex: 1];

        [[theValue(resp.code) should] equal: theValue(200)];

        return nil;
      };

      // Create delegate with mocked handlers
      id mock = [KWMock mockForProtocol: @protocol(ISpdyRequestDelegate)];

      [mock stub: @selector(request:handleInput:) withBlock: onInput];
      [mock stub: @selector(request:handleResponse:) withBlock: onResponse];
      [mock stub: @selector(handleEnd:) withBlock: ^id (NSArray* args) {
        ended = YES;
        return nil;
      }];
      [req setDelegate: mock];

      // Send body
      NSString* body = @"Hello strange world";
      [conn send: req];
      [req writeString: body];
      [req end];

      // And expect it to come back
      [[expectFutureValue(theValue(got_response)) shouldEventually]
          equal: theValue(YES)];
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
