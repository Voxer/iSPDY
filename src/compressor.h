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
  NSError* error_;
}

// Initialize compressor with specific protocol version
- (id) init: (ISpdyVersion) version;

// Get last operation's output
- (NSMutableData*) output;

// Get last operation's error
- (NSError*) error;

// Deflate input data
- (BOOL) deflate: (NSData*) input;

// Inflate input data
- (BOOL) inflate: (NSData*) input;

// (Internal) use deflate()/inflate() instead
- (BOOL) process: (BOOL) isDeflate in: (NSData*) input;

@end
