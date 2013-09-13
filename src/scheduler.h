#import <Foundation/Foundation.h>

@protocol ISpdySchedulerDelegate

- (NSInteger) scheduledWrite: (NSData*) data;

@end

@interface ISpdyScheduler : NSObject

@property id <ISpdySchedulerDelegate> delegate;

+ (ISpdyScheduler*) schedulerWithMaxPriority: (NSUInteger) maxPriority;
- (void) schedule: (NSData*) data withPriority: (NSUInteger) priority;
- (void) unschedule;

@end
