#import <Foundation/Foundation.h>
#import "ispdy.h"  // iSpdyVersion
#import "zlib.h"  // z_stream

@interface iSpdyCompressor : NSObject {
  z_stream deflate_;
  z_stream inflate_;
  const unsigned char* dict_;
  unsigned int dict_len_;
  NSMutableData* output_;
}

- (id) init: (iSpdyVersion) version;

- (NSMutableData*) output;
- (void) process: (BOOL) isDeflate in: (NSData*) input;
- (void) deflate: (NSData*) input;
- (void) inflate: (NSData*) input;

@end
