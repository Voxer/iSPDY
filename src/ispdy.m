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
#import <stdarg.h>  // va_start, va_end
#import <string.h>  // memmove
#import <sys/socket.h>  // setsockopt
#import <errno.h>  // errno

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
// Make sure DATA chunks fit into single TLS frame
static const NSInteger kSocketMaxWriteSize = 32 * 1024;
static const NSUInteger kSocketMaxBufferSize = 256 * 1024;

typedef enum {
  kISpdySSLPinningNone,
  kISpdySSLPinningRejected,
  kISpdySSLPinningApproved
} ISpdySSLPinningResult;

#ifdef APPSTORE
# define LOG(level, ...) ((void) 0)
#elif DEBUG
# define LOG(level, ...)                                                      \
  [self _log: (level) file: @__FILE__ line: __LINE__ format: __VA_ARGS__]
#else
# define LOG(level, ...)                                                      \
  do {                                                                        \
    if ((level) > kISpdyLogDebug)                                             \
      [self _log: (level) file: @__FILE__ line: __LINE__ format: __VA_ARGS__];\
  } while (0)
#endif

// Implementations

@implementation ISpdy {
  ISpdyVersion version_;
  UInt16 port_;
  BOOL secure_;
  CFReadStreamRef cf_in_stream_;
  CFWriteStreamRef cf_out_stream_;
  NSInputStream* in_stream_;
  NSOutputStream* out_stream_;
  ISpdyCompressor* in_comp_;
  ISpdyCompressor* out_comp_;
  ISpdyFramer* framer_;
  ISpdyParser* parser_;
  ISpdyScheduler* scheduler_;
  BOOL settings_sent_;
  BOOL no_delay_;
  int snd_buf_size_;
  NSInteger max_write_size_;
  struct {
    NSInteger delay;
    NSInteger interval;
    NSInteger count;
  } keep_alive_;
  uint8_t read_buf_[kSocketInBufSize];

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
  NSMutableData* buffer_data_;
  NSMutableArray* buffer_size_;
  NSMutableArray* buffer_callback_;
  NSUInteger buffer_offset_;

  struct timeval jitter_start_;

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

  if (delegate_queue_ == nil) {
    // Initialize dispatch queue
    delegate_queue_ = dispatch_queue_create("com.voxer.ispdy.delegate",
                                            NULL);
    NSAssert(delegate_queue_ != NULL, @"Failed to get main queue");
    connection_queue_ = dispatch_queue_create("com.voxer.ispdy.connection",
                                              NULL);
    NSAssert(connection_queue_ != NULL, @"Failed to get main queue");
  }

  version_ = version;
  port_ = port;
  secure_ = secure;

  in_comp_ = [[ISpdyCompressor alloc] init: version];
  out_comp_ = [[ISpdyCompressor alloc] init: version];
  framer_ = [[ISpdyFramer alloc] init: version compressor: out_comp_];
  parser_ = [[ISpdyParser alloc] init: version compressor: in_comp_];
  scheduler_ = [ISpdyScheduler schedulerWithMaxPriority: kMaxPriority
                                            andDispatch: connection_queue_];
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
  no_delay_ = NO;
  snd_buf_size_ = -1;
  keep_alive_.delay = -1;
  max_write_size_ = kSocketMaxWriteSize;
  initial_window_ = kInitialWindowSizeOut;

  streams_ = [[NSMutableDictionary alloc] initWithCapacity: 100];
  pings_ = [[NSMutableDictionary alloc] initWithCapacity: 10];

  // Create buffer (NOTE: might be resized if needed)
  buffer_data_ = [NSMutableData dataWithCapacity: kSocketMaxBufferSize * 2];
  buffer_size_ = [NSMutableArray arrayWithCapacity: 100];
  buffer_callback_ = [NSMutableArray arrayWithCapacity: 100];
  buffer_offset_ = 0;

  // Initialize pinned certs
  if (pinned_certs_ == nil)
    pinned_certs_ = [NSMutableSet setWithCapacity: 1];

  // Initialize storage for loops
  if (scheduled_loops_ == nil)
    scheduled_loops_ = [NSMutableSet setWithCapacity: 1];

  CFStreamCreatePairWithSocketToHost(
      NULL,
      (__bridge CFStringRef) host,
      port,
      &cf_in_stream_,
      &cf_out_stream_);

  in_stream_ = (__bridge NSInputStream*) cf_in_stream_;
  out_stream_ = (__bridge NSOutputStream*) cf_out_stream_;

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
  // Ensure that socket will be removed from the loop and we won't
  // get any further events on it
  [self close];

  delegate_queue_ = NULL;
  connection_queue_ = NULL;

  in_stream_ = nil;
  out_stream_ = nil;
  CFRelease(cf_in_stream_);
  CFRelease(cf_out_stream_);
}


- (void) scheduleInRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode {
  [self _connectionDispatch: ^{
    [self _scheduleInRunLoop: loop forMode: mode];
  }];
}


- (void) removeFromRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode {
  [self _connectionDispatch: ^{
    [self _removeFromRunLoop: loop forMode: mode];
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
    [self _setNoDelay: enable];
  }];
}


- (void) setSendBufferSize: (int) size {
  [self _connectionDispatch: ^{
    [self _setSendBufferSize: size];
  }];
}


- (void) setMaxWriteSize: (NSInteger) size {
  [self _connectionDispatch: ^{
    [self _setMaxWriteSize: size];
  }];
}


- (void) setKeepAliveDelay: (NSInteger) delay
                  interval: (NSInteger) interval
                  andCount: (NSInteger) count {
  [self _connectionDispatch: ^{
   [self _setKeepAliveDelay: delay interval: interval andCount: count];
  }];
}


- (void) setVoip: (BOOL) enable {
  [self _connectionDispatch: ^{
    const NSString* type = enable ? NSStreamNetworkServiceTypeVoIP : nil;
    [in_stream_ setProperty: type
                     forKey: NSStreamNetworkServiceType];
    [out_stream_ setProperty: type
                      forKey: NSStreamNetworkServiceType];
  }];
}


- (ISpdyCheckStatus) checkSocket {
  __block ISpdyCheckStatus res;
  [self _connectionDispatchSync: ^{
    NSStreamStatus status = [out_stream_ streamStatus];

    // If stream is not open yet, queue setting option
    if (status != NSStreamStatusOpen && status != NSStreamStatusWriting) {
      res = kISpdyCheckNotConnected;
      return;
    }

    __block int r;
    __block int err = 0;
    [self _fdWithBlock: ^(CFSocketNativeHandle fd) {
      if (fd == -1) {
        r = 0;
        return;
      }

      socklen_t len = sizeof(err);
      r = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
      NSAssert(r != 0 || len == sizeof(err), @"Unexpected getsocktopt result");
    }];

    if (err == 0 && r == 0) {
      res = kISpdyCheckGood;
      return;
    }

    NSNumber* nerr = [NSNumber numberWithUnsignedInt: err];
    [self _close: [ISpdyError errorWithCode: kISpdyErrCheckSocketError
                                 andDetails: nerr]];
    res = kISpdyCheckBad;
  }];
  return res;
}


- (BOOL) connect {
  // Disallow reconnects
  if (_state == kISpdyStateClosed)
    return NO;

  // Reinitialize streams if connection was closed
  if (in_stream_ == nil) {
    NSAssert(out_stream_ == nil, @"Both streams should be closed");

    (void) [self init: version_
                 host: _host
             hostname: _hostname
                 port: port_
               secure: secure_];
  }

  [self _connectionDispatchSync: ^{
    [self _lazySchedule];
  }];

  _state = kISpdyStateConnecting;
  [in_stream_ open];
  [out_stream_ open];

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
    [self _close: nil];
  }];

  return YES;
}


- (void) closeSoon: (NSTimeInterval) timeout {
  self.goaway_retain_ = self;
  [self _connectionDispatch: ^{
    NSAssert(!goaway_, @"closeSoon called twice");

    if (timeout != 0.0) {
      __weak ISpdy* weakSelf = self;
      goaway_timeout_ = [self _timerWithTimeInterval: timeout block: ^{
        // Force close connection
        [weakSelf _close: nil];
      } andSource: goaway_timeout_];
    }
    goaway_ = YES;

    [framer_ clear];
    [framer_ goaway: stream_id_ - 2 status: kISpdyGoawayOk];
    [scheduler_ schedule: [framer_ output]
             forPriority: 0
               andStream: 0
            withCallback: nil];

    // Close connection if needed
    [self _handleDrain];
  }];
}


- (void) send: (ISpdyRequest*) request {
  if (request == nil) {
    LOG(kISpdyLogWarning, @"Trying to send request nil request", request);
    return;
  }

  [self _connectionDispatch: ^{
    if (_state == kISpdyStateClosed) {
      LOG(kISpdyLogWarning, @"Trying to send request after close", request);
      [self _error: request code: kISpdyErrSendAfterClose];
      return;
    }
    if (goaway_) {
      [self _error: request code: kISpdyErrSendAfterGoawayError];
      return;
    }

    // Try to fit accumulated data and request frame into a single socket buffer
    LOG(kISpdyLogDebug, @"cork");
    [scheduler_ cork];

    // Send initial window
    if (version_ != kISpdyV2 && !settings_sent_) {
      settings_sent_ = YES;
      [framer_ clear];
      [framer_ initialWindow: kInitialWindowSizeIn];
      [scheduler_ schedule: [framer_ output]
               forPriority: 0
                 andStream: 0
              withCallback: nil];
    }

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
    [scheduler_ schedule: [framer_ output]
             forPriority: 0
               andStream: 0
            withCallback: nil];

    // Start timer, if needed
    [request _resetTimeout];

    [request _connectionDispatch: ^{
      LOG(kISpdyLogDebug, @"uncork");
      [scheduler_ uncork];
    }];

    [request _uncork];
  }];
}


- (void) ping: (ISpdyPingCallback) block waitMax: (NSTimeInterval) wait {
  [self _connectionDispatch: ^{
    ISpdyPing* ping = [ISpdyPing alloc];

    ping.ping_id = [NSNumber numberWithUnsignedInt: ping_id_];
    ping_id_ += 2;
    ping.block = block;
    __weak ISpdy* weakSelf = self;
    ping.timeout = [self _timerWithTimeInterval: wait block: ^{
      [pings_ removeObjectForKey: ping.ping_id];

      [weakSelf _delegateDispatch: ^{
        [ping _invoke: kISpdyPingTimedOut rtt: -1.0];
      }];
    } andSource: ping.timeout];
    ping.start_date = [NSDate date];

    // Connection closed - invoke ping's block
    if (_state == kISpdyStateClosed) {
      [self _delegateDispatch: ^{
        [ping _invoke: kISpdyPingConnectionEnd rtt: -1.0];
      }];
      return;
    }

    [pings_ setObject: ping forKey: ping.ping_id];

    [framer_ clear];
    [framer_ ping: (uint32_t) [ping.ping_id integerValue]];
    [scheduler_ schedule: [framer_ output]
             forPriority: 0
               andStream: 0
            withCallback: nil];
  }];
}


- (void) setTimeout: (NSTimeInterval) timeout {
  [self _connectionDispatch: ^() {
    [self _setTimeout: timeout];
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


- (void) _log: (ISpdyLogLevel) level
         file: (NSString*) file
         line: (NSInteger) line
       format: (NSString*) format, ... {
  if (self.delegate == nil)
    return;

#ifdef NDEBUG
  // No debug logging in release builds
  if (level == kISpdyLogDebug)
    return;
#endif

  NSObject* d = (NSObject*) self.delegate;
  if (![d respondsToSelector: @selector(logSpdyEvents:level:message:)])
    return;

  NSString* lnfmt =
      [NSString stringWithFormat: @"%@:%ld %@", file, (long) line, format];

  va_list args;
  va_start(args, format);
  NSString* str = [[NSString alloc] initWithFormat: lnfmt arguments: args];
  va_end(args);

  [self _delegateDispatch: ^{
    [self.delegate logSpdyEvents: self level: level message: str];
  }];
}


- (void) _fdWithBlock: (void(^)(CFSocketNativeHandle)) block {
  CFDataRef data =
      CFWriteStreamCopyProperty((__bridge CFWriteStreamRef) out_stream_,
                                kCFStreamPropertySocketNativeHandle);
  if (data == NULL)
    return block(-1);

  CFSocketNativeHandle handle;
  CFDataGetBytes(data, CFRangeMake(0, sizeof(handle)), (UInt8*) &handle);

  block(handle);

  CFRelease(data);
}


- (void) _lazySchedule {
  if ([scheduled_loops_ count] == 0) {
    on_ispdy_loop_ = YES;
    [self _scheduleInRunLoop: [ISpdyLoop defaultLoop]
                     forMode: NSDefaultRunLoopMode];
  }
}


- (dispatch_source_t) _timerWithTimeInterval: (NSTimeInterval) interval
                                       block: (void (^)()) block
                                   andSource: (dispatch_source_t) source {
  return [ISpdyCommon timerWithTimeInterval: interval
                                      queue: connection_queue_
                                      block: block
                                  andSource: source];
}


- (void) _setTimeout: (NSTimeInterval) timeout {
  if (connection_timeout_ != NULL)
    dispatch_source_cancel(connection_timeout_);
  if (timeout == 0.0)
    return;

  __weak ISpdy* weakSelf = self;
  connection_timeout_ = [self _timerWithTimeInterval: timeout block: ^{
    [weakSelf _close:
        [ISpdyError errorWithCode: kISpdyErrConnectionTimeout]];
  } andSource: connection_timeout_];
}


static void ispdy_source_cb(void* arg) {
  ISpdy* ispdy = (__bridge ISpdy*) arg;

#ifndef NDEBUG
  [ispdy _measureJitterEnd];
#endif
  [ispdy _doSocketWrite];
}


static void ispdy_remove_source_cb(void* arg) {
  ISpdyLoopWrap* wrap = (__bridge ISpdyLoopWrap*) arg;

  CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                        wrap.source,
                        kCFRunLoopDefaultMode);
  CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                        wrap.remove_source,
                        kCFRunLoopDefaultMode);

  CFRunLoopSourceContext ctx;
  memset(&ctx, 0, sizeof(ctx));
  CFRunLoopSourceGetContext(wrap.source, &ctx);
  CFRelease(ctx.info);
  ctx.info = NULL;

  CFRunLoopSourceGetContext(wrap.remove_source, &ctx);
  CFRelease(ctx.info);
  ctx.info = NULL;

  CFRelease(wrap.source);
  CFRelease(wrap.remove_source);
  wrap.source = NULL;
  wrap.remove_source = NULL;
}


- (void) _scheduleInRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode {
  ISpdyLoopWrap* wrap = [ISpdyLoopWrap stateForLoop: loop andMode: mode];

  CFRunLoopSourceContext ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.info = (void*) CFBridgingRetain(self);
  ctx.perform = ispdy_source_cb;
  wrap.source = CFRunLoopSourceCreate(NULL, 0, &ctx);

  ctx.info = (void*) CFBridgingRetain(wrap);
  ctx.perform = ispdy_remove_source_cb;
  wrap.remove_source = CFRunLoopSourceCreate(NULL, 0, &ctx);

  CFRunLoopAddSource([loop getCFRunLoop], wrap.source, kCFRunLoopDefaultMode);
  CFRunLoopAddSource([loop getCFRunLoop],
                     wrap.remove_source,
                     kCFRunLoopDefaultMode);

  [scheduled_loops_ addObject: wrap];

  [in_stream_ scheduleInRunLoop: wrap.loop forMode: wrap.mode];
  [out_stream_ scheduleInRunLoop: wrap.loop forMode: wrap.mode];
}


- (void) _removeFromRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode {
  ISpdyLoopWrap* needle = [ISpdyLoopWrap stateForLoop: loop andMode: mode];
  ISpdyLoopWrap* wrap = [scheduled_loops_ member: needle];
  [scheduled_loops_ removeObject: needle];

  CFRunLoopSourceSignal(wrap.remove_source);
  CFRunLoopWakeUp([wrap.loop getCFRunLoop]);

  [in_stream_ removeFromRunLoop: wrap.loop forMode: wrap.mode];
  [out_stream_ removeFromRunLoop: wrap.loop forMode: wrap.mode];
}


- (void) _setNoDelay: (BOOL) enable {
  NSStreamStatus status = [out_stream_ streamStatus];

  // If stream is not open yet, queue setting option
  if (status != NSStreamStatusOpen && status != NSStreamStatusWriting) {
    no_delay_ = enable;
    return;
  }

  __block int r;
  [self _fdWithBlock: ^(CFSocketNativeHandle fd) {
    int ienable = enable;
    if (fd == -1)
      r = 0;
    else
      r = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &ienable, sizeof(ienable));
  }];
  NSAssert(r == 0 || errno == EINVAL, @"Set NODELAY failed");
}


- (void) _setSendBufferSize: (int) size {
  NSStreamStatus status = [out_stream_ streamStatus];

  // If stream is not open yet, queue setting option
  if (status != NSStreamStatusOpen && status != NSStreamStatusWriting) {
    snd_buf_size_ = size;
    return;
  }

  __block int r;
  [self _fdWithBlock: ^(CFSocketNativeHandle fd) {
    if (fd == -1)
      r = 0;
    else
      r = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
  }];
  //NSAssert(r == 0 || errno == EINVAL, @"Set SO_SNDBUF failed");
}


- (void) _setMaxWriteSize: (NSInteger) size {
  max_write_size_ = size;
}


- (void) _setKeepAliveDelay: (NSInteger) delay
                   interval: (NSInteger) interval
                   andCount: (NSInteger) count {
  NSStreamStatus status = [out_stream_ streamStatus];

  // If stream is not open yet, queue setting option
  if (status != NSStreamStatusOpen && status != NSStreamStatusWriting) {
    keep_alive_.delay = delay;
    keep_alive_.interval = interval;
    keep_alive_.count = count;
    return;
  }

  __block int r;
  [self _fdWithBlock: ^(CFSocketNativeHandle fd) {
    int enable = delay != 0;
    int ikeepalive = (int) delay;
    int iinterval = (int) interval;
    int icount = (int) count;

    if (fd == -1) {
      r = 0;
      return;
    }

    r = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &enable, sizeof(enable));
    if (r == 0 && enable) {
      r = setsockopt(fd,
                     IPPROTO_TCP,
                     TCP_KEEPALIVE,
                     &ikeepalive,
                     sizeof(ikeepalive));
      if (r == 0) {
        r = setsockopt(fd,
                       IPPROTO_TCP,
                       TCP_KEEPINTVL,
                       &iinterval,
                       sizeof(iinterval));
      }
      if (r == 0) {
        r = setsockopt(fd,
                       IPPROTO_TCP,
                       TCP_KEEPCNT,
                       &icount,
                       sizeof(icount));
      }
    }
  }];
  NSAssert(r == 0 || errno == EINVAL, @"Set KEEPALIVE failed");
}


- (BOOL) _close: (ISpdyError*) err {
  if (in_stream_ == nil || out_stream_ == nil)
    return NO;

  if (goaway_timeout_ != NULL)
    dispatch_source_cancel(goaway_timeout_);
  if (connection_timeout_ != NULL)
    dispatch_source_cancel(connection_timeout_);
  goaway_timeout_ = NULL;
  connection_timeout_ = NULL;
  self.goaway_retain_ = nil;

  _state = kISpdyStateClosed;

  if (on_ispdy_loop_) {
    on_ispdy_loop_ = NO;
    [self _removeFromRunLoop: [ISpdyLoop defaultLoop]
                     forMode: NSDefaultRunLoopMode];
  }

  [in_stream_ close];
  [out_stream_ close];
  in_stream_ = nil;
  out_stream_ = nil;

  if (err == nil) {
    err = [ISpdyError errorWithCode: kISpdyErrClose];
  } else {
    [self _delegateDispatch: ^{
      [self.delegate connection: self handleError: err];
    }];
  }

  // Fire stream errors
  [self _closeStreams: err];
  [self _destroyPings: err];

  return YES;
}


- (BOOL) scheduledWrite: (NSData*) data
           withCallback: (ISpdySchedulerCallback) cb {
  if (buffer_offset_ > kSocketMaxBufferSize) {
    LOG(kISpdyLogDebug, @"Can\'t schedule write, buffer is full");
    return NO;
  }

  if (buffer_offset_ + [data length] > [buffer_data_ length])
    [buffer_data_ increaseLengthBy: kSocketMaxBufferSize];

  void* bytes = [buffer_data_ mutableBytes];
  memcpy(bytes + buffer_offset_, [data bytes], [data length]);
  buffer_offset_ += [data length];

  NSNumber* size = [NSNumber numberWithUnsignedInteger: [data length]];
  [buffer_size_ addObject: size];
  [buffer_callback_ addObject: cb];

  LOG(kISpdyLogDebug,
      @"Scheduled write size=%d total buffered=%d",
      [data length],
      buffer_offset_);

  return YES;
}


- (void) scheduledEnd {
  LOG(kISpdyLogDebug, @"End of scheduled data");
  [self _scheduleSocketWrite];
}


- (void) _scheduleSocketWrite {
#ifndef NDEBUG
  [self _measureJitter];
#endif
  for (ISpdyLoopWrap* wrap in scheduled_loops_) {
    CFRunLoopSourceSignal(wrap.source);
    CFRunLoopWakeUp([wrap.loop getCFRunLoop]);
  }
}


- (void) _doSocketWrite {
  NSStreamStatus status = [out_stream_ streamStatus];

  if (status == NSStreamStatusNotOpen) {
    ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrConnectionEnd];
    [self _connectionDispatch: ^{
      [self _close: err];
    }];
    return;
  }

  // If stream is not open yet, or if there's already queued data -
  // queue more.
  if ((status != NSStreamStatusOpen && status != NSStreamStatusWriting) ||
      ![out_stream_ hasSpaceAvailable]) {
    return;
  }

  // Socket available for write
  __block NSInteger r;
  [self _connectionDispatchSync: ^{
    LOG(kISpdyLogDebug, @"Socket send buffer=%d", buffer_offset_);
    if (buffer_offset_ == 0)
      r = 0;
    else
      r = [out_stream_ write: [buffer_data_ bytes] maxLength: buffer_offset_];
  }];

  LOG(kISpdyLogDebug, @"Socket sent size=%d", r);
  if (r == -1) {
    ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrSocketError
                                     andDetails: [out_stream_ streamError]];
    [self _connectionDispatch: ^{
      [self _close: err];
    }];
    return;
  }

  [self _connectionDispatch: ^{
    NSAssert(buffer_offset_ >= (NSUInteger) r, @"Socket buffer overflow");
    buffer_offset_ -= r;

    // Incomplete write
    if (r != 0 && buffer_offset_ > 0) {
      void* bytes = [buffer_data_ mutableBytes];
      memmove(bytes, bytes + r, buffer_offset_);
    }

    // Notify callers
    while (r > 0) {
      NSUInteger size = [[buffer_size_ objectAtIndex: 0] unsignedIntegerValue];

      // Partial write
      if (size > r) {
        [buffer_size_ replaceObjectAtIndex: 0
                   withObject: [NSNumber numberWithUnsignedInt: size - r]];
        r = 0;
        break;
      }

      r -= size;
      [buffer_size_ removeObjectAtIndex: 0];
      ISpdySchedulerCallback cb = [buffer_callback_ objectAtIndex: 0];
      [buffer_callback_ removeObjectAtIndex: 0];
      [self _connectionDispatch: cb];
    }

    if (buffer_offset_ == 0)
      [self _handleDrain];
  }];
}


- (void) _measureJitter {
  if (jitter_start_.tv_sec != 0)
    return;
  gettimeofday(&jitter_start_, NULL);
}


- (void) _measureJitterEnd {
  struct timeval jitter_start;
  struct timeval jitter_end;
  gettimeofday(&jitter_end, NULL);
  jitter_start = jitter_start_;
  memset(&jitter_start_, 0, sizeof(jitter_start_));

  float delta = (float) (jitter_end.tv_sec - jitter_start.tv_sec) * 1e3 +
                (float) (jitter_end.tv_usec - jitter_start.tv_usec) * 1e-3;
  LOG(kISpdyLogDebug, @"socket write schedule jitter=%fms", delta);
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
      [ping _invoke: kISpdyPingConnectionEnd rtt: -1.0];
    }];
  }
}


- (void) _writeData: (NSData*) data
            withFin: (BOOL) fin
                 to: (ISpdyRequest*) request {
  // Already closed
  if (request.closed_by_us == YES)
    return;

  NSAssert(request.connection != nil, @"Request was closed");

  LOG(kISpdyLogDebug,
      @"request=\"%@\" sending DATA size=%d fin=%d",
      request.url,
      [data length],
      fin);

  [framer_ clear];
  [framer_ dataFrame: request.stream_id
                 fin: fin
            withData: data];
  [scheduler_ schedule: [framer_ output]
           forPriority: request.priority
             andStream: request.stream_id
          withCallback: ^() {
    LOG(kISpdyLogDebug,
        @"request=\"%@\" DATA sent size=%d",
        request.url,
        [data length]);

    if (!fin)
      return;

    // Last DATA frame
    request.closed_by_us = YES;
    [request _maybeClose];
  }];
}


- (void) _splitOutput: (NSData*) output
              withFin: (BOOL) fin
             andBlock: (void (^)(NSData* data, BOOL fin)) block {
  for (NSUInteger off = 0; off < [output length]; off += max_write_size_) {
    NSUInteger avail = [output length] - off;
    BOOL is_last = avail <= (NSUInteger) max_write_size_;

    if (!is_last)
      avail = max_write_size_;

    NSData* slice = [output subdataWithRange: NSMakeRange(off, avail)];
    block(slice, is_last && fin);
  }
}


- (void) _addHeaders: (NSDictionary*) headers to: (ISpdyRequest*) request {
  // Reset timeout
  [request _resetTimeout];

  [framer_ clear];
  [framer_ headers: request.stream_id withHeaders: headers];
  [scheduler_ schedule: [framer_ output]
           forPriority: 0
             andStream: 0
          withCallback: nil];
}


- (void) _rst: (uint32_t) stream_id code: (uint8_t) code {
  [framer_ clear];
  [framer_ rst: stream_id code: code];
  [scheduler_ schedule: [framer_ output]
           forPriority: 0
             andStream: 0
          withCallback: nil];
}


- (void) _error: (ISpdyRequest*) request code: (ISpdyErrorCode) code {
  // Ignore double-errors
  if (request.connection == nil)
    return;

  [self _rst: request.stream_id code: kISpdyRstCancel];

  ISpdyError* err = [ISpdyError errorWithCode: code];
  [request _close: err sync: NO];
}


- (void) _removeStream: (ISpdyRequest*) request {
  [request _setConnection: nil];

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
    [ping _invoke: kISpdyPingOk
              rtt: [[NSDate date] timeIntervalSinceDate: ping.start_date]];
  }];
}


- (void) _handleDrain {
  if (goaway_ && active_streams_ == 0 && buffer_size_ == 0)
    [self _close: nil];
  else
    [scheduler_ resume];
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

  push.associated = req;

  push.initial_window_in = initial_window_;
  push.initial_window_out = kInitialWindowSizeIn;
  push.window_in = push.initial_window_in;
  push.window_out = push.initial_window_out;

  // Unidirectional
  push.closed_by_us = YES;
  [push _setConnection: self];
  [push _uncork];

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
    NSData* der = (__bridge_transfer NSData*) SecCertificateCopyData(cert);

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
  NSString* stream_kind = stream == in_stream_ ? @"in" : @"out";
  if (event == NSStreamEventOpenCompleted) {
    LOG(kISpdyLogInfo, @"NSStream<%@> open", stream_kind);
  } else if (event == NSStreamEventEndEncountered) {
    LOG(kISpdyLogInfo, @"NSStream<%@> end", stream_kind);
  } else if (event == NSStreamEventErrorOccurred) {
    LOG(kISpdyLogInfo, @"NSStream<%@> error", stream_kind);
  }

  // Already closed, just return
  if (in_stream_ == nil || out_stream_ == nil)
    return;

  ISpdyError* err = nil;

  // Notify delegate about connection establishment
  if (event == NSStreamEventOpenCompleted && stream == out_stream_) {
    [self _connectionDispatch: ^{
      // Set queued option
      if (no_delay_)
        [self _setNoDelay: no_delay_];
      if (snd_buf_size_ != -1)
        [self _setSendBufferSize: snd_buf_size_];
      if (keep_alive_.delay != -1) {
        [self _setKeepAliveDelay: keep_alive_.delay
                        interval: keep_alive_.interval
                        andCount: keep_alive_.count];
      }

      _state = kISpdyStateConnected;
    }];

    // Notify delegate
    [self _delegateDispatch: ^{
      [self.delegate handleConnect: self];
    }];
  } else if (event == NSStreamEventHasBytesAvailable ||
             event == NSStreamEventHasSpaceAvailable) {
    // Check pinned certificates
    if (secure_ && ![self _checkPinnedCertificates: stream]) {
      // Failure
      err = [ISpdyError errorWithCode: kISpdyErrSSLPinningError];
    }
  }

  if (event == NSStreamEventOpenCompleted ||
      event == NSStreamEventErrorOccurred ||
      event == NSStreamEventEndEncountered) {
    [self _connectionDispatch: ^{
      [self _setTimeout: 0];
    }];
  }

  if (event == NSStreamEventErrorOccurred) {
    err = [ISpdyError errorWithCode: kISpdyErrSocketError
                         andDetails: [stream streamError]];
  }

  if (event == NSStreamEventEndEncountered)
    err = [ISpdyError errorWithCode: kISpdyErrConnectionEnd];

  if (err != nil) {
    [self _connectionDispatch: ^{
      [self _close: err];
    }];
    return;
  }

  if (event == NSStreamEventHasSpaceAvailable) {
    NSAssert(out_stream_ == stream, @"Write event on input stream?!");

    [self _doSocketWrite];
  } else if (event == NSStreamEventHasBytesAvailable) {
    NSAssert(in_stream_ == stream, @"Read event on output stream?!");

    // Socket available for read
    __block NSInteger r;
    [self _connectionDispatchSync: ^{
      r = [in_stream_ read: read_buf_ maxLength: sizeof(read_buf_)];
    }];

    if (r == 0)
      return;
    if (r < 0) {
      ISpdyError* err = [ISpdyError errorWithCode: kISpdyErrSocketError
                                       andDetails: [stream streamError]];
      [self _connectionDispatch: ^{
        [self _close: err];
      }];
      return;
    }

    [self _connectionDispatch: ^{
      [parser_ execute: read_buf_ length: (NSUInteger) r];
    }];
  }
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
          if (req.window_in <= (req.initial_window_in / 2)) {
            NSInteger delta = (uint32_t) req.initial_window_in - req.window_in;
            NSAssert(delta >= 0 && delta <= 0x7fffffff,
                     @"delta OOB");
            [framer_ clear];
            [framer_ windowUpdate: stream_id update: (uint32_t) delta];
            [scheduler_ schedule: [framer_ output]
                     forPriority: 0
                       andStream: 0
                    withCallback: nil];
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
      [req _updateWindow: [body integerValue] withBlock: nil];
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
            [req _updateWindow: delta withBlock: nil];
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
          [scheduler_ schedule: [framer_ output]
                   forPriority: 0
                     andStream: 0
                  withCallback: nil];

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
    [req _maybeClose];
  }
}


- (void) handleParserError: (NSError*) err {
  [self _close: [ISpdyError errorWithCode: kISpdyErrParseError
                               andDetails: err]];
}

@end

@implementation ISpdyResponse

// No-op, only to generate properties' accessors

@end

@implementation ISpdyPush

// No-op too

@end

#undef LOG
