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

#import <sys/time.h>  // struct timeval
#import <Foundation/Foundation.h>

// Forward-declarations
@class ISpdy;
@class ISpdyCompressor;
@class ISpdyFramer;
@class ISpdyParser;
@class ISpdyRequest;

/**
 * SPDY Protocol version
 */
typedef enum {
  kISpdyV2,
  kISpdyV3
} ISpdyVersion;

/**
 * Possible error codes in NSError with domain @"spdy"
 */
typedef enum {
  kISpdyErrConnectionTimeout,
  kISpdyErrConnectionEnd,
  kISpdyErrRequestTimeout,
  kISpdyErrClose,
  kISpdyErrRst,
  kISpdyErrParseError,
  kISpdyErrDoubleResponse,
  kISpdyErrCheckSocketError,
  kISpdyErrSocketError,
  kISpdyErrDecompressionError,
  kISpdyErrSSLPinningError,
  kISpdyErrGoawayError,
  kISpdyErrSendAfterGoawayError,
  kISpdyErrSendAfterClose
} ISpdyErrorCode;

/**
 * Possible connection states
 */
typedef enum {
  kISpdyStateInitial,
  kISpdyStateConnecting,
  kISpdyStateConnected,
  kISpdyStateClosed
} ISpdyState;

/**
 * Ping status results
 */
typedef enum {
  kISpdyPingOk,
  kISpdyPingTimedOut,
  kISpdyPingConnectionEnd
} ISpdyPingStatus;

/**
 * checkSocket results
 */
typedef enum {
  kISpdyCheckNotConnected,
  kISpdyCheckGood,
  kISpdyCheckBad
} ISpdyCheckStatus;

/**
 * Log levels
 */
typedef enum {
  kISpdyLogInfo,
  kISpdyLogWarning,
  kISpdyLogError
} ISpdyLogLevel;

/**
 * Callback for ping method.
 */
typedef void (^ISpdyPingCallback)(ISpdyPingStatus status, NSTimeInterval rtt);

@interface ISpdyError : NSError

- (ISpdyErrorCode) code;
- (NSString*) description;

/**
 * NOTE: when `code` is either `kISpdyErrSocketError` or `kISpdyErrParseError`,
 * `err.userInfo` will contain `@"details"` key with a `NSError*` value,
 * referring to original error, reported by either Socket or Parser respectively
 *
 * When `code` is `kISpdyErrRst`, details will contain `NSNumber*` of RST code.
 */

@end

/**
 * Response class
 */
@interface ISpdyResponse : NSObject

@property (nonatomic) NSInteger code;
@property (nonatomic) NSString* status;
@property (nonatomic) NSDictionary* headers;

@end

/**
 * Delegate for handling request-level events
 */
@protocol ISpdyRequestDelegate
- (void) request: (ISpdyRequest*) req handleResponse: (ISpdyResponse*) res;
- (void) request: (ISpdyRequest*) req handleInput: (NSData*) input;
- (void) request: (ISpdyRequest*) req handleHeaders: (NSDictionary*) headers;
- (void) request: (ISpdyRequest*) req handleEnd: (ISpdyError*) err;
@end

/**
 * Request class.
 *
 * Should be used to initiate new request to the server, works only with
 * existing ISpdy connection.
 */
@interface ISpdyRequest : NSObject

/**
 * Reference to user-provided delegate.
 * Should be provided in order to receive input/end/error events.
 */
@property id <ISpdyRequestDelegate> delegate;

/**
 * Request method, should be initialized using `init: url:` selector.
 */
@property (nonatomic) NSString* method;

/**
 * Request url, should be initialized using `init: url:` selector.
 */
@property (nonatomic) NSString* url;

/**
 * HTTP Headers
 */
@property (nonatomic) NSDictionary* headers;

/**
 * Stream priority (highest: 0, lowest: 7)
 */
@property (nonatomic) NSUInteger priority;

/**
 * Just a property to store user-defined reference, not used internally.
 */
@property (strong) id opaque;

/**
 * Initialize properties.
 *
 * @param method  HTTP method to use when sending request
 * @param url     Request url `@"/some/relative/url"`
 *
 * @return Initialized instance of ISpdyRequest
 */

- (id) init: (NSString*) method url: (NSString*) url;

/**
 * Write raw data to the underlying stream.
 *
 * NOTE: The best option would be to call this after doing `[conn send: req];`,
 * otherwise all data will be buffered until it.
 *
 * @param data  Data to send
 */
- (void) writeData: (NSData*) data;

/**
 * Write string to the underlying stream. Same as `writeData:`.
 *
 * @param data  String to send
 */
- (void) writeString: (NSString*) data;

/**
 * Gracefully end stream/request.
 *
 * NOTE: Could be called before `[conn send: req]`, but again it'll be buffered
 * until actual send.
 */
- (void) end;

/**
 * Send data and gracefully end stream/request.
 *
 * @param data  Data to end with
 */
- (void) endWithData: (NSData*) data;

/**
 * Send data and gracefully end stream/request.
 *
 * @param data  Data to end with
 */
- (void) endWithString: (NSString*) data;

/**
 * Add trailing headers.
 *
 * @param headers  Trailing headers to sent
 */
- (void) addHeaders: (NSDictionary*) headers;

/**
 * Shutdown stream (CANCEL error code will be used).
 *
 * NOTE: Can't be called before `[conn send: req]`
 */
- (void) close;

/**
 * Set response timeout (default value: 1 minute)
 *
 * @param timeout  if non-zero - how much to wait until throwing an error and
 *                               closing stream
 *                 if zero - reset timeout
 */
- (void) setTimeout: (NSTimeInterval) timeout;

@end

/**
 * Server PUSH class
 */

@interface ISpdyPush : ISpdyRequest

@property (nonatomic) ISpdyRequest* associated;
@property (nonatomic) NSString* method;
@property (nonatomic) NSString* url;
@property (nonatomic) NSString* scheme;
@property (nonatomic) NSString* version;
@property (nonatomic) NSDictionary* headers;

@end

/**
 * Delegate for handling connection-level events
 */
@protocol ISpdyDelegate

/**
 * Invoked on TCP connection establishment.
 *
 * @param conn  ISpdy connection on which the error has happened
 */
- (void) handleConnect: (ISpdy*) conn;

/**
 * Invoked on incoming PUSH stream.
 * NOTE: This stream is read-only and any write will cause assertion failure.
 * Also, this method is invoked synchronously so please try to keep out of
 * blocking here, as it blocks ispdy's thread.
 *
 * @param conn  ISpdy connection on which the error has happened
 * @param push  PUSH request
 */
- (void) connection: (ISpdy*) conn handlePush: (ISpdyPush*) push;

/**
 * Invoked on global, connection-level error.
 *
 * @param conn  ISpdy connection on which the error has happened
 * @param err   The error itself
 */
- (void) connection: (ISpdy*) conn handleError: (ISpdyError*) err;

@end

/**
 * Delegate for handling connection-level log events
 */
@protocol ISpdyLogDelegate

- (void) logSpdyEvents: (ISpdy*) conn
                 level: (ISpdyLogLevel) level
               message: (NSString*) message;

@end

/** ISpdy connection class
 *
 * Connects to server and holds underlying socket, parsing incoming data and
 * generating outgoing protocol data. Should be instantiated in order to
 * send requests to the server.
 */
@interface ISpdy : NSObject

/**
 * Connection-level delegate, should be provided to handle global errors.
 */
@property (weak) id <ISpdyDelegate, ISpdyLogDelegate> delegate;

/**
 * Host passed to `init:host:port:secure:`
 */
@property (nonatomic, readonly) NSString* host;

/**
 * Hostname passed to `init:host:port:secure:`
 */
@property (nonatomic, readonly) NSString* hostname;

/**
 * Time of the last received frame
 */
@property (readonly) struct timeval* last_frame;

/**
 * State of connection
 */
@property (readonly) ISpdyState state;

/**
 * Initialize connection to work with specified protocol version.
 *
 * @param version  SPDY protocol version, recommended value `ISpdyV3`
 * @param host     Remote host
 * @param port     Remote port
 * @param secure   `YES` if connecting to TLS server
 */
- (id) init: (ISpdyVersion) version
       host: (NSString*) host
       port: (UInt16) port
     secure: (BOOL) secure;

/**
 * Extended version of init, with `hostname` argument added.
 * Use it if you need to specify for SSL certificate validations if `hostname`
 * differs with `host`.
 *
 * @param version   SPDY protocol version, recommended value `ISpdyV3`
 * @param host      Remote host
 * @param hostname  Remote hostname for certificate verification
 * @param port      Remote port
 * @param secure    `YES` if connecting to TLS server
 *
 * @return Initialized connection
 */
- (id) init: (ISpdyVersion) version
       host: (NSString*) host
   hostname: (NSString*) hostname
       port: (UInt16) port
     secure: (BOOL) secure;

/**
 * Schedule connection in a run loop.
 * NOTE: If not invoked - default loop (running in separate thread) will be
 * used (one per application).
 *
 * @param loop  Loop to schedule connection in
 * @param mode  Mode to use
 */
- (void) scheduleInRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode;

/**
 * Unschedule connection from a run loop.
 *
 * @param loop  Loop to schedule connection in
 * @param mode  Mode to use
 */
- (void) removeFromRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode;

/**
 * Set dispatch queue to run delegate callbacks in.
 *
 * @param queue  Dispatch queue
 */
- (void) setDelegateQueue: (dispatch_queue_t) queue;

/**
 * Enable/disable Nagle algorithm
 */
- (void) setNoDelay: (BOOL) enable;


/**
 * Set send buffer size
 */
- (void) setSendBufferSize: (int) size;

/**
 * Enable/disable TCP keepalive and set its timeout
 * @param delay  0 - to disable, positive - to set keepalive delay (in seconds)
 * @param interval  keepalive probe interval
 * @param count  keepalive probe count before giving up
 */
- (void) setKeepAliveDelay: (NSInteger) delay
                  interval: (NSInteger) interval
                  andCount: (NSInteger) count;

/**
 * Configure the socket for VoIP usage
 */
- (void) setVoip: (BOOL) enable;

/**
 * Check underlying TCP socket's status and emit error in case of trouble
 */
- (ISpdyCheckStatus) checkSocket;

/**
 * Connect to remote server.
 *
 * @return `YES` - If socket initialization was successful
 */
- (BOOL) connect;

/**
 * Connect to remote server.
 *
 * @param timeout  if non-zero - how much to wait until throwing an error,
 *                 if zero - reset timeout
 *
 * @return `YES` - If socket initialization was successful
 */
- (BOOL) connectWithTimeout: (NSTimeInterval) timeout;

/**
 * Disconnect from remote server.
 * NOTE: Connection will be automatically closed at `dealloc`, so do it if you
 * want it to be closed right now
 *
 * @return `YES` - IF socket deinitialization was successful
 */
- (BOOL) close;

/**
 * Disconnect gracefully from remote server
 * @param timeout  if non-zero - how much to wait until throwing an error,
 *                 if zero - wait indefinitely
 * NOTE: Will retain connection until all active requests will be finished
 */
- (void) closeSoon: (NSTimeInterval) timeout;

/**
 * Send initialized request to the server.
 *
 * @param request  `ISpdyRequest` to send to the server
 */
- (void) send: (ISpdyRequest*) request;

/**
 * Send ping and measure RTT
 *
 * @param block    Block to execute upon receival of ping
 * @param waitMax  Max time to wait until giving up
 */
- (void) ping: (ISpdyPingCallback) block waitMax: (NSTimeInterval) wait;

/**
 * Set connection timeout (default value: 2 seconds)
 *
 * @param timeout  if non-zero - how much to wait until throwing an error,
 *                 if zero - reset timeout
 */
- (void) setTimeout: (NSTimeInterval) timeout;

/**
 * Add pinned SSL certificate
 *
 * @param cert  A certificate in DER encoding
 */
- (void) addPinnedSSLCert: (NSData*) cert;

@end
