#import <Foundation/Foundation.h>

#import "scheduler.h"

// Forward-declarations
@class ISpdyPing;
@class ISpdyCompressor;

typedef enum {
  kISpdyWriteNoChunkBuffering,
  kISpdyWriteChunkBuffering
} ISpdyWriteMode;

// Possible SPDY Protocol RST codes
typedef enum {
  kISpdyRstProtocolError = 0x1,
  kISpdyRstInvalidStream = 0x2,
  kISpdyRstRefusedStream = 0x3,
  kISpdyRstUnsupportedVersion = 0x4,
  kISpdyRstCancel = 0x5,
  kISpdyRstInternalError = 0x6,
  kISpdyRstFlowControlError = 0x7,
  kISpdyRstMax = 0xffffffff
} ISpdyRstCode;

typedef enum {
  kISpdySettingUpBandwidth = 0x1,
  kISpdySettingDownBandwidth = 0x2,
  kISpdySettingRTT = 0x3,
  kISpdySettingMaxConcurrentStreams = 0x4,
  kISpdySettingCurrentCWND = 0x5,
  kISpdySettingDownloadRetransRate = 0x6,
  kISpdySettingInitialWindowSize = 0x7,
  kISpdySettingClientCertificateVectorSize = 0x8,
  kISpdySettingMax = 0x00ffffff
} ISpdySetting;

typedef enum {
  kISpdySettingFlagPersist = 0x1,
  kISpdySettingFlagPersisted = 0x2
} ISpdySettingFlag;

typedef enum {
  kISpdyGoawayOk = 0x0,
  kISpdyGoawayProtocolError = 0x1,
  kISpdyGoawayInternalError = 0x2
} ISpdyGoawayStatus;

typedef enum {
  kISpdyFlagFin = 0x1,
} ISpdyFlags;

// SPDY Frame types
typedef enum {
  kISpdySynStream = 1,
  kISpdySynReply = 2,
  kISpdyRstStream = 3,
  kISpdySettings = 4,
  kISpdyNoop = 5,
  kISpdyPing = 6,
  kISpdyGoaway = 7,
  kISpdyHeaders = 8,
  kISpdyWindowUpdate = 9,
  kISpdyCredential = 10,
  kISpdyData = 0xffff
} ISpdyFrameType;

@protocol ISpdyParserDelegate
- (void) handleFrame: (ISpdyFrameType) type
                body: (id) body
              is_fin: (BOOL) is_fin
           forStream: (uint32_t) stream_id;
- (void) handleParserError: (NSError*) err;
@end

@interface ISpdySettings : NSObject

@property int32_t initial_window;

@end

@interface ISpdyGoaway : NSObject

@property int32_t stream_id;
@property ISpdyGoawayStatus status;

@end

@interface ISpdyRequest ()

@property uint32_t stream_id;

@end

@interface ISpdyPush ()

@property uint32_t associated_id;

@end

@interface ISpdy ()

// Self-retaining reference for closeSoon
@property (strong) ISpdy* goaway_retain_;

@end

@interface ISpdy (ISpdyPrivate) <NSStreamDelegate,
                                 ISpdyParserDelegate,
                                 ISpdySchedulerDelegate>

// Get fd out of streams
- (void) _fdWithBlock: (void(^)(CFSocketNativeHandle)) block;

// Invoked on connection timeout
- (void) _onTimeout;

// Invoked on ping timeout
- (void) _onPingTimeout: (ISpdyPing*) ping;

// Use default (off-thread) NS loop, if no was provided by user
- (void) _lazySchedule;

// Create and schedule timer
- (NSTimer*) _timerWithTimeInterval: (NSTimeInterval) interval
                             target: (id) target
                           selector: (SEL) selector
                           userInfo: (id) info;

// Write raw data to the underlying socket, returns YES if write wasn't buffered
- (NSInteger) _writeRaw: (NSData*) data withMode: (ISpdyWriteMode) mode;

// Handle global errors
- (void) _handleError: (ISpdyError*) err;

// Close all streams and send error to each of them
- (void) _closeStreams: (ISpdyError*) err;

// Destroy all pings and invoke callbacks
- (void) _destroyPings: (ISpdyError*) err;

// See ISpdyRequest for description
- (void) _end: (ISpdyRequest*) request;
- (void) _removeStream: (ISpdyRequest*) request;
- (void) _writeData: (NSData*) data to: (ISpdyRequest*) request fin: (BOOL) fin;
- (void) _addHeaders: (NSDictionary*) headers to: (ISpdyRequest*) request;
- (void) _rst: (uint32_t) stream_id code: (uint8_t) code;
- (void) _error: (ISpdyRequest*) request code: (ISpdyErrorCode) code;
- (void) _handlePing: (NSNumber*) ping_id;
- (void) _handleDrain;
- (void) _handleGoaway: (ISpdyGoaway*) goaway;
- (void) _handlePush: (ISpdyPush*) push forRequest: (ISpdyRequest*) req;
- (void) _onGoawayTimeout;

// dispatch delegate callback
- (void) _delegateDispatch: (void (^)()) block;
- (void) _delegateDispatchSync: (void (^)()) block;

// dispatch connection callback
- (void) _connectionDispatch: (void (^)()) block;

@end

// Request state
@interface ISpdyRequest ()

@property ISpdy* connection;
@property ISpdyCompressor* decompressor;

// Indicates queued end
@property BOOL pending_closed_by_us;
@property BOOL closed_by_us;
@property BOOL closed_by_them;
@property BOOL seen_response;
@property NSInteger initial_window_in;
@property NSInteger initial_window_out;
@property NSInteger window_in;
@property NSInteger window_out;

@end

@interface ISpdyRequest (ISpdyRequestPrivate)

// Invoked on SYN_REPLY and PUSH streams
- (void) _handleResponseHeaders: (NSDictionary*) headers;

// Invoked on request timeout
- (void) _onTimeout;

// Calls `[req close]` if the stream is closed by both
// us and them.
- (void) _tryClose;

// Invokes delegate's handleEnd: and remove stream from the connection's
// dictionary
- (void) _close: (ISpdyError*) err sync: (BOOL) sync;

// Sends `end` selector if the close is pending
- (void) _tryPendingClose;

// Set queued timeout, or reset existing one
- (void) _resetTimeout;

// Update outgoing window size
- (void) _updateWindow: (NSInteger) delta;

// Decompress data or return input if there're no compression
- (NSError*) _decompress: (NSData*) data withBlock: (void (^)(NSData*)) block;

// Bufferize frame data and fetch it
- (void) _queueOutput: (NSData*) data;
- (void) _queueHeaders: (NSDictionary*) headers;
- (BOOL) _hasQueuedData;
- (void) _unqueueOutput;
- (void) _unqueueHeaders;

@end

@interface ISpdyLoopWrap : NSObject

@property NSRunLoop* loop;
@property NSString* mode;

+ (ISpdyLoopWrap*) stateForLoop: (NSRunLoop*) loop andMode: (NSString*) mode;
- (BOOL) isEqual: (id) anObject;

@end

@interface ISpdyPing : NSObject

@property NSNumber* ping_id;
@property (strong) ISpdyPingCallback block;
@property NSTimer* timeout;
@property NSDate* start_date;

@end

@interface ISpdyError (ISpdyErrorPrivate)

+ (ISpdyError*) errorWithCode: (ISpdyErrorCode) code;
+ (ISpdyError*) errorWithCode: (ISpdyErrorCode) code andDetails: (id) details;

@end
