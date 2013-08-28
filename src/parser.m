#import <Foundation/Foundation.h>
#import <arpa/inet.h>  // ntohl
#import <string.h>  // memmove

#import "parser.h"
#import "compressor.h"  // ISpdyCompressor
#import "ispdy.h"  // ISpdyVersion

@implementation ISpdyParser

- (id) init: (ISpdyVersion) version compressor: (ISpdyCompressor*) comp {
  NSAssert(version == kISpdyV2, @"Only spdyv2 is supported now");

  self = [super init];
  if (!self)
    return self;

  version_ = version;
  comp_ = comp;
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
    ISpdyFrameType frame_type;
    id frame_body;
    uint32_t body_len;
    uint32_t stream_id = 0;
    uint8_t flags;

    if (!is_control) {
      // Data frame
      stream_id = ntohl(*(uint32_t*) input) & 0x7fffffff;
      frame_type = kISpdyData;
    } else {
      // Control frame
      uint16_t version = ntohs(*(uint16_t*) input) & 0x7fff;
      BOOL valid_version = version_ == kISpdyV2 ? version == 2 : version == 3;
      if (!valid_version)
        return [self.delegate handleParseError];
      frame_type = (ISpdyFrameType) ntohs(*(uint16_t*) (input + 2));
    }
    flags = input[4];
    body_len = ntohl(*(uint32_t*) (input + 4)) & 0x00ffffff;

    // Don't have enough data yet
    if (len < body_len + 8)
      break;

    // Skip header
    len -= 8;
    input += 8;

    switch (frame_type) {
      case kISpdyData:
        frame_body = [NSData dataWithBytes: input length: body_len];
        break;
      case kISpdySynReply:
        stream_id = ntohl(*(uint32_t*) input) & 0x7fffffff;
        frame_body = [self parseSynReply: input length: body_len];
        if (frame_body == nil)
          return [self.delegate handleParseError];
        break;
      case kISpdyRstStream:
        {
          stream_id = ntohl(*(uint32_t*) input) & 0x7fffffff;
          uint32_t code = ntohl(*(uint32_t*) (input + 4));
          frame_body = [NSNumber numberWithUnsignedInt: code];
        }
        break;
      default:
        // Ignore other frame's body
        frame_body = nil;
        break;
    }

    // Skip body
    len -= body_len;
    input += body_len;

    [self.delegate handleFrame: frame_type
                          body: frame_body
                         isFin: (flags & kISpdyFlagFin) != 0
                     forStream: stream_id];
  }

  // Shift data
  memmove(input, input + [buffer_ length] - len, len);
  [buffer_ setLength: len];
}

- (ISpdyResponse*) parseSynReply: (const uint8_t*) data
                          length: (NSUInteger) length {
  // Skip stream_id and unused
  NSData* compressed_kvs = [NSData dataWithBytes: data + 6 length: length - 6];
  [comp_ inflate: compressed_kvs];
  const char* kvs = [[comp_ output] bytes];
  NSUInteger kvs_len = [[comp_ output] length];

  // Get count of pairs
  if (kvs_len < 2)
    return nil;
  uint16_t kv_count = ntohs(*(uint16_t*) kvs);
  kvs += 2;
  kvs_len -= 2;

  ISpdyResponse* reply = [ISpdyResponse alloc];
  NSMutableDictionary* headers =
      [[NSMutableDictionary alloc] initWithCapacity: 16];

  while (kv_count > 0) {
    NSString* kv[] = { nil, nil };
    for (int i = 0; i < 2; i++) {
      if (kvs_len < 2)
        return nil;
      uint16_t val_len  = ntohs(*(uint16_t*) kvs);
      kvs += 2;
      kvs_len -= 2;

      if (kvs_len < val_len)
        return nil;
      kv[i] = [[NSString alloc] initWithBytes: kvs
                                       length: val_len
                                     encoding: NSUTF8StringEncoding];
      kvs += val_len;
      kvs_len -= val_len;
    }

    if ([kv[0] isEqualToString: @"status"]) {
      NSScanner* scanner = [NSScanner scannerWithString: kv[1]];
      NSInteger code;
      if (![scanner scanInteger: &code])
        return nil;

      reply.code = code;
      reply.status = [kv[1] substringFromIndex: [scanner scanLocation] + 1];
    } else {
      [headers setValue: kv[1] forKey: kv[0]];
    }
    kv_count--;
  }

  reply.headers = headers;
  return reply;
}

@end
