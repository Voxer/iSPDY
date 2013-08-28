#import <Foundation/Foundation.h>
#import <arpa/inet.h>  // ntohl
#import <string.h>  // memmove

#import "parser.h"
#import "ispdy.h"  // ISpdyVersion

@implementation ISpdyParser

- (id) init: (ISpdyVersion) version {
  NSAssert(version == kISpdyV2, @"Only spdyv2 is supported now");

  self = [super init];
  if (!self)
    return self;

  version_ = version;
  buffer_ = [[NSMutableData alloc] initWithCapacity: 4096];

  return self;
}


- (void) execute: (const uint8_t*) data length: (NSUInteger) length {
  // Regardless of buffer length queue new stuff into
  [buffer_ appendBytes: (const void*) data length: length];

  // Start parsing
  uint8_t* input = (uint8_t*) [buffer_ mutableBytes];
  NSUInteger len = [buffer_ length];
  while (len >= 8) {
    BOOL is_control = (input[0] & 0x80) != 0;
    uint32_t stream_id;
    uint32_t body_len;
    uint8_t flags;

    if (!is_control) {
      // Data frame
      stream_id = ntohl(*((uint32_t*) input)) & 0x7fffffff;
    } else {
      // Control frame
    }
    flags = input[4];
    body_len = ntohl(*((uint32_t*) (input + 4))) & 0x00ffffff;

    // Don't have enough data yet
    if (len < body_len + 8)
      break;

    // Skip header
    len -= 8;
    input += 8;

    // Emit data frame
    if (!is_control) {
      [self.delegate handleFrame: kISpdyData
                            body: [NSData dataWithBytes: input
                                                 length: body_len]
                           isFin: (flags & kISpdyFlagFin) != 0
                       forStream: stream_id];
    } else {
      // Skip frame...
    }
    len -= body_len;
  }

  // Shift data
  memmove(input, input + [buffer_ length] - len, len);
  [buffer_ setLength: len];
}

@end
