#import <CoreFoundation/CFStream.h>
#import <string.h>  // memmove

#import "ispdy.h"
#import "framer.h"  // iSpdyFramer

@implementation iSpdy

- (id) init: (iSpdyVersion) version {
  self = [super init];
  if (!self)
    return self;

  version_ = version;
  framer_ = [[iSpdyFramer alloc] init: version];
  stream_id_ = 1;

  streams_ = [[NSMutableDictionary alloc] initWithCapacity: 100];

  buffer_ = [[NSMutableData alloc] initWithCapacity: 4096];

  return self;
}


- (void) dealloc {
  [in_stream_ close];
  [out_stream_ close];
  [in_stream_ release];
  [out_stream_ release];
  [framer_ release];
  [streams_ release];
  [buffer_ release];

  [super dealloc];
}


- (BOOL) connect: (NSString*) host port: (UInt32) port {
  CFReadStreamRef cf_in_stream;
  CFWriteStreamRef cf_out_stream;

  CFStreamCreatePairWithSocketToHost(
      NULL,
      (CFStringRef) host,
      port,
      &cf_in_stream,
      &cf_out_stream);

  in_stream_ = (NSInputStream*) cf_in_stream;
  out_stream_ = (NSOutputStream*) cf_out_stream;

  if (in_stream_ == nil || out_stream_ == nil) {
    [in_stream_ release];
    [out_stream_ release];
    return NO;
  }

  NSRunLoop* loop = [NSRunLoop currentRunLoop];
  [in_stream_ setDelegate: self];
  [out_stream_ setDelegate: self];
  [in_stream_ scheduleInRunLoop: loop forMode: NSDefaultRunLoopMode];
  [out_stream_ scheduleInRunLoop: loop forMode: NSDefaultRunLoopMode];
/*  [in_stream_ setProperty: NSStreamSocketSecurityLevelNegotiatedSSL
                   forKey: NSStreamSocketSecurityLevelKey];
  [out_stream_ setProperty: NSStreamSocketSecurityLevelNegotiatedSSL
                    forKey: NSStreamSocketSecurityLevelKey];*/
  [in_stream_ open];
  [out_stream_ open];

  return YES;
}


- (void) writeRaw: (NSData*) data {
  // Has buffered data, just queue more and wait until event
  if ([buffer_ length] > 0) {
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
  [in_stream_ release];
  [out_stream_ release];
  in_stream_ = nil;
  out_stream_ = nil;

  // Close all streams
  for (iSpdyRequest* req in streams_) {
    [self.delegate request: req handleError: err];
  }
  [streams_ removeAllObjects];

  // Fire global error
  [self.delegate connection: self handleError: err];
}


- (void) send: (iSpdyRequest*) request {
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

  [streams_ setObject: request
               forKey: [NSNumber numberWithInt: request.stream_id]];
}


- (void) writeData: (NSData*) data to: (iSpdyRequest*) request {
  NSAssert(request.connection != nil, @"Request was ended");

  // TODO(indutny): wait for SYN_REPLY
  [framer_ clear];
  [framer_ dataFrame: request.stream_id
                 fin: 0
            withData: data];
  [self writeRaw: [framer_ output]];
}


- (void) end: (iSpdyRequest*) request {
  NSAssert(request.connection != nil, @"Request was already ended");
  request.connection = nil;
  [framer_ clear];
  [framer_ dataFrame: request.stream_id
                 fin: 1
            withData: nil];
  [self writeRaw: [framer_ output]];
  [streams_ removeObjectForKey: [NSNumber numberWithInt: request.stream_id]];
}


- (void) stream: (NSStream*) stream handleEvent: (NSStreamEvent) event {
  if (event == NSStreamStatusError)
    return [self handleError: [stream streamError]];

  if (event == NSStreamEventEndEncountered) {
    return [self handleError: [NSError errorWithDomain: @"spdy"
                                                  code: iSpdyConnectionEnd
                                              userInfo: nil]];
  }

  if (event == NSStreamEventHasSpaceAvailable && [buffer_ length] > 0) {
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
  }
}

@end


@implementation iSpdyRequest

- (id) init: (NSString*) method url: (NSString*) url {
  self = [self init];
  self.method = method;
  self.url = url;
  return self;
}


- (void) writeData: (NSData*) data {
  NSAssert(self.connection != nil, @"Request was ended");
  [self.connection writeData: data to: self];
}


- (void) writeString: (NSString*) str {
  NSAssert(self.connection != nil, @"Request was ended");
  [self.connection writeData: [str dataUsingEncoding: NSUTF8StringEncoding] 
                   to: self];
}


- (void) end {
  NSAssert(self.connection != nil, @"Request was already ended");
  [self.connection end: self];
}

@end
