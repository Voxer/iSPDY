#import <Foundation/Foundation.h>
#import "ispdy.h"  // ISpdyVersion

// Wrapper class for deflating/inflating data using zlib with SPDY dictionary
@interface ISpdyCompressor : NSObject

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
