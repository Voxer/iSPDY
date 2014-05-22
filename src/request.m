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
  NSMutableArray* input_queue_;
  NSMutableArray* output_queue_;
  NSMutableDictionary* headers_queue_;
  NSMutableDictionary* in_headers_queue_;
  dispatch_source_t response_timeout_;
  NSTimeInterval response_timeout_interval_;
}

- (id) init: (NSString*) method url: (NSString*) url {
  self = [super init];
  self.method = method;
  self.url = url;
  response_timeout_interval_ = kResponseTimeout;
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
  NSAssert(self.pending_closed_by_us == NO || self.closed_by_us,
           @"Stream already ended");

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
     [self _close: nil sync: NO];
  }];
}


- (void) setTimeout: (NSTimeInterval) timeout {
  response_timeout_interval_ = timeout;

  [self.connection _connectionDispatch: ^() {
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


- (void) _tryClose {
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

  self.pending_closed_by_us = NO;
  [self.connection _removeStream: self];

  self.closed_by_us = YES;
  self.closed_by_them = YES;
}


- (void) _tryPendingClose {
  if (self.pending_closed_by_us) {
    self.pending_closed_by_us = NO;
    [self end];
  }
}


- (void) _resetTimeout {
  [self setTimeout: response_timeout_interval_];
}


- (void) _updateWindow: (NSInteger) delta {
  if (self.window_out <= 0 && self.window_out + delta > 0)
    LOG(kISpdyLogInfo, @"Window filled %d", self.window_out);
  self.window_out += delta;

  // Try writing queued data
  if (self.window_out > 0)
    [self _unqueueOutput];
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
