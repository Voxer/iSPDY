#import <CoreFoundation/CFStream.h>
#import <Foundation/Foundation.h>
#import "ispdy-internal.h"  // Common internal parts

// Forward-declarations
@class ISpdy;
@class ISpdyCompressor;
@class ISpdyFramer;
@class ISpdyParser;
@class ISpdyRequest;

// SPDY Protocol version
typedef enum {
  kISpdyV2,
  kISpdyV3
} ISpdyVersion;

// Possible error codes in NSError with domain @"spdy"
typedef enum {
  kISpdyErrConnectionEnd,
  kISpdyErrNoSuchStream,
  kISpdyErrRst,
  kISpdyErrParseError,
  kISpdyErrDoubleResponse
} ISpdyErrorCode;

// Response class
@interface ISpdyResponse : NSObject

@property NSInteger code;
@property NSString* status;
@property NSDictionary* headers;

@end

// Delegate for handling request-level events
@protocol ISpdyRequestDelegate
- (void) request: (ISpdyRequest*) req handleResponse: (ISpdyResponse*) res;
- (void) request: (ISpdyRequest*) req handleError: (NSError*) err;
- (void) request: (ISpdyRequest*) req handleInput: (NSData*) input;
- (void) handleEnd: (ISpdyRequest*) req;
@end

// Request class.
//
// Should be used to initiate new request to the server, works only with
// existing ISpdy connection.
@interface ISpdyRequest : NSObject {
  NSMutableArray* data_queue_;
}

@property (weak) id <ISpdyRequestDelegate> delegate;
@property (weak) ISpdy* connection;
@property NSString* method;
@property NSString* url;
@property NSDictionary* headers;

// Mostly internal fields
@property uint32_t stream_id;
@property BOOL pending_closed_by_us;
@property BOOL closed_by_us;
@property BOOL closed_by_them;
@property BOOL seen_response;

// Internal too, window value for incoming and outgoing data
@property NSInteger window_in;
@property NSInteger window_out;

// Initialize properties
- (id) init: (NSString*) method url: (NSString*) url;

// Write raw data to the underlying stream
- (void) writeData: (NSData*) data;

// Write string to the underlying stream
- (void) writeString: (NSString*) data;

// Gracefully end stream/request
- (void) end;

// Shutdown stream (CANCEL error code will be used)
- (void) close;

// Mostly internal method, calls `[req close]` if the stream is closed by both
// us and them.
- (void) _tryClose;

// (Internal) sends `end` selector if the close is pending
- (void) _tryPendingClose;

// (Internal)
- (void) _updateWindow: (NSInteger) delta;

// (Internal) Bufferize frame data and fetch it
- (void) _queueData: (NSData*) data;
- (BOOL) _hasQueuedData;
- (void) _unqueue;

@end

// Delegate for handling connection-level events
@protocol ISpdyDelegate
- (void) connection: (ISpdy*) conn handleError: (NSError*) err;
@end

// ISpdy connection class
//
// Connects to server and holds underlying socket, parsing incoming data and
// generating outgoing protocol data. Should be instantiated in order to
// send requests to the server.
@interface ISpdy : NSObject <NSStreamDelegate, ISpdyParserDelegate> {
  ISpdyVersion version_;
  NSInputStream* in_stream_;
  NSOutputStream* out_stream_;
  ISpdyCompressor* comp_;
  ISpdyFramer* framer_;
  ISpdyParser* parser_;

  // Next stream's id
  uint32_t stream_id_;
  NSInteger initial_window_;

  // Dictionary of all streams
  NSMutableDictionary* streams_;

  // Connection write buffer
  NSMutableData* buffer_;
}

@property (weak) id <ISpdyDelegate> delegate;

// Initialize connection to work with specified protocol version
- (id) init: (ISpdyVersion) version;

// Connect to remote server
- (BOOL) connect: (NSString*) host port: (UInt32) port secure: (BOOL) secure;

// Send initialized request to the server
- (void) send: (ISpdyRequest*) request;

// (Internal) Write raw data to the underlying socket
- (void) writeRaw: (NSData*) data;

// (Internal) Handle global errors
- (void) handleError: (NSError*) err;

// (Mostly internal) see ISpdyRequest for description
- (void) end: (ISpdyRequest*) request;
- (void) close: (ISpdyRequest*) request;
- (void) writeData: (NSData*) data to: (ISpdyRequest*) request;
- (void) rst: (uint32_t) stream_id code: (uint8_t) code;
- (void) error: (ISpdyRequest*) request code: (ISpdyErrorCode) code;

@end
