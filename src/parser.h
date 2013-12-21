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
#import "ispdy.h"  // ISpdyVersion, ISpdyResponse, ISpdySettings, ...
#import "common.h"  // Common internal parts

// Forward-declarations
@class ISpdyCompressor;

typedef enum {
  kISpdyParserErrInvalidVersion,
  kISpdyParserErrSynStreamOOB,
  kISpdyParserErrSynReplyOOB,
  kISpdyParserErrSettingsOOB,
  kISpdyParserErrHeadersOOB,
  kISpdyParserErrRstOOB,
  kISpdyParserErrPingOOB,
  kISpdyParserErrGoawayOOB,
  kISpdyParserErrKVsTooSmall,
  kISpdyParserErrKeyLenOOB,
  kISpdyParserErrKeyValueOOB,
  kISpdyParserErrInvalidStatusHeader
} ISpdyParserError;

// SPDY Protocol parser class
@interface ISpdyParser : NSObject {
  ISpdyVersion version_;
  ISpdyCompressor* comp_;

  NSMutableData* buffer_;
}

// Parser delegate, usually ISpdy instance
@property (weak) id <ISpdyParserDelegate> delegate;

// Initialize framer with specific protocol version
- (id) init: (ISpdyVersion) version compressor: (ISpdyCompressor*) comp;

// Execute parser on given data, accumulate data if needed
// NOTE: that `handleFrame:...` delegate's method could be executed multiple
// times, if `data` contains multiple frames, or if start of one frame was
// previously accumulated.
- (void) execute: (const uint8_t*) data length: (NSUInteger) length;

// Helper function
- (void) error: (ISpdyParserError) err;

// Parse Key/Value pairs
- (NSDictionary*) parseKVs: (const uint8_t*) data
                    length: (NSUInteger) length
                withFilter: (BOOL (^)(NSString*, NSString*)) filter;

// Parse SYN_STREAM's body
- (ISpdyResponse*) parseSynStream: (const uint8_t*) data
                           length: (NSUInteger) length;

// Parse SYN_REPLY's body
- (ISpdyResponse*) parseSynReply: (const uint8_t*) data
                          length: (NSUInteger) length;

// Parse HEADERS's body
- (NSDictionary*) parseHeaders: (const uint8_t*) data
                        length: (NSUInteger) length;

// Parse SETTINGS's body
- (ISpdySettings*) parseSettings: (const uint8_t*) data
                          length: (NSUInteger) length;

// Parse GOAWAY's body
- (ISpdyGoaway*) parseGoaway: (const uint8_t*) data
                      length: (NSUInteger) length;

@end
