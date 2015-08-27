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
                                   andBlock: (void (^)()) block {
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                   0,
                                                   0,
                                                   queue);
  NSAssert(timer, @"Failed to create dispatch timer source");

  uint64_t intervalNS = (uint64_t) (interval * 1e9);
  uint64_t leeway = (intervalNS >> 2) < 100000ULL ?
    (intervalNS >> 2) : 100000ULL;
  dispatch_source_set_timer(timer,
      dispatch_walltime(NULL, intervalNS),
      intervalNS,
      leeway);
  dispatch_source_set_event_handler(timer, block);
  dispatch_resume(timer);

  return timer;
}

@end
