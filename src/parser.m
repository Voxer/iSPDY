// The MIT License (MIT)
//
// Copyright (c) 2013 Voxer
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

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
      case kISpdySynStream:
        if (body_len < 4)
          return [self error: kISpdyParserErrSynStreamOOB];
        // NOTE: Actually, it is an associated stream id
        stream_id = ntohl(*(uint32_t*) (input + 4)) & 0x7fffffff;
        frame_body = [self parseSynStream: input length: body_len];

        // Error, but should be already handled by parseSynStream
        if (frame_body == nil)
          return;
        break;
      case kISpdySynReply:
        if (body_len < 6)
          return [self error: kISpdyParserErrSynReplyOOB];
        stream_id = ntohl(*(uint32_t*) input) & 0x7fffffff;
        if (version_ == kISpdyV2)
          frame_body = [self parseSynReply: input + 6 length: body_len - 6];
        else
          frame_body = [self parseSynReply: input + 4 length: body_len - 4];

        // Error, but should be already handled by parseSynReply
        if (frame_body == nil)
          return;
        break;
      case kISpdyHeaders:
        if (body_len < 6)
          return [self error: kISpdyParserErrHeadersOOB];
        stream_id = ntohl(*(uint32_t*) input) & 0x7fffffff;
        if (version_ == kISpdyV2)
          frame_body = [self parseHeaders: input + 6 length: body_len - 6];
        else
          frame_body = [self parseHeaders: input + 4 length: body_len - 4];

        // Error, but should be already handled by parseHeaders
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
          if (body_len < 8)
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
          if (body_len < 4)
            return [self error: kISpdyParserErrPingOOB];
          uint32_t ping_id = ntohl(*(uint32_t*) input);
          frame_body = [NSNumber numberWithUnsignedInt: ping_id];
        }
        break;
      case kISpdyGoaway:
        frame_body = [self parseGoaway: input length: body_len];

        // Should be handled by parseGoawaySettings
        if (frame_body == nil)
          return;
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


- (NSDictionary*) parseKVs: (const uint8_t*) data
                    length: (NSUInteger) length
                withFilter: (BOOL (^)(NSString*, NSString*)) filter {
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

    if (filter(kv[0], kv[1]))
      [headers setValue: kv[1] forKey: kv[0]];
    kv_count--;
  }

  return headers;
}


- (ISpdyResponse*) parseSynReply: (const uint8_t*) data
                          length: (NSUInteger) length {
  __block ISpdyResponse* reply = [ISpdyResponse alloc];
  NSDictionary* headers = [self parseKVs: data
                                  length: length
                              withFilter: ^BOOL (NSString* key, NSString* val) {
    if ((version_ == kISpdyV2 && [key isEqualToString: @"status"]) ||
        (version_ == kISpdyV3 && [key isEqualToString: @":status"])) {
      NSScanner* scanner = [NSScanner scannerWithString: val];
      NSInteger code;
      if (![scanner scanInteger: &code]) {
        [self error: kISpdyParserErrInvalidStatusHeader];
        return NO;
      }

      reply.code = code;
      reply.status = [val substringFromIndex: [scanner scanLocation] + 1];
      return NO;
    }
    return YES;
  }];
  if (headers == nil) {
    [self error: kISpdyParserErrSynReplyOOB];
    return nil;
  }

  reply.headers = headers;
  return reply;
}


- (ISpdyPush*) parseSynStream: (const uint8_t*) data
                       length: (NSUInteger) length {
  if (length < 6) {
    [self error: kISpdyParserErrSynStreamOOB];
    return nil;
  }

  __block ISpdyPush* push = [ISpdyPush alloc];
  push.stream_id = ntohl(*(uint32_t*) data) & 0x7fffffff;
  push.associated_id = ntohl(*(uint32_t*) (data + 4)) & 0x7fffffff;
  push.priority = data[8];

  if (version_ == kISpdyV2)
    push.priority >>= 6;
  else
    push.priority >>= 5;

  NSDictionary* headers = [self parseKVs: data + 10
                                  length: length - 10
                              withFilter: ^BOOL (NSString* key, NSString* val) {
    if ((version_ == kISpdyV2 && [key isEqualToString: @"method"]) ||
        (version_ == kISpdyV3 && [key isEqualToString: @":method"])) {
      push.method = val;
      return NO;
    }

    if ((version_ == kISpdyV2 && [key isEqualToString: @"url"]) ||
        (version_ == kISpdyV3 && [key isEqualToString: @":path"])) {
      push.url = val;
      return NO;
    }

    if ((version_ == kISpdyV2 && [key isEqualToString: @"version"]) ||
        (version_ == kISpdyV3 && [key isEqualToString: @":version"])) {
      push.version = val;
      return NO;
    }

    if ((version_ == kISpdyV2 && [key isEqualToString: @"scheme"]) ||
        (version_ == kISpdyV3 && [key isEqualToString: @":scheme"])) {
      push.scheme = val;
      return NO;
    }

    return YES;
  }];
  if (headers == nil) {
    [self error: kISpdyParserErrSynStreamOOB];
    return nil;
  }

  push.headers = headers;
  return push;
}


- (NSDictionary*) parseHeaders: (const uint8_t*) data
                        length: (NSUInteger) length {
  return [self parseKVs: data
                 length: length
             withFilter: ^BOOL (NSString* key, NSString* val) {
    return YES;
  }];
}


- (ISpdySettings*) parseSettings: (const uint8_t*) data
                          length: (NSUInteger) length {
  if (length < 4) {
    [self error: kISpdyParserErrSettingsOOB];
    return nil;
  }

  uint32_t setting_count = ntohl(*(uint32_t*) data);
  data += 4;
  length -= 4;

  if (length < setting_count * 8) {
    [self error: kISpdyParserErrSettingsOOB];
    return nil;
  }

  ISpdySettings* settings = [ISpdySettings alloc];
  while (setting_count > 0) {
    uint32_t key = ntohl(*(uint32_t*) data) & 0x00ffffff;
    uint32_t value = ntohl(*(uint32_t*) (data + 4));

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


- (ISpdyGoaway*) parseGoaway: (const uint8_t*) data
                      length: (NSUInteger) length {
  ISpdyGoaway* res = [ISpdyGoaway alloc];

  if (length < 4) {
    [self error: kISpdyParserErrGoawayOOB];
    return nil;
  }

  res.stream_id = ntohl(*(uint32_t*) data);
  if (version_ == kISpdyV2) {
    res.status = kISpdyGoawayOk;
  } else {
    if (length < 8) {
      [self error: kISpdyParserErrGoawayOOB];
      return nil;
    }
    res.status = (ISpdyGoawayStatus) ntohl(*(uint32_t*) data + 4);
  }

  return res;
}

@end

@implementation ISpdySettings
// No-op, just to generate properties
@end

@implementation ISpdyGoaway
// No-op, just to generate properties
@end
