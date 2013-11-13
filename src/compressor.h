#import <Foundation/Foundation.h>
#import "ispdy.h"  // ISpdyVersion

typedef enum {
  kISpdyCompressorModeDictDeflate,
  kISpdyCompressorModeDeflate,
  kISpdyCompressorModeGzip
} ISpdyCompressorMode;

// Wrapper class for deflating/inflating data using zlib with SPDY dictionary
@interface ISpdyCompressor : NSObject

// Initialize compressor with specific protocol version
- (id) init: (ISpdyVersion) version;

// Initialize compressor with specific protocol version and mode
- (id) init: (ISpdyVersion) version withMode: (ISpdyCompressorMode) mode;

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
