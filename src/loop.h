#import <Foundation/Foundation.h>

@interface ISpdyLoop : NSThread

+ (NSRunLoop*) defaultLoop;

- (id) init;
- (void) main;
- (NSRunLoop*) runLoop;

@end
