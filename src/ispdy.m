#import <CoreFoundation/CFStream.h>
#import <string.h>  // memmove

#import "ispdy.h"
#import "compressor.h"  // ISpdyCompressor
#import "framer.h"  // ISpdyFramer
#import "parser.h"  // ISpdyParser

@implementation ISpdy

- (id) init: (ISpdyVersion) version {
  self = [super init];
  if (!self)
    return self;

  version_ = version;
  comp_ = [[ISpdyCompressor alloc] init: version];
  framer_ = [[ISpdyFramer alloc] init: version compressor: comp_];
  parser_ = [[ISpdyParser alloc] init: version compressor: comp_];
  [parser_ setDelegate: self];
  stream_id_ = 1;

  streams_ = [[NSMutableDictionary alloc] initWithCapacity: 100];

  buffer_ = [[NSMutableData alloc] initWithCapacity: 4096];

  return self;
}


- (void) dealloc {
  [in_stream_ close];
  [out_stream_ close];
}


- (BOOL) connect: (NSString*) host port: (UInt32) port secure: (BOOL) secure {
  CFReadStreamRef cf_in_stream;
  CFWriteStreamRef cf_out_stream;

  CFStreamCreatePairWithSocketToHost(
      NULL,
      (__bridge CFStringRef) host,
      port,
      &cf_in_stream,
      &cf_out_stream);

  in_stream_ = (NSInputStream*) CFBridgingRelease(cf_in_stream);
  out_stream_ = (NSOutputStream*) CFBridgingRelease(cf_out_stream);

  if (in_stream_ == nil || out_stream_ == nil) {
    in_stream_ = nil;
    out_stream_ = nil;
    return NO;
  }

  NSRunLoop* loop = [NSRunLoop currentRunLoop];
  [in_stream_ setDelegate: self];
  [out_stream_ setDelegate: self];
  [in_stream_ scheduleInRunLoop: loop forMode: NSDefaultRunLoopMode];
  [out_stream_ scheduleInRunLoop: loop forMode: NSDefaultRunLoopMode];
  if (secure) {
    [in_stream_ setProperty: NSStreamSocketSecurityLevelNegotiatedSSL
                     forKey: NSStreamSocketSecurityLevelKey];
    [out_stream_ setProperty: NSStreamSocketSecurityLevelNegotiatedSSL
                      forKey: NSStreamSocketSecurityLevelKey];
  }
  [in_stream_ open];
  [out_stream_ open];

  return YES;
}


- (void) writeRaw: (NSData*) data {
  NSStreamStatus status = [out_stream_ streamStatus];

  // If stream is not open yet, or if there's already queued data -
  // queue more.
  if ((status != NSStreamStatusOpen && status != NSStreamStatusWriting) ||
      [buffer_ length] > 0) {
    [buffer_ appendData: data];
    return;
  }

  // Try writing to stream first
  NSInteger r = [out_stream_ write: [data bytes] maxLength: [data length]];
  if (r == -1)
    return [self handleError: [out_stream_ streamError]];

  // Only part of data was written, queue rest
  if (r < (NSInteger) [data length]) {
    const void* input = [data bytes] + r;
    [buffer_ appendBytes: input length: [data length] - r];
  }
}


- (void) handleError: (NSError*) err {
  // Already closed - ignore
  if (in_stream_ == nil || out_stream_ == nil)
    return;
  [in_stream_ close];
  [out_stream_ close];
  in_stream_ = nil;
  out_stream_ = nil;

  // Close all streams
  NSDictionary* streams = streams_;
  streams_ = nil;
  for (NSNumber* stream_id in streams) {
    ISpdyRequest* req = [streams objectForKey: stream_id];
    [req.delegate request: req handleError: err];
    [req.delegate handleEnd: req];
  }

  // Fire global error
  [self.delegate connection: self handleError: err];
}


- (void) send: (ISpdyRequest*) request {
  NSAssert(request.connection == nil, @"Request was already sent");

  if (request.connection != nil)
    return;
  request.stream_id = stream_id_;
  request.connection = self;
  stream_id_ += 2;

  [framer_ clear];
  [framer_ synStream: request.stream_id
            priority: 0
              method: request.method
                  to: request.url
             headers: request.headers];
  [self writeRaw: [framer_ output]];

  NSNumber* request_key = [NSNumber numberWithUnsignedInt: request.stream_id];
  [streams_ setObject: request forKey: request_key];
}


- (void) writeData: (NSData*) data to: (ISpdyRequest*) request {
  NSAssert(request.connection != nil, @"Request was closed");

  [framer_ clear];
  [framer_ dataFrame: request.stream_id
                 fin: 0
            withData: data];

  if (request.seen_response)
    [self writeRaw: [framer_ output]];
  else
    [request buffer: [framer_ output]];
}


- (void) rst: (uint32_t) stream_id code: (uint8_t) code {
  [framer_ clear];
  [framer_ rst: stream_id code: code];
  [self writeRaw: [framer_ output]];
}


- (void) error: (ISpdyRequest*) request code: (ISpdyErrorCode) code {
  [self rst: request.stream_id code: code];
  NSError* err = [NSError errorWithDomain: @"spdy"
                                     code: code
                                 userInfo: nil];
  [request.delegate request: request handleError: err];
}


- (void) end: (ISpdyRequest*) request {
  NSAssert(request.connection != nil, @"Request was already closed");
  NSAssert(request.closed_by_us == NO, @"Request already awaiting other side");
  NSAssert(request.pending_closed_by_us == NO,
           @"Request already awaiting other side");

  [framer_ clear];
  [framer_ dataFrame: request.stream_id
                 fin: 1
            withData: nil];
  if (request.seen_response) {
    request.closed_by_us = YES;
    [self writeRaw: [framer_ output]];
    [request _tryClose];
  } else {
    request.pending_closed_by_us = YES;
    [request buffer: [framer_ output]];
  }
}


- (void) close: (ISpdyRequest*) request {
  NSAssert(request.connection != nil, @"Request was already closed");
  request.connection = nil;

  if (!request.closed_by_us) {
    [self rst: request.stream_id code: kISpdyRstCancel];
    request.closed_by_us = YES;
  }

  NSNumber* request_key = [NSNumber numberWithUnsignedInt: request.stream_id];
  [streams_ removeObjectForKey: request_key];
}

// NSSocket delegate methods

- (void) stream: (NSStream*) stream handleEvent: (NSStreamEvent) event {
  if (event == NSStreamEventErrorOccurred)
    return [self handleError: [stream streamError]];

  if (event == NSStreamEventEndEncountered) {
    return [self handleError: [NSError errorWithDomain: @"spdy"
                                                  code: kISpdyErrConnectionEnd
                                              userInfo: nil]];
  }

  if (event == NSStreamEventHasSpaceAvailable && [buffer_ length] > 0) {
    NSAssert(out_stream_ == stream, @"Write event on input stream?!");

    // Socket available for write
    NSInteger r = [out_stream_ write: [buffer_ bytes]
                           maxLength: [buffer_ length]];
    if (r == -1)
      return [self handleError: [out_stream_ streamError]];

    // Shift data
    if (r < (NSInteger) [buffer_ length]) {
      void* bytes = [buffer_ mutableBytes];
      memmove(bytes, bytes + r, [buffer_ length] - r);
    }
    // Truncate
    [buffer_ setLength: [buffer_ length] - r];
  } else if (event == NSStreamEventHasBytesAvailable) {
    NSAssert(in_stream_ == stream, @"Read event on output stream?!");

    // Socket available for read
    uint8_t buf[1024];
    while ([in_stream_ hasBytesAvailable]) {
      NSInteger r = [in_stream_ read: buf maxLength: sizeof(buf)];
      if (r == 0)
        break;
      else if (r < 0)
        return [self handleError: [in_stream_ streamError]];

      [parser_ execute: buf length: (NSUInteger) r];
    }
  }
}

// Parser delegate methods

- (void) handleFrame: (ISpdyFrameType) type
                body: (id) body
              is_fin: (BOOL) is_fin
           forStream: (uint32_t) stream_id {
  ISpdyRequest* req = nil;

  if (type == kISpdySynReply ||
      type == kISpdyRstStream ||
      type == kISpdyData) {
    req = [streams_ objectForKey: [NSNumber numberWithUnsignedInt: stream_id]];

    // If stream isn't found - notify server about it,
    // but don't reply with RST for RST to prevent echoing each other
    // indefinitely.
    if (req == nil && type != kISpdyRstStream) {
      [self rst: stream_id code: kISpdyRstProtocolError];
      NSError* err = [NSError errorWithDomain: @"spdy"
                                         code: kISpdyErrNoSuchStream
                                     userInfo: nil];
      return [self handleError: err];
    }
  }

  // Stream was already ended, this is probably a harmless race condition on
  // server.
  if (req != nil && req.connection == nil)
    return;

  switch (type) {
    case kISpdyData:
      [req.delegate request: req handleInput: (NSData*) body];
      break;
    case kISpdySynReply:
      if (req.seen_response)
        return [self error: req code: kISpdyErrDoubleResponse];
      req.seen_response = YES;
      [req.delegate request: req handleResponse: body];

      // Write queued data
      if ([req buffer] != nil) {
        [self writeRaw: [req buffer]];
        [req clearBuffer];

        // End request, if its pending
        if (req.pending_closed_by_us) {
          req.pending_closed_by_us = NO;
          if (!req.closed_by_us) {
            req.closed_by_us = YES;
            [req _tryClose];
          }
        }
      }
      break;
    case kISpdyRstStream:
      {
        NSError* err = [NSError errorWithDomain: @"spdy"
                                           code: kISpdyErrRst
                                       userInfo: nil];
        [req.delegate request: req handleError: err];
        [req close];
      }
      break;
    default:
      // Ignore
      break;
  }

  if (is_fin)
    [req.delegate handleEnd: req];
}


- (void) handleParseError {
  // TODO(indutny): Propagate stream_id here and send RST
  return [self handleError: [NSError errorWithDomain: @"spdy"
                                                code: kISpdyErrParseError
                                            userInfo: nil]];
}

@end


@implementation ISpdyRequest

- (id) init: (NSString*) method url: (NSString*) url {
  self = [self init];
  self.method = method;
  self.url = url;
  return self;
}


- (void) writeData: (NSData*) data {
  [self.connection writeData: data to: self];
}


- (void) writeString: (NSString*) str {
  [self.connection writeData: [str dataUsingEncoding: NSUTF8StringEncoding]
                   to: self];
}


- (void) end {
  [self.connection end: self];
}


- (void) close {
  [self.connection close: self];
}


- (void) _tryClose {
  if (self.closed_by_us && self.closed_by_them) {
    [self.delegate handleEnd: self];
    [self close];
  }
}


- (void) buffer: (NSData*) data {
  if (buffer_ == nil)
    buffer_ = [NSMutableData dataWithData: data];
  else
    [buffer_ appendData: data];
}

- (void) clearBuffer {
  buffer_ = nil;
}

- (NSData*) buffer {
  return buffer_;
}

@end

@implementation ISpdyResponse

// No-op, only to generate properties' accessors

@end
