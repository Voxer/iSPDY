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
    void (^pipe_req)(ISpdyRequest*,
                     NSData*,
                     BOOL) = ^(ISpdyRequest* req,
                               NSData* data,
                               BOOL expect_response) {
      __block BOOL got_response = !expect_response;
      __block BOOL got_headers = NO;
      __block BOOL ended = NO;
      __block NSMutableData* received = nil;

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

        got_response = YES;
        ISpdyResponse* resp = [args objectAtIndex: 1];

        [[theValue(resp.code) should] equal: theValue(200)];

        return nil;
      };

      // Create delegate with mocked handlers
      id mock = [KWMock mockForProtocol: @protocol(ISpdyRequestDelegate)];

      [mock stub: @selector(request:handleInput:) withBlock: onInput];
      [mock stub: @selector(request:handleResponse:) withBlock: onResponse];
      [mock stub: @selector(request:handleHeaders:)
       withBlock: ^id (NSArray* args) {
        NSDictionary* headers  = (NSDictionary*) [args objectAtIndex: 1];
        [[[headers valueForKey: @"wtf"] should] equal: @"yes"];
        got_headers = YES;
        return nil;
      }];
      [mock stub: @selector(handleEnd:) withBlock: ^id (NSArray* args) {
        NSAssert(ended == NO, @"Double-end");
        ended = YES;
        return nil;
      }];
      [req setDelegate: mock];

      // Send trailing headers
      NSDictionary* trailers = [NSDictionary dictionaryWithObject: @"yes"
                                                           forKey: @"set"];
      [req addHeaders: trailers];

      // Send data
      [req endWithData: data];

      // And expect it to come back
      [[expectFutureValue(theValue(got_response)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue(got_headers)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue(ended)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue([received length])) shouldEventually]
          equal: theValue([data length])];
      [[expectFutureValue(received) shouldEventually] equal: data];
    };

    void (^pipe)(ISpdyVersion, NSData*) = ^(ISpdyVersion v, NSData* data) {
      __block ISpdy* conn = [[ISpdy alloc] init: v
                                           host: @"localhost"
                                           port: 3232
                                         secure: NO];

      // Expect push streams and connect event
      __block BOOL connected = NO;
      __block BOOL got_push = NO;
      __block BOOL got_push_input = NO;
      __block BOOL got_push_end = NO;
      id mock = [KWMock mockForProtocol: @protocol(ISpdyDelegate)];

      [mock stub: @selector(handleConnect:) withBlock: ^id (NSArray* args) {
        [[theValue([args count]) should] equal: theValue(1)];
        [[theValue(connected) shouldNot] equal: theValue(YES)];
        connected = YES;
        return nil;
      }];
      [mock stub: @selector(connection:handlePush:)
       withBlock: ^id (NSArray* args) {
        [[theValue([args count]) should] equal: theValue(2)];
        [[theValue(got_push) shouldNot] equal: theValue(YES)];
        got_push = YES;

        // Receive data
        ISpdyPush* push = [args objectAtIndex: 1];

        id mock = [KWMock mockForProtocol: @protocol(ISpdyRequestDelegate)];

        [mock stub: @selector(request:handleInput:)
         withBlock: ^id (NSArray* args) {
           got_push_input = YES;
           return nil;
         }];
        [mock stub: @selector(handleEnd:) withBlock: ^id (NSArray* args) {
          NSAssert(got_push_end == NO, @"Double-end");
          got_push_end = YES;
          return nil;
        }];
        [push setDelegate: mock];

        return nil;
      }];
      [conn setDelegate: mock];

      // Perform connection
      BOOL r = [conn connect];
      [[theValue(r) should] equal:theValue(YES)];

      // Disable Nagle algorithm
      [conn setNoDelay: YES];

      // Perform POST request to echo server
      ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];
      NSString* contentLength =
          [NSString stringWithFormat: @"%u", (unsigned int) [data length]];

      // Server expects and verifies this headers
      NSMutableDictionary* headers =
          [NSMutableDictionary dictionaryWithCapacity: 2];
      [headers setValue: contentLength forKey: @"Content-Length"];
      [headers setValue: @"yikes" forKey: @"X-ISpdy"];
      [headers setValue: [NSNumber numberWithInt: 3] forKey: @"X-ISpdy-V"];
      req.headers = headers;

      // Send request
      [conn send: req];

      // Pipe data
      pipe_req(req, data, YES);

      // Send ping
      __block BOOL received_pong = NO;
      [conn ping: ^(ISpdyPingStatus status, NSTimeInterval interval) {
        received_pong = YES;
      } waitMax: 10000];

      // Poll block variables until changed
      [[expectFutureValue(theValue(received_pong)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue(connected)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue(got_push)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue(got_push_end)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue(got_push_input)) shouldEventually]
          equal: theValue(YES)];
    };

    void (^slow_response)(ISpdyVersion) = ^(ISpdyVersion v) {
      ISpdy* conn = [[ISpdy alloc] init: v
                                   host: @"localhost"
                                   port: 3232
                                 secure: NO];

      BOOL r = [conn connect];
      [[theValue(r) should] equal:theValue(YES)];

      // Perform POST request to echo server
      ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];

      // Create delegate with mocked handlers
      id mock = [KWMock mockForProtocol: @protocol(ISpdyRequestDelegate)];

      __block NSError* err;
      id (^onError)(NSArray*) = ^id (NSArray* args) {
        [[theValue([args count]) should] equal: theValue(2)];

        err = [args objectAtIndex: 1];

        return nil;
      };
      [mock stub: @selector(request:handleResponse:) withBlock: nil];
      [mock stub: @selector(request:handleError:) withBlock: onError];
      [mock stub: @selector(handleEnd:) withBlock: nil];
      req.delegate = mock;

      [conn send: req];
      [req setTimeout: 0.5];

      [[expectFutureValue(err) shouldEventuallyBeforeTimingOutAfter(5.0)]
          beNonNil];
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

      it(@"should timeout on slow responses", ^{
        slow_response(v);
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
