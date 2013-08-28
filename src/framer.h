#import <Foundation/Foundation.h>
#import "ispdy.h"  // ISpdyVersion

// Forward-declarations
@class ISpdyCompressor;

// Possible SPDY Protocol RST codes
typedef enum {
  kISpdyRstProtocolError = 0x1,
  kISpdyRstInvalidStream = 0x2,
  kISpdyRstRefusedStream = 0x3,
  kISpdyRstUnsupportedVersion = 0x4,
  kISpdyRstCancel = 0x5,
  kISpdyRstInternalError = 0x6,
  kISpdyRstFlowControlError = 0x7
} ISpdyRstCode;

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
- (id) init: (ISpdyVersion) version;

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

// Utilities, not for public use
- (void) controlHeader: (uint16_t) type
                 flags: (uint8_t) flags
                length: (uint32_t) len;
- (void) putValue: (NSString*) value withKey: (NSString*) key;

@end
