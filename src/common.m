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
#import <sys/time.h>  // gettimeofday

#include "ispdy.h"
#include "common.h"

@implementation ISpdyTimerPool {
  dispatch_queue_t queue;
  dispatch_source_t source;
  CFBinaryHeapRef timers;
  BOOL suspended;
  BOOL recursive;
}


static CFComparisonResult compare_timers_cb(const void* a,
                                            const void* b,
                                            void* info) {
  ISpdyTimer* timer_a = (__bridge ISpdyTimer*) a;
  ISpdyTimer* timer_b = (__bridge ISpdyTimer*) b;

  if (timer_a.start < timer_b.start)
    return kCFCompareLessThan;
  else if (timer_a.start > timer_b.start)
    return kCFCompareGreaterThan;
  else
    return kCFCompareEqualTo;
}


+ (ISpdyTimerPool*) poolWithQueue: (dispatch_queue_t) queue {
  ISpdyTimerPool* pool = [ISpdyTimerPool new];

  pool->queue = queue;
  pool->source = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  NSAssert(pool->source != NULL, @"Failed to create dispatch timer source");

  __weak ISpdyTimerPool* weakSelf = pool;
  dispatch_source_set_event_handler(pool->source, ^{
    [weakSelf run];
  });

  pool->suspended = YES;
  CFBinaryHeapCallBacks heap_callbacks;
  memset(&heap_callbacks, 0, sizeof(heap_callbacks));
  heap_callbacks.compare = compare_timers_cb;
  pool->timers = CFBinaryHeapCreate(NULL, 0, &heap_callbacks, NULL);
  NSAssert(pool->timers != NULL, @"Failed to allocate binary heap");

  return pool;
}


- (ISpdyTimer*) armWithTimeInterval: (NSTimeInterval) interval
                           andBlock: (ISpdyTimerCallback) block {
  ISpdyTimer* timer = [ISpdyTimer new];
  timer.pool = self;
  timer.block = block;

  timer.start = [ISpdyTimerPool now];
  timer.start += interval;

  NSNumber* key = [NSNumber numberWithDouble: interval];
  timer.key = key;

  // Splitting into subpools ensures the order of timers
  dispatch_async(queue, ^{
    CFBinaryHeapAddValue(timers, (__bridge_retained void*) timer);
    [self schedule];
  });

  return timer;
}


- (void) schedule {
  // Skip removed timers
  void* value;
  while (CFBinaryHeapGetMinimumIfPresent(timers, (const void**) &value)) {
    ISpdyTimer* timer = (__bridge ISpdyTimer*) value;
    if (!timer.removed)
      break;
    CFBinaryHeapRemoveMinimumValue(timers);
    CFRelease((__bridge CFTypeRef) timer);
  }

  if (CFBinaryHeapGetCount(timers) == 0)
    return;

  ISpdyTimer* timer = (__bridge ISpdyTimer*) CFBinaryHeapGetMinimum(timers);
  double off = timer.start - [ISpdyTimerPool now];

  // Minimum one 1ns
  if (off < 1e-9)
    off = 1e-9;
  dispatch_time_t start_d = dispatch_walltime(NULL, (uint64_t) (off * 1e9));
  dispatch_source_set_timer(source, start_d, 1000000000ULL, 100000ULL);

  if (suspended)
    dispatch_resume(source);
  suspended = NO;
}


- (void) run {
  if (recursive || suspended)
    return;

  dispatch_suspend(source);
  suspended = YES;

  recursive = YES;

  double now = [ISpdyTimerPool now];
  void* value;
  while (CFBinaryHeapGetMinimumIfPresent(timers, (const void**) &value)) {
    ISpdyTimer* timer = (__bridge ISpdyTimer*) value;
    if (!timer || timer.start > now)
      break;

    CFBinaryHeapRemoveMinimumValue(timers);
    timer.block();
    timer.block = nil;
    CFRelease((__bridge CFTypeRef) timer);
  }

  // Do it right after the executing blocks to prevent recursion
  recursive = NO;

  if (CFBinaryHeapGetCount(timers) == 0)
    return;

  // Reschedule timer
  [self schedule];
}


+ (double) now {
  struct timeval t;
  int r = gettimeofday(&t, NULL);
  NSAssert(r == 0, @"Failed to get time of day");

  return (double) t.tv_sec + (double) t.tv_usec / 1e6;
}


- (void) dealloc {
  dispatch_source_set_event_handler_f(source, NULL);
  if (suspended)
    dispatch_resume(source);
  dispatch_source_cancel(source);
  source = NULL;
}

@end

@implementation ISpdyTimer

- (void) clear {
  self.removed = YES;
  self.pool = NULL;
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
