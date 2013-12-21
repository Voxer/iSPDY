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
#import "ispdy.h"  // ISpdyVersion
#import "common.h"  // Common internal parts

// Forward-declarations
@class ISpdyCompressor;

// Framer class.
//
// Creates SPDY frames from raw data, or other details
@interface ISpdyFramer : NSObject {
  ISpdyVersion version_;
  ISpdyCompressor* comp_;

  // Cached data for pairs
  NSInteger pair_count_;
  NSMutableData* pairs_;

  // And cached data for output
  NSMutableData* output_;
}

// Initialize framer with specific protocol version
- (id) init: (ISpdyVersion) version compressor: (ISpdyCompressor*) comp;

// Truncate internal buffer (`output_`)
- (void) clear;

// Get generated frame(s)
- (NSMutableData*) output;

// Generate different frames
- (void) synStream: (uint32_t) stream_id
          priority: (uint8_t) priority
            method: (NSString*) method
                to: (NSString*) url
           headers: (NSDictionary*) headers;
- (void) headers: (uint32_t) stream_id
     withHeaders: (NSDictionary*) headers;
- (void) dataFrame: (uint32_t) stream_id
               fin: (BOOL) fin
          withData: (NSData*) data;
- (void) rst: (uint32_t) stream_id code: (ISpdyRstCode) code;
- (void) initialWindow: (uint32_t) window;
- (void) windowUpdate: (uint32_t) stream_id update: (uint32_t) update;
- (void) ping: (uint32_t) ping_id;
- (void) goaway: (uint32_t) stream_id status: (ISpdyGoawayStatus) status;

// Utilities, not for public use
- (void) putKVs: (void (^)()) block;
- (void) controlHeader: (uint16_t) type
                 flags: (uint8_t) flags
                length: (uint32_t) len;
- (void) putValue: (NSString*) value withKey: (NSString*) key;

@end
