#import <Foundation/Foundation.h>
#import "ispdy.h"  // ISpdyVersion
#import "zlib.h"  // z_stream

// Wrapper class for deflating/inflating data using zlib with SPDY dictionary
@interface ISpdyCompressor : NSObject {
  z_stream deflate_;
  z_stream inflate_;
  const unsigned char* dict_;
  unsigned int dict_len_;
  NSMutableData* output_;
}

// Initialize compressor with specific protocol version
- (id) init: (ISpdyVersion) version;

// Get last operation's output
- (NSMutableData*) output;

// Deflate input data
- (void) deflate: (NSData*) input;

// Inflate input data
- (void) inflate: (NSData*) input;

// (Internal) use deflate()/inflate() instead
- (void) process: (BOOL) isDeflate in: (NSData*) input;

@end
