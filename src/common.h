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

@property (nonatomic) int32_t initial_window;

@end

@interface ISpdyGoaway : NSObject

@property (nonatomic) int32_t stream_id;
@property (nonatomic) ISpdyGoawayStatus status;

@end

@interface ISpdyRequest ()

@property (nonatomic) uint32_t stream_id;

@end

@interface ISpdyPush ()

@property (nonatomic) uint32_t associated_id;

@end

@interface ISpdy ()

// Self-retaining reference for closeSoon
@property (nonatomic, strong) ISpdy* goaway_retain_;

@end

@interface ISpdy (ISpdyPrivate) <NSStreamDelegate,
                                 ISpdyParserDelegate,
                                 ISpdySchedulerDelegate>

// Invoke delegate logging if present
- (void) _log: (ISpdyLogLevel) level
         file: (NSString*) file
         line: (NSInteger) line
       format: (NSString*) format, ...;

// Get fd out of streams
- (void) _fdWithBlock: (void(^)(CFSocketNativeHandle)) block;

// Use default (off-thread) NS loop, if no was provided by user
- (void) _lazySchedule;

// Create and schedule timer
- (dispatch_source_t) _timerWithTimeInterval: (NSTimeInterval) interval
                                    andBlock: (void (^)()) block;

// Private version of setTimeout and friends
- (void) _setTimeout: (NSTimeInterval) timeout;
- (void) _scheduleInRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode;
- (void) _removeFromRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode;
- (void) _setNoDelay: (BOOL) enable;
- (void) _setSendBufferSize: (int) size;
- (void) _setKeepAliveDelay: (NSInteger) delay
                   interval: (NSInteger) interval
                   andCount: (NSInteger) count;
- (BOOL) _close: (ISpdyError*) err;

// Write raw data to the underlying socket, returns YES if write wasn't buffered
- (NSInteger) _writeRaw: (NSData*) data withMode: (ISpdyWriteMode) mode;

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

// dispatch delegate callback
- (void) _delegateDispatch: (void (^)()) block;
- (void) _delegateDispatchSync: (void (^)()) block;

// dispatch connection callback
- (void) _connectionDispatch: (void (^)()) block;
- (void) _connectionDispatchSync: (void (^)()) block;

@end

// Request state
@interface ISpdyRequest ()

@property ISpdy* connection;
@property (nonatomic) ISpdyCompressor* decompressor;

// Indicates queued end
@property BOOL pending_closed_by_us;
@property BOOL closed_by_us;
@property BOOL closed_by_them;
@property (nonatomic) BOOL seen_response;
@property (nonatomic) NSInteger initial_window_in;
@property (nonatomic) NSInteger initial_window_out;
@property (nonatomic) NSInteger window_in;
@property (nonatomic) NSInteger window_out;

@end

@interface ISpdyRequest (ISpdyRequestPrivate)

// Invoked on SYN_REPLY and PUSH streams
- (void) _handleResponseHeaders: (NSDictionary*) headers;

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
@property dispatch_source_t timeout;
@property NSDate* start_date;

- (void) _invoke: (ISpdyPingStatus) status rtt: (NSTimeInterval) rtt;

@end

@interface ISpdyError (ISpdyErrorPrivate)

+ (ISpdyError*) errorWithCode: (ISpdyErrorCode) code;
+ (ISpdyError*) errorWithCode: (ISpdyErrorCode) code andDetails: (id) details;

@end
