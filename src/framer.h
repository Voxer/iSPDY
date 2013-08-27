#import <Foundation/Foundation.h>
#import "ispdy.h"  // iSpdyVersion

// Forward-declarations
@class iSpdyCompressor;

@interface iSpdyFramer : NSObject {
  iSpdyVersion version_;
  iSpdyCompressor* comp_;

  // Cached data for pairs
  NSMutableData* pairs_;

  // And cached data for output
  NSMutableData* output_;
}

- (id) init: (iSpdyVersion) version;

- (void) clear;
- (NSMutableData*) output;

- (void) controlHeader: (uint16_t) type
                 flags: (uint8_t) flags
                length: (uint32_t) len;
- (void) putValue: (NSString*) value withKey: (NSString*) key;
- (void) synStream: (uint32_t) stream_id
          priority: (uint8_t) priority
            method: (NSString*) method
                to: (NSString*) url
           headers: (NSDictionary*) headers;
- (void) dataFrame: (uint32_t) stream_id
               fin: (BOOL) fin
          withData: (NSData*) data;

@end
