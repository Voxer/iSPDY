#import <Foundation/Foundation.h>
#import "Kiwi.h"
#import <SenTestingKit/SenTestingKit.h>
#import <ispdy.h>
#import "compressor.h"

SPEC_BEGIN(ISpdySpec)

describe(@"ISpdy compressor", ^{
  context(@"compressing/decompressing stream", ^{
    it(@"should work", ^{
      BOOL r;
      ISpdyCompressor* input = [[ISpdyCompressor alloc] init: kISpdyV3];
      ISpdyCompressor* output = [[ISpdyCompressor alloc] init: kISpdyV3];

      NSData* str = [@"hello world\n" dataUsingEncoding: NSUTF8StringEncoding];

      for (int i = 0; i < 100; i++) {
        r = [input deflate: str];
        [[theValue(r) should] equal: theValue(YES)];
        [[input.error should] beNil];

        r = [output inflate: input.output];
        [[theValue(r) should] equal: theValue(YES)];
        [[output.error should] beNil];
      }
    });
  });
});

describe(@"ISpdy server", ^{
  void (^bothVersions)(void (^)(ISpdyVersion)) = ^(void (^b)(ISpdyVersion)) {
    context(@"spdy-v2", ^{
      b(kISpdyV2);
    });
    context(@"spdy-v3", ^{
      b(kISpdyV3);
    });
  };

  context(@"sending requests to echo server", ^{
    void (^pipe)(ISpdyVersion, NSData*) = ^(ISpdyVersion v, NSData* data) {
      ISpdy* conn = [[ISpdy alloc] init: v
                                   host: @"localhost"
                                   port:3232
                                 secure: NO];

      BOOL r = [conn connect];
      [[theValue(r) should] equal:theValue(YES)];

      __block BOOL got_response = NO;
      __block BOOL ended = NO;
      __block NSMutableData* received = nil;

      // Perform POST request to echo server
      ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];
      NSString* contentLength =
          [NSString stringWithFormat: @"%u", (unsigned int) [data length]];

      // Server expects and verifies this headers
      NSMutableDictionary* headers =
          [NSMutableDictionary dictionaryWithCapacity: 2];
      [headers setValue: contentLength forKey: @"Content-Length"];
      [headers setValue: @"yikes" forKey: @"X-ISpdy"];
      req.headers = headers;

      // Concatenate all input into one string
      id (^onInput)(NSArray*) = ^id (NSArray* args) {
        [[theValue(ended) shouldNot] equal: theValue(YES)];
        [[theValue(got_response) should] equal: theValue(YES)];
        [[theValue([args count]) should] equal: theValue(2)];

        NSData* input = [args objectAtIndex: 1];
        if (received == nil)
          received = [NSMutableData dataWithData: input];
        else
          [received appendData: input];

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
      [conn send: req];
      [req writeData: data];
      [req end];

      // And expect it to come back
      [[expectFutureValue(theValue(got_response)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue(ended)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(received) shouldEventually] equal: data];

      // Send ping
      __block BOOL received_pong = NO;
      [conn ping: ^(ISpdyPingStatus status, NSTimeInterval interval) {
        received_pong = YES;
      } waitMax: 10000];
      [[expectFutureValue(theValue(received_pong)) shouldEventually]
          equal: theValue(YES)];
    };

    bothVersions(^(ISpdyVersion v) {
      it(@"should return body that was sent", ^{
        pipe(v, [@"hello world" dataUsingEncoding: NSUTF8StringEncoding]);
      });

      it(@"should return big body that was sent", ^{
        int count = 100 * 1024;
        NSData* str = [@"hello world\n" dataUsingEncoding: NSUTF8StringEncoding];
        NSMutableData* body =
            [NSMutableData dataWithCapacity: [str length] * count];
        for (int i = 0; i < count; i++) {
          [body appendData: str];
        }
        pipe(v, body);
      });
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
