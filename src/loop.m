#import <dispatch/dispatch.h>

#import "loop.h"

static ISpdyLoop* loop;
static dispatch_once_t loop_once;

@implementation ISpdyLoop {
  NSRunLoop* runLoop_;
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
    dispatch_semaphore_signal(init_sem_);
    [runLoop_ addTimer: timer forMode: NSDefaultRunLoopMode];
    [runLoop_ run];
  }
}


- (NSRunLoop*) runLoop {
  // If not initialized, wait for another thread to catch-up with us
  if (runLoop_ == nil)
    dispatch_semaphore_wait(init_sem_, DISPATCH_TIME_FOREVER);
  return runLoop_;
}

@end
