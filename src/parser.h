#import <Foundation/Foundation.h>
#import "ispdy.h"  // ISpdyVersion

// SPDY Protocol parser class
@interface ISpdyParser : NSObject {
  ISpdyVersion version_;
  NSMutableData* buffer_;
}

// Parser delegate, usually ISpdy instance
@property (weak) id <ISpdyParserDelegate> delegate;

// Initialize framer with specific protocol version
- (id) init: (ISpdyVersion) version;
- (void) execute: (const uint8_t*) data length: (NSUInteger) length;

@end
