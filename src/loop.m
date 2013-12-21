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

#import <dispatch/dispatch.h>

#import "loop.h"

static ISpdyLoop* loop;
static dispatch_once_t loop_once;

@implementation ISpdyLoop {
  volatile NSRunLoop* runLoop_;
  dispatch_semaphore_t init_sem_;
}

+ (NSRunLoop*) defaultLoop {
  dispatch_once(&loop_once, ^{
    loop = [[ISpdyLoop alloc] init];
    [loop start];
  });
  return [loop runLoop];
}

- (id) init {
  self = [super init];
  if (!self)
    return self;

  self.name = @"ISpdy default run loop's thread";

  init_sem_ = dispatch_semaphore_create(0);
  NSAssert(init_sem_ != NULL, @"Dispatch semaphore create failed");

  return self;
}

- (void) main {
  @autoreleasepool {
    // Create timer that fires in distant future, just to keep loop running
    NSTimer* timer = [[NSTimer alloc] initWithFireDate: [NSDate distantFuture]
                                              interval: 0.0
                                                target: nil
                                              selector: nil
                                              userInfo: nil
                                               repeats: NO];
    runLoop_ = [NSRunLoop currentRunLoop];
    __sync_synchronize();
    dispatch_semaphore_signal(init_sem_);
    [runLoop_ addTimer: timer forMode: NSDefaultRunLoopMode];
    [runLoop_ run];
  }
}


- (NSRunLoop*) runLoop {
  // If not initialized, wait for another thread to catch-up with us
  if (runLoop_ == nil)
    dispatch_semaphore_wait(init_sem_, DISPATCH_TIME_FOREVER);
  return (NSRunLoop *)runLoop_;
}

@end
