#import <string.h>  // memmove

#import "scheduler.h"

static const NSUInteger kBufferCapacity = 1024;

@implementation ISpdyScheduler {
  NSArray* buffers_;
  NSUInteger length_;
}

+ (ISpdyScheduler*) schedulerWithMaxPriority: (NSUInteger) maxPriority {
  ISpdyScheduler* scheduler = [ISpdyScheduler alloc];

  NSMutableArray* buffers = [NSMutableArray arrayWithCapacity: maxPriority];
  for (NSUInteger i = 0; i <= maxPriority; i++)
    [buffers addObject: [NSMutableData dataWithCapacity: kBufferCapacity]];
  scheduler->buffers_ = buffers;

  return scheduler;
}


- (void) schedule: (NSData*) data withPriority: (NSUInteger) priority {
  NSAssert(self.delegate != nil, @"Delegate wasn't set");
  NSAssert(priority < [buffers_ count], @"Priority OOB");

  NSMutableData* buffer = (NSMutableData*) [buffers_ objectAtIndex: priority];

  // Optimization, write directly to output stream, skipping unschedule call
  if (length_ == 0) {
    NSUInteger r = [self.delegate scheduledWrite: data];

    // Wholly written
    if (r == [data length])
      return;

    // Part of data wasn't written right now, slice it and buffer
    [buffer appendBytes: [data bytes] + r length: [data length] - r];
    length_ += r;
  } else {
    [buffer appendData: data];
    length_ += [data length];
  }
}


- (void) unschedule {
  NSAssert(self.delegate != nil, @"Delegate wasn't set");
  NSUInteger count = [buffers_ count];
  for (NSUInteger i = 0; i < count; i++) {
    NSMutableData* buffer = (NSMutableData*) [buffers_ objectAtIndex: i];
    if ([buffer length] == 0)
      continue;
    NSInteger r = [self.delegate scheduledWrite: buffer];

    void* bytes = [buffer mutableBytes];
    memmove(bytes, bytes + r, [buffer length] - r);
    [buffer setLength: [buffer length] - r];
    length_ -= r;

    // Target stream is full, wait for next `unschedule` call
    if ([buffer length] != 0)
      break;

    // No more bytes to schedule
    if (length_ == 0)
      break;
  }
}

@end
