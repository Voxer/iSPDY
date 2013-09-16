#import <Foundation/Foundation.h>
#import <arpa/inet.h>  // ntohl
#import <string.h>  // memmove

#import "parser.h"
#import "common.h"  // Common internal parts
#import "compressor.h"  // ISpdyCompressor
#import "ispdy.h"  // ISpdyVersion

@implementation ISpdyParser

- (id) init: (ISpdyVersion) version compressor: (ISpdyCompressor*) comp {
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
  NSUInteger read = 0;

  while (len >= 8) {
    BOOL skip = NO;
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
        return [self error: kISpdyParserErrInvalidVersion];
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
    read += 8;

    switch (frame_type) {
      case kISpdyData:
        frame_body = [NSData dataWithBytes: input length: body_len];
        break;
      case kISpdySynReply:
        stream_id = ntohl(*(uint32_t*) input) & 0x7fffffff;
        if (version_ == kISpdyV2)
          frame_body = [self parseSynReply: input + 6 length: body_len - 6];
        else
          frame_body = [self parseSynReply: input + 4 length: body_len - 4];

        // Error, but should be already handled by parseSynReply
        if (frame_body == nil)
          return;
        break;
      case kISpdySettings:
        if (version_ == kISpdyV2) {
          // SETTINGS in v2 has endianness problem, skip it
          skip = YES;
          break;
        }
        frame_body = [self parseSettings: input length: body_len];

        // Should be handled by parseSettings
        if (frame_body == nil)
          return;
        break;
      case kISpdyRstStream:
      case kISpdyWindowUpdate:
        {
          if (len < 8)
            return [self error: kISpdyParserErrRstOOB];
          stream_id = ntohl(*(uint32_t*) input) & 0x7fffffff;
          uint32_t code = ntohl(*(uint32_t*) (input + 4));

          // Mask window update, as its a 31bit value
          if (frame_type == kISpdyWindowUpdate)
            code = code & 0x7fffffff;

          // And frame body is just a number
          frame_body = [NSNumber numberWithUnsignedInt: code];
        }
        break;
      case kISpdyPing:
        {
          if (len < 4)
            return [self error: kISpdyParserErrPingOOB];
          uint32_t ping_id = ntohl(*(uint32_t*) input);
          frame_body = [NSNumber numberWithUnsignedInt: ping_id];
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
    read += body_len;

    if (!skip) {
      [self.delegate handleFrame: frame_type
                            body: frame_body
                          is_fin: (flags & kISpdyFlagFin) != 0
                       forStream: stream_id];
    }
  }

  // Shift data
  if (read != 0) {
    memmove([buffer_ mutableBytes],
            [buffer_ bytes] + read,
            [buffer_ length] - read);
    [buffer_ setLength: [buffer_ length] - read];
  }
}


- (void) error: (ISpdyParserError) err {
  NSError* error = [NSError errorWithDomain: @"spdy-parser"
                                       code: err
                                   userInfo: nil];
  [self.delegate handleParserError: error];
}


- (ISpdyResponse*) parseSynReply: (const uint8_t*) data
                          length: (NSUInteger) length {
  NSData* compressed_kvs = [NSData dataWithBytes: data length: length];
  if (![comp_ inflate: compressed_kvs]) {
    [self.delegate handleParserError: [comp_ error]];
    return nil;
  }

  const char* kvs = [[comp_ output] bytes];
  NSUInteger kvs_len = [[comp_ output] length];

  // Size of length field in every location below
  NSUInteger len_size = version_ == kISpdyV2 ? 2 : 4;

  // Get count of pairs
  if (kvs_len < len_size) {
    [self error: kISpdyParserErrKVsTooSmall];
    return nil;
  }
  uint32_t kv_count = len_size == 2 ? ntohs(*(uint16_t*) kvs) :
                                      ntohl(*(uint32_t*) kvs);
  kvs += len_size;
  kvs_len -= len_size;

  ISpdyResponse* reply = [ISpdyResponse alloc];
  NSMutableDictionary* headers =
      [[NSMutableDictionary alloc] initWithCapacity: 16];

  while (kv_count > 0) {
    NSString* kv[] = { nil, nil };
    for (int i = 0; i < 2; i++) {
      if (kvs_len < len_size) {
        [self error: kISpdyParserErrKeyLenOOB];
        return nil;
      }
      uint32_t val_len = len_size == 2 ? ntohs(*(uint16_t*) kvs) :
                                         ntohl(*(uint32_t*) kvs);
      kvs += len_size;
      kvs_len -= len_size;

      if (kvs_len < val_len) {
        [self error: kISpdyParserErrKeyValueOOB];
        return nil;
      }
      kv[i] = [[NSString alloc] initWithBytes: kvs
                                       length: val_len
                                     encoding: NSUTF8StringEncoding];
      kvs += val_len;
      kvs_len -= val_len;
    }

    if ((version_ == kISpdyV2 && [kv[0] isEqualToString: @"status"]) ||
        (version_ == kISpdyV3 && [kv[0] isEqualToString: @":status"])) {
      NSScanner* scanner = [NSScanner scannerWithString: kv[1]];
      NSInteger code;
      if (![scanner scanInteger: &code]) {
        [self error: kISpdyParserErrInvalidStatusHeader];
        return nil;
      }

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


- (ISpdySettings*) parseSettings: (const uint8_t*) data
                          length: (NSUInteger) length {
  if (length < 4)
    return nil;

  uint32_t setting_count = ntohl(*(uint32_t*) data);
  data += 4;
  length -= 4;

  if (length < setting_count * 8)
    return nil;

  ISpdySettings* settings = [ISpdySettings alloc];
  while (setting_count > 0) {
    uint32_t key = ntohl(*(uint32_t*) data) & 0x00ffffff;
    uint32_t value = ntohl(*(uint32_t*) data + 4);

    switch ((ISpdySetting) key) {
      case kISpdySettingInitialWindowSize:
        // NOTE: it can really be negative
        settings.initial_window = (int32_t) value;
        break;
      default:
        break;
    }

    data += 8;
    length -= 8;
    setting_count--;
  }

  return settings;
}

@end

@implementation ISpdySettings
// No-op, just to generate properties
@end
