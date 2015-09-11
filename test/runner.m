// The MIT License (MIT)
//
// Copyright (c) 2013 Voxer
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>  // dispatch_queue_t
#import "Kiwi.h"
#import <ispdy.h>
#import "compressor.h"
#import "common.h"


SPEC_BEGIN(ISpdySpec)

describe(@"ISpdy server", ^{
  typedef struct {
    ISpdyVersion version;
    const char* compression;
  } ISpdyTestConf;

  void (^eachConf)(void (^)(ISpdyTestConf)) = ^(void (^b)(ISpdyTestConf)) {
    context(@"spdy-v2 - no comp", ^{
      b((ISpdyTestConf) { kISpdyV2, "*" });
    });
    context(@"spdy-v2 - deflate", ^{
      b((ISpdyTestConf) { kISpdyV2, "deflate" });
    });
    context(@"spdy-v2 - gzip", ^{
      b((ISpdyTestConf) { kISpdyV2, "gzip" });
    });
    context(@"spdy-v3 - no comp", ^{
      b((ISpdyTestConf) { kISpdyV3, "*" });
    });
    context(@"spdy-v3 - deflate", ^{
      b((ISpdyTestConf) { kISpdyV3, "deflate" });
    });
    context(@"spdy-v3 - gzip", ^{
      b((ISpdyTestConf) { kISpdyV3, "gzip" });
    });
  };

  context(@"using timers pool", ^{
    dispatch_queue_t queue = dispatch_get_main_queue();

    it(@"should call single timer callback", ^{
      __block BOOL called = NO;

      ISpdyTimerPool* pool = [ISpdyTimerPool poolWithQueue: queue];

      [pool armWithTimeInterval: 1.0 andBlock: ^{
        called = YES;
      }];

      [[expectFutureValue(theValue(called)) shouldEventually]
          equal: theValue(YES)];
    });

    it(@"should call recursive timer callback", ^{
      __block BOOL called = NO;

      ISpdyTimerPool* pool = [ISpdyTimerPool poolWithQueue: queue];

      [pool armWithTimeInterval: 0.5 andBlock: ^{
        [pool armWithTimeInterval: 1.75 andBlock: ^{
          called = YES;

          // Just a reference
          NSString* name = [pool className];
        }];
      }];

      [[expectFutureValue(theValue(called))
          shouldEventuallyBeforeTimingOutAfter(5.0)]
          equal: theValue(YES)];
    });

    it(@"should call two timers in a row", ^{
      __block BOOL called_first = NO;
      __block BOOL called_second = NO;

      ISpdyTimerPool* pool = [ISpdyTimerPool poolWithQueue: queue];

      [pool armWithTimeInterval: 1.0 andBlock: ^{
        called_first = YES;
      }];
      [pool armWithTimeInterval: 1.0 andBlock: ^{
        called_second = YES;
      }];

      [[expectFutureValue(theValue(called_first)) shouldEventually]
          equal: theValue(YES)];
      [[expectFutureValue(theValue(called_second)) shouldEventually]
          equal: theValue(YES)];
    });
  });

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
      [mock stub: @selector(request:handleEnd:) withBlock: ^id (NSArray* args) {
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

    void (^pipe)(ISpdyTestConf, NSData*) = ^(ISpdyTestConf conf, NSData* data) {
      __block ISpdy* conn = [[ISpdy alloc] init: conf.version
                                           host: @"localhost"
                                           port: 3232
                                         secure: NO];
      [conn setVoip: true];

      // Expect push streams and connect event
      __block BOOL connected = NO;
      __block BOOL got_push = NO;
      __block BOOL got_push_input = NO;
      __block BOOL got_push_headers = NO;
      __block BOOL got_push_end = NO;
      id mock = [KWMock mockForProtocol: @protocol(ISpdyDelegate)];

      [mock stub: @selector(handleConnect:) withBlock: ^id (NSArray* args) {
        [[theValue([args count]) should] equal: theValue(1)];
        [[theValue(connected) shouldNot] equal: theValue(YES)];
        connected = YES;
        // Check socket
        NSAssert([conn checkSocket] == kISpdyCheckGood,
                 @"Check socket fail");
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
        [mock stub: @selector(request:handleEnd:)
         withBlock: ^id (NSArray* args) {
          NSAssert(got_push_end == NO, @"Double-end");
          got_push_end = YES;
          return nil;
        }];
        [mock stub: @selector(request:handleHeaders:)
         withBlock: ^id (NSArray* args) {
          NSAssert(got_push_headers == NO, @"Double-headers");
          got_push_headers = YES;

          NSDictionary* headers = (NSDictionary*) [args objectAtIndex: 1];
          [[[headers valueForKey: @"oh-yes"] should] equal: @"yay"];

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
      ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST"
                                                 url: @"/"
                                      withConnection: conn];
      NSString* contentLength =
          [NSString stringWithFormat: @"%u", (unsigned int) [data length]];

      // Server expects and verifies this headers
      NSMutableDictionary* headers =
          [NSMutableDictionary dictionaryWithCapacity: 2];
      [headers setValue: contentLength forKey: @"Content-Length"];
      [headers setValue: @"yikes" forKey: @"X-ISpdy"];
      [headers setValue: [NSString stringWithCString: conf.compression
                                            encoding: NSUTF8StringEncoding]
                 forKey: @"Accept-Encoding"];
      [headers setValue: [NSNumber numberWithInt: 3] forKey: @"X-ISpdy-V"];
      req.headers = headers;

      // Send request
      [conn send: req];

      // Check socket
      NSAssert([conn checkSocket] == kISpdyCheckNotConnected,
               @"Check socket fail");

      // Pipe data
      pipe_req(req, data, YES);

      // Send ping
      __block BOOL received_pong = NO;
      [conn ping: ^(ISpdyPingStatus status, NSTimeInterval interval) {
        received_pong = YES;

        [conn closeSoon: 15.0];
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
      [[expectFutureValue(theValue(got_push_headers)) shouldEventually]
          equal: theValue(YES)];
    };

    void (^slow_response)(ISpdyTestConf) = ^(ISpdyTestConf conf) {
      ISpdy* conn = [[ISpdy alloc] init: conf.version
                                   host: @"localhost"
                                   port: 3232
                                 secure: NO];

      BOOL r = [conn connect];
      [[theValue(r) should] equal:theValue(YES)];

      // Perform POST request to echo server
      ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST"
                                                 url: @"/"
                                      withConnection: conn];

      // Create delegate with mocked handlers
      id mock = [KWMock mockForProtocol: @protocol(ISpdyRequestDelegate)];

      __block ISpdyError* err;
      id (^onEnd)(NSArray*) = ^id (NSArray* args) {
        [[theValue([args count]) should] equal: theValue(2)];

        err = [args objectAtIndex: 1];

        return nil;
      };
      [mock stub: @selector(request:handleResponse:) withBlock: nil];
      [mock stub: @selector(request:handleEnd:) withBlock: onEnd];
      req.delegate = mock;

      [conn send: req];
      [req setTimeout: 0.5];

      [[expectFutureValue(err) shouldEventuallyBeforeTimingOutAfter(5.0)]
          beNonNil];
    };

    void (^failure)(ISpdyTestConf) = ^(ISpdyTestConf conf) {
      ISpdy* conn = [[ISpdy alloc] init: conf.version
                                   host: @"localhost"
                                   port: 3232
                                 secure: NO];

      BOOL r = [conn connect];
      [[theValue(r) should] equal:theValue(YES)];

      // Perform POST request to echo server
      ISpdyRequest* req = [[ISpdyRequest alloc] init: @"GET"
                                                 url: @"/fail"
                                      withConnection: conn];

      // Create delegate with mocked handlers
      id mock = [KWMock mockForProtocol: @protocol(ISpdyRequestDelegate)];

      __block ISpdyError* err;
      id (^onEnd)(NSArray*) = ^id (NSArray* args) {
        [[theValue([args count]) should] equal: theValue(2)];

        err = [args objectAtIndex: 1];

        return nil;
      };
      [mock stub: @selector(request:handleResponse:) withBlock: nil];
      [mock stub: @selector(request:handleEnd:) withBlock: onEnd];
      req.delegate = mock;

      [conn send: req];

      [[expectFutureValue(err) shouldEventuallyBeforeTimingOutAfter(5.0)]
          beNonNil];
    };

    eachConf(^(ISpdyTestConf conf) {
      it(@"should return body that was sent", ^{
        pipe(conf, [@"hello world" dataUsingEncoding: NSUTF8StringEncoding]);
      });

      it(@"should return big body that was sent", ^{
        int count = 100 * 1024;
        NSData* str = [@"hello world\n" dataUsingEncoding: NSUTF8StringEncoding];
        NSMutableData* body =
            [NSMutableData dataWithCapacity: [str length] * count];
        for (int i = 0; i < count; i++) {
          [body appendData: str];
        }
        pipe(conf, body);
      });

      it(@"should timeout on slow responses", ^{
        slow_response(conf);
      });

      it(@"should handle failures", ^{
        failure(conf);
      });
    });
  });
});

SPEC_END

int main() {
  @autoreleasepool {
    XCTestSuite* suite = [XCTestSuite testSuiteWithName: @"ISpdy"];

    for (NSInvocation* invocation in [ISpdySpec testInvocations]) {
      [suite addTest: [ISpdySpec testCaseWithInvocation: invocation]];
    }
    [suite run];
  }
  return 0;
}
