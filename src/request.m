#import <Foundation/Foundation.h>

#import "ispdy.h"
#import "common.h"

static const NSTimeInterval kResponseTimeout = 60.0;  // 1 minute

@implementation ISpdyRequest {
  id <ISpdyRequestDelegate> delegate_;
  NSMutableArray* input_queue_;
  NSMutableArray* output_queue_;
  NSMutableDictionary* headers_queue_;
  NSMutableDictionary* in_headers_queue_;
  BOOL end_queued_;
  NSTimer* response_timeout_;
  NSTimeInterval response_timeout_interval_;
}

- (id) init: (NSString*) method url: (NSString*) url {
  self = [self init];
  self.method = method;
  self.url = url;
  return self;
}


- (void) writeData: (NSData*) data {
  if (self.connection == nil)
    return [self _queueOutput: data];

  [self.connection _connectionDispatch: ^{
    [self.connection _writeData: data to: self fin: NO];
  }];
}


- (void) writeString: (NSString*) str {
  [self writeData: [str dataUsingEncoding: NSUTF8StringEncoding]];
}


- (void) end {
  NSAssert(self.pending_closed_by_us == NO, @"Double end");

  // Request was either closed, or not opened yet, queue end.
  if (self.connection == nil) {
    self.pending_closed_by_us = YES;
    return;
  }
  [self.connection _connectionDispatch: ^{
    [self.connection _end: self];
  }];
}

- (void) endWithData: (NSData*) data {
  if (self.connection == nil) {
    [self _queueOutput: data];
    [self end];
    return;
  }

  [self.connection _connectionDispatch: ^{
    [self.connection _writeData: data to: self fin: YES];
  }];
}

- (void) endWithString: (NSString*) str {
  [self endWithData: [str dataUsingEncoding: NSUTF8StringEncoding]];
}


- (void) addHeaders: (NSDictionary*) headers {
  if (self.connection == nil)
    return [self _queueHeaders: headers];

  [self.connection _connectionDispatch: ^{
    [self.connection _addHeaders: headers to: self];
  }];
}


- (void) close {
  [self.connection _connectionDispatch: ^{
    [self _forceClose];
  }];
}


- (void) setTimeout: (NSTimeInterval) timeout {
  response_timeout_interval_ = timeout;

  [self.connection _connectionDispatch: ^() {
    [response_timeout_ invalidate];
    response_timeout_ = nil;
    if (timeout == 0.0)
      return;

    // Queue timeout until sent
    if (self.connection == nil)
      return;

    response_timeout_ =
        [self.connection _timerWithTimeInterval: response_timeout_interval_
                                         target: self
                                       selector: @selector(_onTimeout)
                                       userInfo: nil];
  }];
}

@end

@implementation ISpdyRequest (ISpdyRequestPrivate)

- (void) _tryClose {
  if (self.connection == nil)
    return;
  if (self.closed_by_us && self.closed_by_them)
    [self _forceClose];
}


- (void) _forceClose {
  if (self.connection == nil)
    return;

  [self setTimeout: 0.0];

  [self.connection _delegateDispatch: ^{
    if (self.delegate == nil) {
      [self.connection _connectionDispatch: ^{
        [self _queueEnd];
      }];
    } else {
      [self.delegate handleEnd: self];
    }
  }];
  self.closed_by_us = YES;
  self.closed_by_them = YES;
  self.pending_closed_by_us = NO;

  [self.connection _close: self];
}


- (void) _tryPendingClose {
  if (self.pending_closed_by_us) {
    self.pending_closed_by_us = NO;
    [self end];
  }
}


- (void) _resetTimeout {
  [self setTimeout: response_timeout_interval_ != 0.0 ?
      response_timeout_interval_ : kResponseTimeout];
}


- (void) _onTimeout {
  NSAssert(self.connection != nil, @"Request closed before timeout callback");
  [self.connection _connectionDispatch: ^{
    [self.connection _error: self code: kISpdyErrRequestTimeout];
  }];
}


- (void) _updateWindow: (NSInteger) delta {
  self.window_out += delta;

  // Try writing queued data
  if (self.window_out > 0)
    [self _unqueueOutput];
}


- (void) _handleError: (ISpdyError*) err {
  self.error = err;
  [self.delegate request: self handleError: err];
}


- (void) _queueOutput: (NSData*) data {
  if (output_queue_ == nil)
    output_queue_ = [NSMutableArray arrayWithCapacity: 16];

  [output_queue_ addObject: data];
}


- (void) _queueHeaders: (NSDictionary*) headers {
  if (headers_queue_ == nil) {
    headers_queue_ = [NSMutableDictionary dictionaryWithDictionary: headers];
    return;
  }

  // Insert key/values into existing dictionary
  [headers enumerateKeysAndObjectsUsingBlock: ^(NSString* key,
                                                NSString* val,
                                                BOOL* stop) {
    [headers_queue_ setValue: val forKey: key];
  }];
}


- (void) _queueEnd {
  NSAssert(end_queued_ == NO, @"Double end queue");
  end_queued_ = YES;
}


- (BOOL) _hasQueuedData {
  return [output_queue_ count] > 0;
}


- (void) _unqueueOutput {
  if (output_queue_ == nil)
    return;

  NSUInteger count = [output_queue_ count];
  for (NSUInteger i = 0; i < count; i++) {
    [self.connection _writeData: [output_queue_ objectAtIndex: i]
                             to: self
                            fin: NO];
  }

  [output_queue_ removeObjectsInRange: NSMakeRange(0, count)];
}


- (void) _unqueueHeaders {
  if (self.connection == nil || headers_queue_ == nil)
    return;

  [self addHeaders: headers_queue_];
  headers_queue_ = nil;
}

@end
