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
#import <dispatch/dispatch.h>  // dispatch_source_t

#import "ispdy.h"
#import "common.h"
#import "compressor.h"  // ISpdyCompressor

#define LOG(level, ...)                                                       \
  [self.connection _log: (level)                                              \
                   file: @__FILE__                                            \
                   line: __LINE__                                             \
                 format: __VA_ARGS__]

static const NSTimeInterval kResponseTimeout = 60.0;  // 1 minute

@implementation ISpdyRequest {
  id <ISpdyRequestDelegate> delegate_;
  NSMutableArray* output_queue_;
  NSUInteger output_queue_size_;
  dispatch_source_t response_timeout_;
  NSTimeInterval response_timeout_interval_;
  NSMutableArray* connection_queue_;
  NSMutableArray* window_out_queue_;
}

- (id) init: (NSString*) method url: (NSString*) url {
  self = [super init];
  self.method = method;
  self.url = url;
  response_timeout_interval_ = kResponseTimeout;
  return self;
}


- (void) writeData: (NSData*) data {
  [self _connectionDispatch: ^{
    [self _resetTimeout];
    [self.connection _splitOutput: data
                          withFin: NO
                         andBlock: ^(NSData* data, BOOL fin) {
      [self _updateWindow: -(NSInteger) [data length] withBlock: ^() {
        [self.connection _writeData: data withFin: fin to: self];
      }];
    }];
  }];
}


- (void) writeString: (NSString*) str {
  [self writeData: [str dataUsingEncoding: NSUTF8StringEncoding]];
}


- (void) end {
  NSAssert(!self.closed_by_us, @"Stream already ended");

  [self _connectionDispatch: ^{
    [self _resetTimeout];
    [self.connection _writeData: nil withFin: YES to: self];
  }];
}

- (void) endWithData: (NSData*) data {
  [self _connectionDispatch: ^{
    [self _resetTimeout];
    [self.connection _splitOutput: data
                          withFin: YES
                         andBlock: ^(NSData* data, BOOL fin) {
      [self _updateWindow: -(NSInteger) [data length] withBlock: ^() {
        [self.connection _writeData: data withFin: fin to: self];
      }];
    }];
  }];
}

- (void) endWithString: (NSString*) str {
  [self endWithData: [str dataUsingEncoding: NSUTF8StringEncoding]];
}


- (void) addHeaders: (NSDictionary*) headers {
  [self _connectionDispatch: ^{
    [self.connection _addHeaders: headers to: self];
  }];
}


- (void) close {
  [self _connectionDispatch: ^{
     [self _close: nil sync: NO];
  }];
}


- (void) setTimeout: (NSTimeInterval) timeout {
  response_timeout_interval_ = timeout;

  [self _connectionDispatch: ^() {
    if (response_timeout_ != NULL) {
      dispatch_source_cancel(response_timeout_);
      response_timeout_ = NULL;
    }
    if (timeout == 0.0)
      return;

    // Queue timeout until sent
    if (self.connection == nil)
      return;

    response_timeout_ =
        [self.connection _timerWithTimeInterval: response_timeout_interval_
                                       andBlock: ^{
          [self.connection _error: self code: kISpdyErrRequestTimeout];
        }];
  }];
}

@end

@implementation ISpdyRequest (ISpdyRequestPrivate)

- (void) _setConnection: (ISpdy*) connection {
  // Make sure we can't be pushing to the queue
  @synchronized (self) {
    self.connection = connection;
  }

  if (connection == nil)
    return;

  NSArray* queue = connection_queue_;
  connection_queue_ = nil;
  if (queue == nil)
    return;

  // Invoke pending callbacks
  for (void (^block)(void) in queue)
    [self.connection _connectionDispatch: block];
}


- (void) _connectionDispatch: (void (^)()) block {
  @synchronized (self) {
    if (self.connection == nil) {
      if (connection_queue_ == nil)
        connection_queue_ = [NSMutableArray arrayWithCapacity: 2];

      [connection_queue_ addObject: block];
      return;
    }
  }

  [self.connection _connectionDispatch: block];
}


- (void) _handleResponseHeaders: (NSDictionary*) headers {
  NSString* encoding = [headers valueForKey: @"content-encoding"];
  if (encoding == nil)
    return;

  BOOL is_deflate = [encoding isEqualToString: @"deflate"];
  BOOL is_gzip = !is_deflate && [encoding isEqualToString: @"gzip"];

  if (is_deflate || is_gzip) {
    // Setup decompressor
    ISpdyCompressorMode mode;
    if (is_deflate)
      mode = kISpdyCompressorModeDeflate;
    else
      mode = kISpdyCompressorModeGzip;

    // NOTE: Version doesn't really matter here
    self.decompressor = [[ISpdyCompressor alloc] init: kISpdyV3 withMode: mode];
  }
}


- (NSError*) _decompress: (NSData*) data withBlock: (void (^)(NSData*)) block {
  if (self.decompressor == nil) {
    block(data);
    return nil;
  }

  if (![self.decompressor inflate: data])
    return [self.decompressor error];

  // Copy data out of decompressor's output as it is shared
  block([NSData dataWithData: [self.decompressor output]]);
  return nil;
}


- (void) _maybeClose {
  if (self.connection == nil)
    return;
  if (self.closed_by_us && self.closed_by_them)
    [self _close: nil sync: NO];
}


- (void) _close: (ISpdyError*) err sync: (BOOL) sync {
  if (self.connection == nil)
    return;

  void (^delegateBlock)(void) = ^{
    [self.delegate request: self handleEnd: err];
  };
  if (sync == YES)
    [self.connection _delegateDispatchSync: delegateBlock];
  else
    [self.connection _delegateDispatch: delegateBlock];

  [self setTimeout: 0.0];

  [self.connection _removeStream: self];

  self.closed_by_us = YES;
  self.closed_by_them = YES;
}


- (void) _resetTimeout {
  [self setTimeout: response_timeout_interval_];
}


- (void) _updateWindow: (NSInteger) delta withBlock: (void (^)()) block {
  if (delta < 0 && self.window_out <= 0) {
    if (block == nil)
      return;

    if (window_out_queue_ == nil)
      window_out_queue_ = [NSMutableArray arrayWithCapacity: 16];

    // Retry on positive window_out
    [window_out_queue_ addObject: ^() {
      [self _updateWindow: delta withBlock: block];
    }];
    return;
  }

  if (self.window_out <= 0 && self.window_out + delta > 0)
    LOG(kISpdyLogInfo, @"Window filled %d", self.window_out);
  self.window_out += delta;

  if (block != nil)
    block();

  // Frames no more
  if (self.window_out <= 0)
    return;

  // Invoke pending callbacks
  NSArray* queue = window_out_queue_;
  window_out_queue_ = nil;
  if (queue == nil)
    return;

  for (void (^block)() in queue) {
    block();
  }
}

@end
