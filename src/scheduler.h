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

typedef void (^ISpdySchedulerCallback)();
typedef BOOL (^ISpdySchedulerUnscheduleCallback)(NSData* data,
                                                 ISpdySchedulerCallback cb);

@protocol ISpdySchedulerDelegate

- (BOOL) scheduledWrite: (NSData*) data
           withCallback: (ISpdySchedulerCallback) cb;
- (void) scheduledEnd;

@end

@interface ISpdyScheduler : NSObject

@property id <ISpdySchedulerDelegate> delegate;

+ (ISpdyScheduler*) schedulerWithMaxPriority: (NSUInteger) maxPriority
                                 andDispatch: (dispatch_queue_t) dispatch;

- (void) schedule: (NSData*) data
      forPriority: (NSUInteger) priority
        andStream: (uint32_t) stream_id
     withCallback: (ISpdySchedulerCallback) cb;
- (void) unschedule;
- (void) cork;
- (void) uncork;

@end

@interface ISpdySchedulerQueue : NSObject

@property (weak) ISpdyScheduler* scheduler;

+ (ISpdySchedulerQueue*) queueWithScheduler: (ISpdyScheduler*) scheduler;
- (ISpdySchedulerQueue*) initWithScheduler: (ISpdyScheduler*) scheduler;

- (void) appendData: (NSData*) data
         forStream: (uint32_t) stream_id
       withCallback: (ISpdySchedulerCallback) cb;
- (BOOL) unschedule: (ISpdySchedulerUnscheduleCallback) cb;
- (BOOL) unscheduleOne: (ISpdySchedulerUnscheduleCallback) cb;

@end

@interface ISpdySchedulerItem : NSObject

@property (weak) ISpdySchedulerQueue* queue;
@property uint32_t stream_id;

+ (ISpdySchedulerItem*) itemWithQueue: (ISpdySchedulerQueue*) queue
                            andStream: (uint32_t) stream_id;
- (ISpdySchedulerItem*) initWithQueue: (ISpdySchedulerQueue*) queue
                            andStream: (uint32_t) stream_id;

- (void) appendData: (NSData*) data withCallback: (ISpdySchedulerCallback) cb;
- (BOOL) isEmpty;
- (BOOL) unschedule: (ISpdySchedulerUnscheduleCallback) cb;

@end
