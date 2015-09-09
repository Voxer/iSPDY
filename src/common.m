// The MIT License (MIT)
//
// Copyright (c) 2015 Voxer
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

#import <dispatch/dispatch.h>  // dispatch_queue_t

#include "ispdy.h"
#include "common.h"

@implementation ISpdyCommon

+ (dispatch_source_t) timerWithTimeInterval: (NSTimeInterval) interval
                                      queue: (dispatch_queue_t) queue
                                      block: (void (^)()) block
                                  andSource: (dispatch_source_t) source {
  dispatch_source_t res = source;
  if (res == NULL)
    res = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  else
    dispatch_suspend(res);
  NSAssert(res != NULL, @"Failed to create dispatch timer source");

  uint64_t intervalNS = (uint64_t) (interval * 1e9);
  uint64_t leeway = (intervalNS >> 2) < 100000ULL ?
    (intervalNS >> 2) : 100000ULL;
  dispatch_source_set_timer(res,
      dispatch_walltime(NULL, intervalNS),
      intervalNS,
      leeway);
  dispatch_source_set_event_handler(res, ^{
    [ISpdyCommon clearTimer: res];

    if (block != nil)
      block();
  });
  dispatch_resume(res);

  return res;
}

+ (void) clearTimer: (dispatch_source_t) source {
  dispatch_source_set_event_handler(source, NULL);
  dispatch_source_cancel(source);
}

@end

@implementation ISpdyPing

- (void) _invoke: (ISpdyPingStatus) status rtt: (NSTimeInterval) rtt {
  if (self.block == NULL)
    return;
  self.block(status, rtt);
  self.block = NULL;
}

@end

@implementation ISpdyLoopWrap

+ (ISpdyLoopWrap*) stateForLoop: (NSRunLoop*) loop andMode: (NSString*) mode {
  ISpdyLoopWrap* wrap = [ISpdyLoopWrap alloc];
  wrap.loop = loop;
  wrap.mode = mode;

  return wrap;
}

- (BOOL) isEqual: (id) anObject {
  if (![anObject isMemberOfClass: [ISpdyLoopWrap class]])
    return NO;

  ISpdyLoopWrap* wrap = (ISpdyLoopWrap*) anObject;
  return [wrap.loop isEqual: self.loop] &&
         [wrap.mode isEqualToString: self.mode];
}


- (NSUInteger) hash {
  return [self.loop hash] + [self.mode hash];
}

@end

@implementation ISpdyError

- (ISpdyErrorCode) code {
  return (ISpdyErrorCode) super.code;
}

- (NSString*) description {
  id details = [self.userInfo objectForKey: @"details"];
  switch (self.code) {
    case kISpdyErrConnectionTimeout:
      return @"ISpdy error: connection timed out";
    case kISpdyErrConnectionEnd:
      return @"ISpdy error: connection's socket end";
    case kISpdyErrRequestTimeout:
      return @"ISpdy error: request timed out";
    case kISpdyErrClose:
      return @"ISpdy error: connection was closed on client side";
    case kISpdyErrRst:
      return [NSString stringWithFormat: @"ISpdy error: connection was RSTed "
                                         @"by other side - %@",
          details];
    case kISpdyErrParseError:
      return [NSString stringWithFormat: @"ISpdy error: parser error - %@",
          details];
    case kISpdyErrDoubleResponse:
      return @"ISpdy error: got double SYN_REPLY for a single stream";
    case kISpdyErrSocketError:
      return [NSString stringWithFormat: @"ISpdy error: socket error - %@",
          details];
    case kISpdyErrCheckSocketError:
      return [NSString
          stringWithFormat: @"ISpdy error: check socket error - %@",
          details];
    case kISpdyErrDecompressionError:
      return @"ISpdy error: failed to decompress incoming data";
    case kISpdyErrSSLPinningError:
      return @"ISpdy error: failed to verify certificate against pinned one";
    case kISpdyErrGoawayError:
      return @"ISpdy error: server asked to go away";
    case kISpdyErrSendAfterGoawayError:
      return @"ISpdy error: request sent after go away";
    case kISpdyErrSendAfterClose:
      return @"ISpdy error: request sent after close";
    default:
      return [NSString stringWithFormat: @"Unexpected spdy error %d",
          self.code];
  }
}

@end

@implementation ISpdyError (ISpdyErrorPrivate)

+ (ISpdyError*) errorWithCode: (ISpdyErrorCode) code {
  ISpdyError* r = [ISpdyError alloc];

  return [r initWithDomain: @"ispdy" code: (NSInteger) code userInfo: nil];
}

+ (ISpdyError*) errorWithCode: (ISpdyErrorCode) code andDetails: (id) details {
  ISpdyError* r = [ISpdyError alloc];
  NSDictionary* dict;

  if (details != nil)
    dict = [NSDictionary dictionaryWithObject: details forKey: @"details"];
  return [r initWithDomain: @"ispdy" code: (NSInteger) code userInfo: dict];
}

@end
