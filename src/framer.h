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
- (void) dataFrame: (uint32_t) stream_id
               fin: (BOOL) fin
          withData: (NSData*) data;
- (void) rst: (uint32_t) stream_id code: (ISpdyRstCode) code;
- (void) initialWindow: (uint32_t) window;
- (void) windowUpdate: (uint32_t) stream_id update: (uint32_t) update;
- (void) ping: (uint32_t) ping_id;

// Utilities, not for public use
- (void) controlHeader: (uint16_t) type
                 flags: (uint8_t) flags
                length: (uint32_t) len;
- (void) putValue: (NSString*) value withKey: (NSString*) key;

@end
