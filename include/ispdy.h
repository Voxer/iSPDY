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
  kISpdyErrDealloc,
  kISpdyErrNoSuchStream,
  kISpdyErrRst,
  kISpdyErrParseError,
  kISpdyErrDoubleResponse
} ISpdyErrorCode;

/**
 * Response class
 */
@interface ISpdyResponse : NSObject

@property NSInteger code;
@property NSString* status;
@property NSDictionary* headers;

@end

/**
 * Delegate for handling request-level events
 */
@protocol ISpdyRequestDelegate
- (void) request: (ISpdyRequest*) req handleResponse: (ISpdyResponse*) res;
- (void) request: (ISpdyRequest*) req handleError: (NSError*) err;
- (void) request: (ISpdyRequest*) req handleInput: (NSData*) input;
- (void) handleEnd: (ISpdyRequest*) req;
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
@property (weak) id <ISpdyRequestDelegate> delegate;

/**
 * Request method, should be initialized using `init: url:` selector.
 */
@property NSString* method;

/**
 * Request url, should be initialized using `init: url:` selector.
 */
@property NSString* url;

/**
 * HTTP Headers
 */
@property NSDictionary* headers;

/**
 * Just a property to store user-defined reference, not used internally.
 */
@property (weak) id opaque;

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
 * Delegate for handling connection-level events
 */
@protocol ISpdyDelegate

/**
 * Invoked on global, connection-level error.
 *
 * @param conn  ISpdy connection on which the error has happened
 * @param err   The error itself
 */
- (void) connection: (ISpdy*) conn handleError: (NSError*) err;
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
@property (weak) id <ISpdyDelegate> delegate;

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
 * Connect to remote server.
 *
 * @return `YES` - If socket initialization was successful
 */
- (BOOL) connect;

/**
 * Disconnect from remote server.
 * NOTE: Connection will be automatically closed at `dealloc`, so do it if you
 * want it to be closed right now
 *
 * @return `YES` - IF socket deinitialization was successful
 */
- (BOOL) close;

/**
 * Send initialized request to the server.
 *
 * @param request  `ISpdyRequest` to send to the server
 */
- (void) send: (ISpdyRequest*) request;

/**
 * Set connection timeout (default value: 2 seconds)
 *
 * @param timeout  if non-zero - how much to wait until throwing an error,
 *                 if zero - reset timeout
 */
- (void) setTimeout: (NSTimeInterval) timeout;

@end
