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

#import "scheduler.h"

static const NSInteger kSchedulerItemCapacity = 10;

@implementation ISpdyScheduler {
  ISpdySchedulerQueue* sync_;
  NSArray* queues_;
  NSUInteger pending_;
  dispatch_queue_t dispatch_;
  BOOL pending_dispatch_;
  NSInteger corked_;
}

+ (ISpdyScheduler*) schedulerWithMaxPriority: (NSUInteger) maxPriority
                                 andDispatch: (dispatch_queue_t) dispatch {
  ISpdyScheduler* scheduler = [ISpdyScheduler alloc];

  NSMutableArray* queues = [NSMutableArray arrayWithCapacity: maxPriority];
  for (NSUInteger i = 0; i <= maxPriority; i++)
    [queues addObject: [ISpdySchedulerQueue queueWithScheduler: scheduler]];
  scheduler->queues_ = queues;
  scheduler->pending_ = 0;
  scheduler->dispatch_ = dispatch;
  scheduler->sync_ = [ISpdySchedulerQueue queueWithScheduler: scheduler];
  scheduler->pending_dispatch_ = NO;
  scheduler->corked_ = 0;

  return scheduler;
}


- (void) schedule: (NSData*) data
      forPriority: (NSUInteger) priority
        andStream: (uint32_t) stream_id
     withCallback: (ISpdySchedulerCallback) cb {
  NSAssert(self.delegate != nil, @"Delegate wasn't set");
  NSAssert(priority < [queues_ count], @"Priority OOB");

  ISpdySchedulerQueue* queue;
  if (stream_id == 0)
    queue = sync_;
  else
    queue = (ISpdySchedulerQueue*) [queues_ objectAtIndex: priority];

  // Clone the framer output
  NSData* clone = [NSData dataWithBytes: [data bytes] length: [data length]];
  if (cb == nil)
    [queue appendData: clone forStream: stream_id withCallback: ^() {}];
  else
    [queue appendData: clone forStream: stream_id withCallback: cb];
  pending_++;

  if (pending_dispatch_)
    return;

  pending_dispatch_ = YES;
  dispatch_async(dispatch_, ^() {
    // Someone has already unscheduled everything
    if (!pending_dispatch_)
      return;
    [self unschedule];
  });
}


- (void) unschedule {
  if (corked_ != 0)
    return;

  corked_++;
  ISpdySchedulerUnscheduleCallback cb = ^BOOL (NSData* data,
                                               ISpdySchedulerCallback done) {
    if ([self.delegate scheduledWrite: data withCallback: done]) {
      pending_--;
      return YES;
    }
    return NO;
  };

  // Write all sync data first
  if (![sync_ unschedule: cb])
    return;

  for (ISpdySchedulerQueue* queue in queues_)
    if (![queue unschedule: cb])
      break;

  // Let the parent know that we are done
  [self.delegate scheduledEnd];

  pending_dispatch_ = NO;

  // Prevent recursion
  corked_--;
}


- (void) cork {
  corked_++;
}


- (void) uncork {
  corked_--;
  if (corked_ != 0)
    return;

  pending_dispatch_ = YES;
  dispatch_async(dispatch_, ^() {
    // Someone has already unscheduled everything
    if (!pending_dispatch_)
      return;
    [self unschedule];
  });
}

@end

@implementation ISpdySchedulerQueue {
  NSMutableDictionary* map_;
  NSMutableArray* list_;
  NSUInteger index_;
}

+ (ISpdySchedulerQueue*) queueWithScheduler: (ISpdyScheduler*) scheduler {
  return [[ISpdySchedulerQueue alloc] initWithScheduler: scheduler];
}


- (ISpdySchedulerQueue*) initWithScheduler: (ISpdyScheduler*) scheduler {
  self.scheduler = scheduler;

  // TODO(indutny): no magic constants
  map_ = [NSMutableDictionary dictionaryWithCapacity: 100];
  list_ = [NSMutableArray arrayWithCapacity: 100];
  index_ = 0;
  return self;
}


- (void) appendData: (NSData*) data
          forStream: (uint32_t) stream_id
       withCallback: (ISpdySchedulerCallback) cb {
  NSNumber* key = [NSNumber numberWithUnsignedInt: stream_id];

  ISpdySchedulerItem* item = [map_ objectForKey: key];
  if (item == nil) {
    item = [ISpdySchedulerItem itemWithQueue: self andStream: stream_id];
    [map_ setObject: item forKey: key];
    [list_ addObject: item];
  }

  [item appendData: data withCallback: cb];
}


- (BOOL) unschedule: (ISpdySchedulerUnscheduleCallback) cb {
  while ([list_ count] > 0) {
    if (![self unscheduleOne: cb])
      return NO;
  }
  return YES;
}


- (BOOL) unscheduleOne: (ISpdySchedulerUnscheduleCallback) cb {
  index_ %= [list_ count];
  NSUInteger index = index_;
  index_++;

  ISpdySchedulerItem* item = [list_ objectAtIndex: index];
  BOOL result = [item unschedule: cb];

  if ([item isEmpty]) {
    NSNumber* key = [NSNumber numberWithUnsignedInt: item.stream_id];

    [list_ removeObjectAtIndex: index];
    [map_ removeObjectForKey: key];
  }

  return result;
}

@end

@implementation ISpdySchedulerItem {
  NSMutableArray* datas_;
  NSMutableArray* callbacks_;
}

+ (ISpdySchedulerItem*) itemWithQueue: (ISpdySchedulerQueue*) queue
                            andStream: (uint32_t) stream_id {
  return [[ISpdySchedulerItem alloc] initWithQueue: queue andStream: stream_id];
}


- (ISpdySchedulerItem*) initWithQueue: (ISpdySchedulerQueue*) queue
                            andStream: (uint32_t) stream_id {
  self.queue = queue;
  self.stream_id = stream_id;

  datas_ = [NSMutableArray arrayWithCapacity: kSchedulerItemCapacity];
  callbacks_ = [NSMutableArray arrayWithCapacity: kSchedulerItemCapacity];

  return self;
}


- (void) appendData: (NSData*) data withCallback: (ISpdySchedulerCallback) cb {
  [datas_ addObject: data];
  [callbacks_ addObject: cb];
}


- (BOOL) isEmpty {
  return [datas_ count] == 0;
}


- (BOOL) unschedule: (ISpdySchedulerUnscheduleCallback) done {
  NSData* data = [datas_ objectAtIndex: 0];
  ISpdySchedulerCallback cb = [callbacks_ objectAtIndex: 0];
  if (done(data, cb)) {
    [datas_ removeObjectAtIndex: 0];
    [callbacks_ removeObjectAtIndex: 0];
    return YES;
  }
  return NO;
}

@end
