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

#import <CoreFoundation/CFStream.h>
#import <CFNetwork/CFSocketStream.h>
#import <dispatch/dispatch.h>  // dispatch_queue_t
#import <netinet/in.h>  // IPPROTO_TCP
#import <netinet/tcp.h>  // TCP_NODELAY
#import <string.h>  // memmove
#import <sys/socket.h>  // setsockopt

#import "ispdy.h"
#import "common.h"  // Common internal parts
#import "compressor.h"  // ISpdyCompressor
#import "framer.h"  // ISpdyFramer
#import "loop.h"  // ISpdyLoop
#import "parser.h"  // ISpdyParser
#import "scheduler.h"  // ISpdyScheduler

static const NSInteger kSocketInBufSize = 65536;
static const NSInteger kInitialWindowSizeIn = 1048576;
static const NSInteger kInitialWindowSizeOut = 65536;
static const NSUInteger kMaxPriority = 7;
static const NSTimeInterval kConnectTimeout = 30.0;  // 30 seconds

typedef enum {
  kISpdySSLPinningNone,
  kISpdySSLPinningRejected,
  kISpdySSLPinningApproved
} ISpdySSLPinningResult;

// Implementations

@implementation ISpdy {
  ISpdyVersion version_;
  UInt16 port_;
  BOOL secure_;
  NSInputStream* in_stream_;
  NSOutputStream* out_stream_;
  ISpdyCompressor* in_comp_;
  ISpdyCompressor* out_comp_;
  ISpdyFramer* framer_;
  ISpdyParser* parser_;
  ISpdyScheduler* scheduler_;
  BOOL no_delay_;
  NSInteger keep_alive_;

  // SSL pinned certs
  NSMutableSet* pinned_certs_;
  ISpdySSLPinningResult pinned_check_result_;

  // Run loop
  BOOL on_ispdy_loop_;
  NSMutableSet* scheduled_loops_;
  dispatch_source_t connection_timeout_;
  dispatch_source_t goaway_timeout_;
  struct timeval last_frame_;

  // Next stream's id
  uint32_t stream_id_;
  NSInteger active_streams_;

  // Goaway status
  BOOL goaway_;

  // Window size
  NSInteger initial_window_;

  // Next ping's id
  uint32_t ping_id_;

  // Dictionary of all streams
  NSMutableDictionary* streams_;

  // Dictionary of all client-initiated pings pings
  NSMutableDictionary* pings_;

  // Connection write buffer
  NSMutableData* buffer_;

  // Dispatch queue for invoking methods on delegates
  dispatch_queue_t delegate_queue_;

  // Dispatch queue for invoking methods on parser loop and
  // working with connection's state
  dispatch_queue_t connection_queue_;
}

- (id) init: (ISpdyVersion) version
       host: (NSString*) host
   hostname: (NSString*) hostname
       port: (UInt16) port
     secure: (BOOL) secure {
  self = [super init];
  if (!self)
    return self;

  version_ = version;
  port_ = port;
  secure_ = secure;

  in_comp_ = [[ISpdyCompressor alloc] init: version];
  out_comp_ = [[ISpdyCompressor alloc] init: version];
  framer_ = [[ISpdyFramer alloc] init: version compressor: out_comp_];
  parser_ = [[ISpdyParser alloc] init: version compressor: in_comp_];
  scheduler_ = [ISpdyScheduler schedulerWithMaxPriority: kMaxPriority];
  _last_frame = &last_frame_;
  _state = kISpdyStateInitial;

  scheduler_.delegate = self;
  parser_.delegate = self;

  _host = host;
  _hostname = hostname;

  stream_id_ = 1;
  active_streams_ = 0;
  ping_id_ = 1;
  goaway_ = NO;
  keep_alive_ = -1;
  initial_window_ = kInitialWindowSizeOut;

  streams_ = [[NSMutableDictionary alloc] initWithCapacity: 100];
  pings_ = [[NSMutableDictionary alloc] initWithCapacity: 10];

  // Truncate or create buffer
  if (buffer_ != nil)
    [buffer_ setLength: 0];
  else
    buffer_ = [[NSMutableData alloc] initWithCapacity: 4096];

  // Initialize pinned certs
  if (pinned_certs_ == nil)
    pinned_certs_ = [NSMutableSet setWithCapacity: 1];

  // Initialize storage for loops
  if (scheduled_loops_ == nil)
    scheduled_loops_ = [NSMutableSet setWithCapacity: 1];

  // Initialize connection
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
    return nil;
  }

  in_stream_.delegate = self;
  out_stream_.delegate = self;

  // Initialize encryption
  if (secure) {
    [in_stream_ setProperty: NSStreamSocketSecurityLevelNegotiatedSSL
                     forKey: NSStreamSocketSecurityLevelKey];
    [out_stream_ setProperty: NSStreamSocketSecurityLevelNegotiatedSSL
                      forKey: NSStreamSocketSecurityLevelKey];
    if (![host isEqualToString: hostname]) {
      NSString* peer_name = (__bridge NSString*) kCFStreamSSLPeerName;
      NSString* ssl_settings =
          (__bridge NSString*) kCFStreamPropertySSLSettings;
      NSDictionary* settings =
          [NSDictionary dictionaryWithObject: hostname forKey: peer_name];
      if (![in_stream_ setProperty: settings forKey: ssl_settings] ||
          ![out_stream_ setProperty: settings forKey: ssl_settings]) {
        NSAssert(NO, @"Failed to set SSL hostname");
      }
    }
  }

  if (delegate_queue_ == nil) {
    // Initialize dispatch queue
    delegate_queue_ = dispatch_queue_create("com.voxer.ispdy.delegate",
                                            NULL);
    NSAssert(delegate_queue_ != NULL, @"Failed to get main queue");
    connection_queue_ = dispatch_queue_create("com.voxer.ispdy.connection",
                                              NULL);
    NSAssert(connection_queue_ != NULL, @"Failed to get main queue");
  }

  return self;
}

- (id) init: (ISpdyVersion) version
       host: (NSString*) host
       port: (UInt16) port
     secure: (BOOL) secure {
  return [self init: version
               host: host
           hostname: host
               port: port
             secure: secure];
}


- (void) dealloc {
  delegate_queue_ = NULL;
  connection_queue_ = NULL;
}


- (void) scheduleInRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode {
  ISpdyLoopWrap* wrap = [ISpdyLoopWrap stateForLoop: loop andMode: mode];

  [self _connectionDispatch: ^{
    [scheduled_loops_ addObject: wrap];

    [in_stream_ scheduleInRunLoop: wrap.loop forMode: wrap.mode];
    [out_stream_ scheduleInRunLoop: wrap.loop forMode: wrap.mode];
  }];
}


- (void) removeFromRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode {
  ISpdyLoopWrap* wrap = [ISpdyLoopWrap stateForLoop: loop andMode: mode];
  [self _connectionDispatch: ^{
    [scheduled_loops_ removeObject: wrap];

    [in_stream_ removeFromRunLoop: wrap.loop forMode: wrap.mode];
    [out_stream_ removeFromRunLoop: wrap.loop forMode: wrap.mode];
  }];
}


- (void) setDelegateQueue: (dispatch_queue_t) queue {
  NSAssert(queue != NULL, @"Empty delegate queue!");
  [self _connectionDispatch: ^{
    delegate_queue_ = queue;
  }];
}


- (void) setNoDelay: (BOOL) enable {
  [self _connectionDispatch: ^{
    NSStreamStatus status = [out_stream_ streamStatus];

    // If stream is not open yet, queue setting option
    if (status != NSStreamStatusOpen && status != NSStreamStatusWriting) {
      no_delay_ = YES;
      return;
    }

    __block int r;
    [self _fdWithBlock: ^(CFSocketNativeHandle fd) {
      int ienable = enable;
      r = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &ienable, sizeof(ienable));
    }];
    NSAssert(r == 0, @"Set NODELAY failed");
  }];
}


- (void) setKeepAlive: (NSInteger) keepalive {
  [self _connectionDispatch: ^{
    NSStreamStatus status = [out_stream_ streamStatus];

    // If stream is not open yet, queue setting option
    if (status != NSStreamStatusOpen && status != NSStreamStatusWriting) {
      keep_alive_ = keepalive;
      return;
    }

    __block int r;
    [self _fdWithBlock: ^(CFSocketNativeHandle fd) {
      int enable = keepalive != 0;
      int ikeepalive = (int) keepalive;

      r = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &enable, sizeof(enable));
      if (r == 0 && enable) {
        r = setsockopt(fd,
                       IPPROTO_TCP,
                       TCP_KEEPALIVE,
                       &ikeepalive,
                       sizeof(ikeepalive));
      }
    }];
    NSAssert(r == 0, @"Set NODELAY failed");
  }];
}


- (void) enableVoip {
  [self _connectionDispatch: ^{
    [in_stream_ setProperty: NSStreamNetworkServiceTypeVoIP
                     forKey: NSStreamNetworkServiceType];
  }];
}


- (BOOL) connect {
  // Reinitialize streams if connection was closed
  if (in_stream_ == nil) {
    NSAssert(out_stream_ == nil, @"Both streams should be closed");

    (void) [self init: version_
                 host: _host
             hostname: _hostname
                 port: port_
               secure: secure_];
  }

  [self _lazySchedule];

  _state = kISpdyStateConnecting;
  [in_stream_ open];
  [out_stream_ open];

  // Send initial window
  if (version_ != kISpdyV2) {
    [self _connectionDispatch: ^{
      [framer_ clear];
      [framer_ initialWindow: kInitialWindowSizeIn];
      [self _writeRaw: [framer_ output] withMode: kISpdyWriteChunkBuffering];
    }];
  }

  // Start timer
  [self setTimeout: kConnectTimeout];

  return YES;
}


- (BOOL) connectWithTimeout: (NSTimeInterval) timeout {
  BOOL r = [self connect];
  if (!r)
    return r;

  [self setTimeout: timeout];

  return r;
}


- (BOOL) close {
  if (in_stream_ == nil || out_stream_ == nil)
    return NO;

  [self _connectionDispatch: ^{
    if (goaway_timeout_ != NULL)
      dispatch_source_cancel(goaway_timeout_);
    if (connection_timeout_ != NULL)
      dispatch_source_cancel(connection_timeout_);
    goaway_timeout_ = NULL;
    connection_timeout_ = NULL;
    self.goaway_retain_ = nil;

    _state = kISpdyStateClosed;
    [in_stream_ close];
    [out_stream_ close];
    in_stream_ = nil;
    out_stream_ = nil;

    if (on_ispdy_loop_) {
      on_ispdy_loop_ = NO;
      [self removeFromRunLoop: [ISpdyLoop defaultLoop]
                      forMode: NSDefaultRunLoopMode];
    }

    [self _closeStreams: [ISpdyError errorWithCode: kISpdyErrClose]];
  }];

  return YES;
}


- (void) closeSoon: (NSTimeInterval) timeout {
  self.goaway_retain_ = self;
  [self _connectionDispatch: ^{
    NSAssert(!goaway_, @"closeSoon called twice");

    if (timeout != 0.0) {
      goaway_timeout_ = [self _timerWithTimeInterval: timeout andBlock: ^{
        // Force close connection
        [self close];
      }];
    }
    goaway_ = YES;

    [framer_ clear];
    [framer_ goaway: stream_id_ - 2 status: kISpdyGoawayOk];
    [self _writeRaw: [framer_ output] withMode: kISpdyWriteChunkBuffering];

    // Close connection if needed
    [self _handleDrain];
  }];
}


- (void) send: (ISpdyRequest*) request {
  NSAssert(request != nil, @"Received nil as stream to send");
  NSAssert(request.connection == nil, @"Request was already sent");

  if (request.connection != nil)
    return;
  request.connection = self;

  [self _connectionDispatch: ^{
    NSAssert(!goaway_, @"Can't send streams after GOAWAY was sent/received");

    request.initial_window_in = kInitialWindowSizeIn;
    request.initial_window_out = initial_window_;
    request.window_in = request.initial_window_in;
    request.window_out = request.initial_window_out;
    request.stream_id = stream_id_;
    stream_id_ += 2;

    NSNumber* request_key = [NSNumber numberWithUnsignedInt: request.stream_id];
    [streams_ setObject: request forKey: request_key];
    active_streams_++;

    [framer_ clear];
    [framer_ synStream: request.stream_id
              priority: request.priority
                method: request.method
                    to: request.url
               headers: request.headers];
    [self _writeRaw: [framer_ output] withMode: kISpdyWriteChunkBuffering];

    // Send body if accumulated
    [request _unqueueOutput];

    // Send trailing headers
    [request _unqueueHeaders];

    // Start timer, if needed
    [request _resetTimeout];
  }];
}


- (void) ping: (ISpdyPingCallback) block waitMax: (NSTimeInterval) wait {
  [self _connectionDispatch: ^{
    ISpdyPing* ping = [ISpdyPing alloc];

    ping.ping_id = [NSNumber numberWithUnsignedInt: ping_id_];
    ping_id_ += 2;
    ping.block = block;
    ping.timeout = [self _timerWithTimeInterval: wait andBlock: ^{
      [pings_ removeObjectForKey: ping.ping_id];

      [self _delegateDispatch: ^{
        ping.block(kISpdyPingTimedOut, -1.0);
      }];
    }];
    ping.start_date = [NSDate date];
    [pings_ setObject: ping forKey: ping.ping_id];

    [framer_ clear];
    [framer_ ping: (uint32_t) [ping.ping_id integerValue]];
    [self _writeRaw: [framer_ output]
           withMode: kISpdyWriteChunkBuffering];
  }];
}


- (void) setTimeout: (NSTimeInterval) timeout {
  [self _connectionDispatch: ^() {
    if (connection_timeout_ != NULL) {
      dispatch_source_cancel(connection_timeout_);
      connection_timeout_ = NULL;
    }
    if (timeout == 0.0)
      return;

    connection_timeout_ = [self _timerWithTimeInterval: timeout andBlock: ^{
      [self _handleError:
          [ISpdyError errorWithCode: kISpdyErrConnectionTimeout]];
    }];
  }];
}


- (void) addPinnedSSLCert: (NSData*) cert {
  [pinned_certs_ addObject: cert];
}

@end

@implementation ISpdy (ISpdyPrivate)

- (void) _delegateDispatch: (void (^)()) block {
  dispatch_async(delegate_queue_, block);
}


- (void) _delegateDispatchSync: (void (^)()) block {
  dispatch_sync(delegate_queue_, block);
}


- (void) _connectionDispatch: (void (^)()) block {
  dispatch_async(connection_queue_, block);
}


- (void) _connectionDispatchSync: (void (^)()) block {
  dispatch_sync(connection_queue_, block);
}


- (void) _fdWithBlock: (void(^)(CFSocketNativeHandle)) block {
  CFDataRef data =
      CFWriteStreamCopyProperty((__bridge CFWriteStreamRef) out_stream_,
                                kCFStreamPropertySocketNativeHandle);
  NSAssert(data != NULL, @"CFWriteStreamCopyProperty failed");
  CFSocketNativeHandle handle;
  CFDataGetBytes(data, CFRangeMake(0, sizeof(handle)), (UInt8*) &handle);

  block(handle);

  CFRelease(data);
}


- (void) _lazySchedule {
  if ([scheduled_loops_ count] == 0) {
    on_ispdy_loop_ = YES;
    [self scheduleInRunLoop: [ISpdyLoop defaultLoop]
                    forMode: NSDefaultRunLoopMode];
  }
}


- (dispatch_source_t) _timerWithTimeInterval: (NSTimeInterval) interval
                                    andBlock: (void (^)()) block {
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                   0,
                                                   0,
                                                   connection_queue_);
  NSAssert(timer, @"Failed to create dispatch timer source");

  dispatch_source_set_timer(timer,
                            dispatch_walltime(NULL, (int64_t) interval * 1e9),
                            0,
                            0);
  dispatch_source_set_event_handler(timer, block);
  dispatch_resume(timer);

  return timer;
}


- (NSInteger) scheduledWrite: (NSData*) data {
  return [self _writeRaw: data withMode: kISpdyWriteNoChunkBuffering];
}


- (NSInteger) _writeRaw: (NSData*) data withMode: (ISpdyWriteMode) mode {
  NSStreamStatus status = [out_stream_ streamStatus];

  if (status == NSStreamStatusNotOpen) {
    ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrConnectionEnd];
    [self _handleError: err];
    return [data length];
  }

  // If stream is not open yet, or if there's already queued data -
  // queue more.
  if ((status != NSStreamStatusOpen && status != NSStreamStatusWriting) ||
      [buffer_ length] > 0) {
    if (mode != kISpdyWriteNoChunkBuffering) {
      [buffer_ appendData: data];
      return [data length];
    }
    return 0;
  }

  // Try writing to stream first
  NSInteger r = [out_stream_ write: [data bytes] maxLength: [data length]];

  // Error will be handled on socket level, no need in buffering
  if (r == -1)
    return [data length];

  if (mode == kISpdyWriteNoChunkBuffering)
    return r;

  // Only part of data was written, queue rest
  if (r < (NSInteger) [data length]) {
    const void* input = [data bytes] + r;
    [buffer_ appendBytes: input length: [data length] - r];
  }

  return r;
}


- (void) _handleError: (ISpdyError*) err {
  // Already closed - ignore
  if (![self close])
    return;

  // Ensure that state is closed to avoid races
  _state = kISpdyStateClosed;

  // Fire global error
  [self _delegateDispatch: ^{
    [self.delegate connection: self handleError: err];
  }];

  // Fire stream errors
  [self _closeStreams: err];
  [self _destroyPings: err];
}


- (void) _closeStreams: (ISpdyError*) err {
  // Close all streams
  NSDictionary* streams = streams_;
  streams_ = nil;
  for (NSNumber* stream_id in streams) {
    ISpdyRequest* req = [streams objectForKey: stream_id];
    [req _close: err sync: YES];
  }
  active_streams_ = 0;
  [self _handleDrain];
}


- (void) _destroyPings: (ISpdyError*) err {
  NSDictionary* pings = pings_;
  pings_ = nil;
  for (NSNumber* ping_id in pings) {
    ISpdyPing* ping = [pings objectForKey: ping_id];
    [self _delegateDispatch: ^{
      dispatch_source_cancel(ping.timeout);
      ping.timeout = NULL;
      ping.block(kISpdyPingTimedOut, -1.0);
    }];
  }
}


- (void) _writeData: (NSData*) data
                 to: (ISpdyRequest*) request
                fin: (BOOL) fin {
  // Reset timeout
  [request _resetTimeout];

  NSData* pending = data;
  NSInteger pending_length = [pending length];
  NSData* rest = nil;

  // Already closed
  if (request.closed_by_us == YES)
    return;

  NSAssert(request.connection != nil, @"Request was closed");

  if (request.window_out != 0) {
    // Perform flow control
    if (version_ != kISpdyV2) {
      // Only part of the data could be written now
      if (pending_length > request.window_out) {
        // Queue tail
        rest = [pending subdataWithRange: NSMakeRange(
            request.window_out,
            pending_length - request.window_out)];

        // Send head
        pending =
            [pending subdataWithRange: NSMakeRange(0, request.window_out)];

        pending_length = [pending length];
      }
      request.window_out -= pending_length;
    }

    BOOL write_fin = fin || request.pending_closed_by_us;
    [framer_ clear];
    [framer_ dataFrame: request.stream_id
                   fin: rest == nil && write_fin
              withData: pending];
    [scheduler_ schedule: [framer_ output] withPriority: request.priority];

    if (write_fin) {
      NSAssert(request.closed_by_us == NO, @"Already closed!");
      if (rest == nil) {
        request.closed_by_us = YES;
        request.pending_closed_by_us = NO;
      } else {
        request.pending_closed_by_us = YES;
      }
    }
  } else {
    rest = data;
  }

  if (rest != nil)
    [request _queueOutput: rest];
}


- (void) _addHeaders: (NSDictionary*) headers to: (ISpdyRequest*) request {
  // Reset timeout
  [request _resetTimeout];

  [framer_ clear];
  [framer_ headers: request.stream_id withHeaders: headers];
  [self _writeRaw: [framer_ output] withMode: kISpdyWriteChunkBuffering];
}


- (void) _rst: (uint32_t) stream_id code: (uint8_t) code {
  [framer_ clear];
  [framer_ rst: stream_id code: code];
  [self _writeRaw: [framer_ output] withMode: kISpdyWriteChunkBuffering];
}


- (void) _error: (ISpdyRequest*) request code: (ISpdyErrorCode) code {
  // Ignore double-errors
  if (request.connection == nil)
    return;

  [self _rst: request.stream_id code: kISpdyRstCancel];

  ISpdyError* err = [ISpdyError errorWithCode: code];
  [request _close: err sync: NO];
}


- (void) _end: (ISpdyRequest*) request {
  if (request.closed_by_us || request.pending_closed_by_us)
    return;

  if (![request _hasQueuedData]) {
    [framer_ clear];
    [framer_ dataFrame: request.stream_id
                   fin: 1
              withData: nil];
    request.closed_by_us = YES;
    [scheduler_ schedule: [framer_ output] withPriority: request.priority];
    [request _tryClose];
  } else {
    request.pending_closed_by_us = YES;
  }
}


- (void) _removeStream: (ISpdyRequest*) request {
  request.connection = nil;

  if (!request.closed_by_us) {
    [self _rst: request.stream_id code: kISpdyRstCancel];
    request.closed_by_us = YES;
  }

  NSNumber* request_key = [NSNumber numberWithUnsignedInt: request.stream_id];
  if ([streams_ objectForKey: request_key] != nil)
    active_streams_--;
  [streams_ removeObjectForKey: request_key];

  [self _handleDrain];
}


- (void) _handlePing: (NSNumber*) ping_id {
  ISpdyPing* ping = [pings_ objectForKey: ping_id];

  // Ignore non-initiated pings
  if (ping == nil)
    return;

  [pings_ removeObjectForKey: ping_id];
  dispatch_source_cancel(ping.timeout);
  ping.timeout = NULL;

  [self _delegateDispatch: ^{
    ping.block(kISpdyPingOk,
               [[NSDate date] timeIntervalSinceDate: ping.start_date]);
  }];
}


- (void) _handleDrain {
  if (goaway_ && active_streams_ == 0 && [buffer_ length] == 0)
    [self close];
}


- (void) _handleGoaway: (ISpdyGoaway*) goaway {
  ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrGoawayError];

  goaway_ = YES;

  // Destroy all non-pushed streams with ids greater than goaway.stream_id
  for (NSNumber* stream_id in streams_) {
    // Skip push streams
    if ([stream_id integerValue] % 2 == 0)
      continue;
    // Skip handled streams
    if ([stream_id integerValue] > goaway.stream_id)
      continue;

    ISpdyRequest* req = [streams_ objectForKey: stream_id];
    [req _close: err sync: NO];
  }
}


- (void) _handlePush: (ISpdyPush*) push forRequest: (ISpdyRequest*) req {
  NSAssert(push != nil, @"Received nil as PUSH stream");

  push.connection = self;
  push.associated = req;

  push.initial_window_in = initial_window_;
  push.initial_window_out = kInitialWindowSizeIn;
  push.window_in = push.initial_window_in;
  push.window_out = push.initial_window_out;

  // Unidirectional
  push.closed_by_us = YES;

  NSNumber* request_key = [NSNumber numberWithUnsignedInt: push.stream_id];
  [streams_ setObject: push forKey: request_key];
  active_streams_++;

  // Start timer, if needed
  [push _resetTimeout];

  // Enable decompression, if needed
  [push _handleResponseHeaders: push.headers];

  [self _delegateDispatchSync: ^{
    [self.delegate connection: self handlePush: push];
  }];
}


- (BOOL) _checkPinnedCertificates: (NSStream*) stream {
  // Do not perform pinned cert check every time
  if (pinned_check_result_ != kISpdySSLPinningNone)
    return pinned_check_result_ == kISpdySSLPinningApproved;

  // No pinned certs - no check
  if ([pinned_certs_ count] == 0)
    return YES;

  BOOL res = NO;

  NSString* peer_trust = (__bridge NSString*) kCFStreamPropertySSLPeerTrust;
  SecTrustRef trust =
      (__bridge SecTrustRef) [stream propertyForKey: peer_trust];
  NSAssert(trust != NULL, @"Failed to get SSLPeerTrust");

  CFIndex count = SecTrustGetCertificateCount(trust);
  for (CFIndex i = 0; i < count; i++) {
    SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
    NSData* der = (__bridge NSData*) SecCertificateCopyData(cert);

    for (NSData* pinned in pinned_certs_) {
      if ([der isEqualToData: pinned]) {
        res = YES;
        break;
      }
    }

    if (res)
      break;
  }

  pinned_check_result_ = res ? kISpdySSLPinningApproved :
                               kISpdySSLPinningRejected;
  return res;
}

// NSSocket delegate methods

- (void) stream: (NSStream*) stream handleEvent: (NSStreamEvent) event {
  [self _connectionDispatchSync: ^{
    // Already closed, just return
    if (in_stream_ == nil || out_stream_ == nil)
      return;

    // Notify delegate about connection establishment
    if (event == NSStreamEventOpenCompleted && stream == out_stream_) {
      // Set queued option
      if (no_delay_)
        [self setNoDelay: no_delay_];
      if (keep_alive_ != -1)
        [self setKeepAlive: keep_alive_];

      // Notify delegate
      [self _delegateDispatch: ^{
        _state = kISpdyStateConnected;
        [self.delegate handleConnect: self];
      }];
    } else if (event == NSStreamEventHasBytesAvailable ||
               event == NSStreamEventHasSpaceAvailable) {
      // Check pinned certificates
      if (secure_ && ![self _checkPinnedCertificates: stream]) {
        // Failure
        ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrSSLPinningError];
        return [self _handleError: err];
      }
    }

    if (event == NSStreamEventOpenCompleted ||
        event == NSStreamEventErrorOccurred ||
        event == NSStreamEventEndEncountered) {
      [self setTimeout: 0];
    }

    if (event == NSStreamEventErrorOccurred) {
      ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrSocketError
                                       andDetails: [stream streamError]];
      return [self _handleError: err];
    }

    if (event == NSStreamEventEndEncountered) {
      ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrConnectionEnd];
      return [self _handleError: err];
    }

    if (event == NSStreamEventHasSpaceAvailable) {
      // If there're no control frames to send - send data
      if ([buffer_ length] == 0)
        return [scheduler_ unschedule];

      NSAssert(out_stream_ == stream, @"Write event on input stream?!");

      // Socket available for write
      NSInteger r = [out_stream_ write: [buffer_ bytes]
                             maxLength: [buffer_ length]];
      if (r == -1) {
        ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrSocketError
                                         andDetails: [stream streamError]];
        return [self _handleError: err];
      }

      // Shift data
      if (r < (NSInteger) [buffer_ length]) {
        void* bytes = [buffer_ mutableBytes];
        memmove(bytes, bytes + r, [buffer_ length] - r);
      }
      // Truncate
      BOOL drained = r != 0 && [buffer_ length] == (NSUInteger) r;
      [buffer_ setLength: [buffer_ length] - r];
      if (drained)
        [self _handleDrain];
    } else if (event == NSStreamEventHasBytesAvailable) {
      NSAssert(in_stream_ == stream, @"Read event on output stream?!");

      // Socket available for read
      uint8_t buf[kSocketInBufSize];
      NSInteger r = [in_stream_ read: buf maxLength: sizeof(buf)];
      if (r == 0)
        return;
      if (r < 0) {
        ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrSocketError
                                         andDetails: [stream streamError]];
        return [self _handleError: err];
      }

      [parser_ execute: buf length: (NSUInteger) r];
    }
  }];
}

// Parser delegate methods

- (void) handleFrame: (ISpdyFrameType) type
                body: (id) body
              is_fin: (BOOL) is_fin
           forStream: (uint32_t) stream_id {
  ISpdyRequest* req = nil;

  // Update last_frame time
  gettimeofday(&last_frame_, NULL);

  if (type != kISpdyPing &&
      type != kISpdyGoaway &&
      type != kISpdySettings &&
      type != kISpdyNoop &&
      type != kISpdyCredential) {
    req =
        [streams_ objectForKey: [NSNumber numberWithUnsignedInt: stream_id]];

    // If stream isn't found - notify server about it,
    // but don't reply with RST for RST to prevent echoing each other
    // indefinitely.
    if (req == nil && type != kISpdyRstStream) {
      [self _rst: stream_id code: kISpdyRstInvalidStream];
      return;
    }
  }

  // Stream was already ended, this is probably a harmless race condition on
  // server.
  if (req != nil && req.connection == nil)
    return;

  // Reset timeout
  [req _resetTimeout];

  switch (type) {
    case kISpdyData:
      {
        // Perform flow-control
        if (version_ != kISpdyV2) {
          req.window_in -= [body length];

          // Send WINDOW_UPDATE if exhausted
          if (req.window_in <= 0) {
            NSInteger delta = (uint32_t) req.initial_window_in - req.window_in;
            NSAssert(delta >= 0 && delta <= 0x7fffffff,
                     @"delta OOB");
            [framer_ clear];
            [framer_ windowUpdate: stream_id update: (uint32_t) delta];
            [self _writeRaw: [framer_ output]
                   withMode: kISpdyWriteChunkBuffering];
            req.window_in += delta;
          }
        }
        if ([body length] != 0) {
          NSError* err = [req _decompress: body withBlock: ^(NSData* data) {
            if ([data length] == 0)
              return;

            [self _delegateDispatch: ^{
              [req.delegate request: req handleInput: data];
            }];
          }];

          // TODO(indutny): Report actual error as well?
          if (err != nil)
            return [self _error: req code: kISpdyErrDecompressionError];
        }
      }
      break;
    case kISpdyHeaders:
      {
        [self _delegateDispatch: ^{
          [req.delegate request: req handleHeaders: (NSDictionary*) body];
        }];
      }
      break;
    case kISpdySynReply:
      {
        if (req.seen_response)
          return [self _error: req code: kISpdyErrDoubleResponse];
        req.seen_response = YES;
        ISpdyResponse* res = (ISpdyResponse*) body;
        [req _handleResponseHeaders: res.headers];
        [self _delegateDispatch: ^{
          [req.delegate request: req handleResponse: res];
        }];
      }
      break;
    case kISpdySynStream:
      [self _handlePush: body forRequest: req];
      break;
    case kISpdyRstStream:
      {
        ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrRst
                                         andDetails: body];

        // Do not send RST frame in reply to RST
        req.closed_by_us = YES;
        [req _close: err sync: NO];
      }
      break;
    case kISpdyWindowUpdate:
      [req _updateWindow: [body integerValue]];
      break;
    case kISpdySettings:
      {
        ISpdySettings* settings = (ISpdySettings*) body;
        NSInteger delta = settings.initial_window - initial_window_;
        initial_window_ = settings.initial_window;

        // Update all streams' output window
        if (delta != 0) {
          for (NSNumber* stream_id in streams_) {
            // Skip push streams
            if ([stream_id integerValue] % 2 == 0)
              continue;
            ISpdyRequest* req = [streams_ objectForKey: stream_id];
            [req _updateWindow: delta];
          }
        }
      }
      break;
    case kISpdyPing:
      {
        NSInteger ping_id = [body integerValue];

        // Server-initiated ping
        if (ping_id % 2 == 0) {
          // Just reply
          [framer_ clear];
          [framer_ ping: (uint32_t) ping_id];
          [self _writeRaw: [framer_ output]
                 withMode: kISpdyWriteChunkBuffering];

        // Client-initiated ping
        } else {
          [self _handlePing: (NSNumber*) body];
        }
      }
      break;
    case kISpdyGoaway:
      [self _handleGoaway: (ISpdyGoaway*) body];
      break;
    default:
      // Ignore
      break;
  }

  if (is_fin) {
    req.closed_by_them = YES;
    [req _tryClose];
  }

  // Try end request, if its pending
  [req _tryPendingClose];
}


- (void) handleParserError: (NSError*) err {
  return [self _handleError: [ISpdyError errorWithCode: kISpdyErrParseError
                                            andDetails: err]];
}

@end

@implementation ISpdyResponse

// No-op, only to generate properties' accessors

@end

@implementation ISpdyPush

// No-op too

@end

@implementation ISpdyPing

// No-op too

@end

@implementation ISpdyLoopWrap

+ (ISpdyLoopWrap*) stateForLoop: (NSRunLoop*) loop andMode: (NSString*) mode {
  ISpdyLoopWrap* wrap = [ISpdyLoopWrap alloc];
  wrap.loop = loop;
  wrap.mode = mode;
  return wrap;
}

- (BOOL) isEqual: (id) anObject {
  if (![anObject isMemberOfClass: [ISpdyLoopWrap class]])
    return NO;

  ISpdyLoopWrap* wrap = (ISpdyLoopWrap*) anObject;
  return [wrap.loop isEqual: self.loop] &&
         [wrap.mode isEqualToString: self.mode];
}

@end

@implementation ISpdyError

- (ISpdyErrorCode) code {
  return (ISpdyErrorCode) super.code;
}

- (NSString*) description {
  id details = [self.userInfo objectForKey: @"details"];
  switch (self.code) {
    case kISpdyErrConnectionTimeout:
      return @"ISpdy error: connection timed out";
    case kISpdyErrConnectionEnd:
      return @"ISpdy error: connection's socket end";
    case kISpdyErrRequestTimeout:
      return @"ISpdy error: request timed out";
    case kISpdyErrClose:
      return @"ISpdy error: connection was closed on client side";
    case kISpdyErrRst:
      return [NSString stringWithFormat: @"ISpdy error: connection was RSTed "
                                         @"by other side - %@",
          details];
    case kISpdyErrParseError:
      return [NSString stringWithFormat: @"ISpdy error: parser error - %@",
          details];
    case kISpdyErrDoubleResponse:
      return @"ISpdy error: got double SYN_REPLY for a single stream";
    case kISpdyErrSocketError:
      return [NSString stringWithFormat: @"ISpdy error: socket error - %@",
          details];
    case kISpdyErrDecompressionError:
      return @"ISpdy error: failed to decompress incoming data";
    case kISpdyErrSSLPinningError:
      return @"ISpdy error: failed to verify certificate against pinned one";
    case kISpdyErrGoawayError:
      return @"ISpdy error: server asked to go away";
    default:
      return [NSString stringWithFormat: @"Unexpected spdy error %d",
          self.code];
  }
}

@end

@implementation ISpdyError (ISpdyErrorPrivate)

+ (ISpdyError*) errorWithCode: (ISpdyErrorCode) code {
  ISpdyError* r = [ISpdyError alloc];

  return [r initWithDomain: @"ispdy" code: (NSInteger) code userInfo: nil];
}

+ (ISpdyError*) errorWithCode: (ISpdyErrorCode) code andDetails: (id) details {
  ISpdyError* r = [ISpdyError alloc];
  NSDictionary* dict;

  dict = [NSDictionary dictionaryWithObject: details forKey: @"details"];
  return [r initWithDomain: @"ispdy" code: (NSInteger) code userInfo: dict];
}

@end
