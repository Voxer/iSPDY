#import <Foundation/Foundation.h>
#import "ispdy.h"  // ISpdyVersion, ISpdyResponse, ISpdySettings, ...

// Forward-declarations
@class ISpdyCompressor;


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

// Parse SYN_REPLY's body
- (ISpdyResponse*) parseSynReply: (const uint8_t*) data
                          length: (NSUInteger) length;
- (ISpdySettings*) parseSettings: (const uint8_t*) data
                          length: (NSUInteger) length;

@end
