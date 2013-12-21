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
#import <arpa/inet.h>  // htonl

#import "framer.h"  // ISpdyFramer
#import "ispdy.h"  // ISpdyVersion
#import "common.h"  // Common internal parts
#import "compressor.h"  // ISpdyCompressor


@implementation ISpdyFramer

- (id) init: (ISpdyVersion) version compressor: (ISpdyCompressor*) comp {
  self = [super init];
  if (!self)
    return self;

  version_ = version;
  comp_ = comp;
  pairs_ = [[NSMutableData alloc] initWithCapacity: 4096];
  output_ = [[NSMutableData alloc] initWithCapacity: 4096];
  return self;
}


- (void) clear {
  [output_ setLength: 0];
}


- (NSMutableData*) output {
  return output_;
}


- (void) controlHeader: (uint16_t) type
                 flags: (uint8_t) flags
                length: (uint32_t) len {
  uint8_t header[8];

  header[0] = 0x80;
  header[1] = version_ == kISpdyV2 ? 2 : 3;
  *(uint16_t*) (header + 2) = htons(type);
  *(uint32_t*) (header + 4) = htonl(len & 0x00ffffff);
  header[4] = flags;

  [output_ appendBytes: (const void*) header length: sizeof(header)];
}


- (void) putValue: (NSString*) value withKey: (NSString*) key {
  NSUInteger ckey_len = [key lengthOfBytesUsingEncoding: NSUTF8StringEncoding];
  NSUInteger cvalue_len =
      [value lengthOfBytesUsingEncoding: NSUTF8StringEncoding];

  uint16_t len_repr16;
  uint32_t len_repr32;

  if (version_ == kISpdyV2) {
    len_repr16 = htons(ckey_len);
    [pairs_ appendBytes: (const void*) &len_repr16 length: sizeof(len_repr16)];
  } else {
    len_repr32 = htonl(ckey_len);
    [pairs_ appendBytes: (const void*) &len_repr32 length: sizeof(len_repr32)];
  }
  [pairs_ appendBytes: [key cStringUsingEncoding: NSUTF8StringEncoding]
               length: ckey_len];

  if (version_ == kISpdyV2) {
    len_repr16 = htons(cvalue_len);
    [pairs_ appendBytes: (const void*) &len_repr16 length: sizeof(len_repr16)];
  } else {
    len_repr32 = htonl(cvalue_len);
    [pairs_ appendBytes: (const void*) &len_repr32 length: sizeof(len_repr32)];
  }
  [pairs_ appendBytes: [value cStringUsingEncoding: NSUTF8StringEncoding]
               length: cvalue_len];
  pair_count_++;
}


- (void) putKVs: (void (^)()) block {
  // Truncate pairs
  // Put some space for length ahead of time, we'll change it later
  [pairs_ setLength: version_ == kISpdyV2 ? 2 : 4];
  pair_count_ = 0;

  // Execute block
  block();

  // Now insert a proper length
  uint8_t* data = [pairs_ mutableBytes];
  if (version_ == kISpdyV2)
    *(uint16_t*) data = htons(pair_count_);
  else
    *(uint32_t*) data = htonl(pair_count_);
  // And compress pairs
  BOOL ret = [comp_ deflate: pairs_];

  // NOTE: this assertion can't be caused by any user input,
  // if it happens - something terribly bad has happened to the
  // ispdy state.
  NSAssert(ret == YES, @"Deflate failed!");
}


- (void) synStream: (uint32_t) stream_id
          priority: (uint8_t) priority
            method: (NSString*) method
                to: (NSString*) url
           headers: (NSDictionary*) headers {
  [self putKVs: ^() {
    // Put system headers
    if (version_ == kISpdyV2) {
      [self putValue: @"https" withKey: @"scheme"];
      [self putValue: @"HTTP/1.1" withKey: @"version"];
      [self putValue: method withKey: @"method"];
      [self putValue: url withKey: @"url"];
    } else {
      [self putValue: @"https" withKey: @":scheme"];
      [self putValue: @"HTTP/1.1" withKey: @":version"];
      [self putValue: method withKey: @":method"];
      [self putValue: url withKey: @":path"];
    }

    [headers enumerateKeysAndObjectsUsingBlock: ^(NSString* key,
                                                  NSString* val,
                                                  BOOL* stop) {
      if (![key isKindOfClass: [NSString class]])
        key = [(id) key stringValue];
      if (![val isKindOfClass: [NSString class]])
        val = [(id) val stringValue];
      NSString* lckey = [key lowercaseString];

      // Skip protocol headers
      if (version_ == kISpdyV2) {
        if (![lckey isEqualToString: @"scheme"] &&
            ![lckey isEqualToString: @"version"] &&
            ![lckey isEqualToString: @"method"] &&
            ![lckey isEqualToString: @"url"]) {
          [self putValue: val withKey: lckey];
        }
      } else {
        if ([lckey isEqualToString: @"host"]) {
          [self putValue: val withKey: @":host"];
        } else if (![lckey isEqualToString: @":scheme"] &&
                   ![lckey isEqualToString: @":version"] &&
                   ![lckey isEqualToString: @":method"] &&
                   ![lckey isEqualToString: @":host"] &&
                   ![lckey isEqualToString: @":path"]) {
          [self putValue: val withKey: lckey];
        }
      }
    }];
  }];

  // Finally, write body
  uint8_t body[10];

  *(uint32_t*) body = htonl(stream_id & 0x7fffffff);
  *(uint32_t*) (body + 4) = 0;  // Associated stream_id

  // Priority and unused
  if (version_ == kISpdyV2)
    body[8] = (priority > 3 ? 3 : priority) << 6;
  else
    body[8] = (priority > 7 ? 7 : priority) << 5;

  body[9] = 0;

  [self controlHeader: kISpdySynStream
                flags: 0
               length: (uint32_t) (sizeof(body) + [[comp_ output] length])];
  [output_ appendBytes: (const void*) body length: sizeof(body)];
  [output_ appendData: [comp_ output]];
}


- (void) headers: (uint32_t) stream_id
     withHeaders: (NSDictionary*) headers {
  [self putKVs: ^() {
    [headers enumerateKeysAndObjectsUsingBlock: ^(NSString* key,
                                                  NSString* val,
                                                  BOOL* stop) {
      NSString* lckey = [key lowercaseString];

      [self putValue: val withKey: lckey];
    }];
  }];

  // Finally, write body
  uint8_t body[6];
  int body_size = version_ == kISpdyV2 ? 6 : 4;
  NSAssert(body_size <= (int) sizeof(body), @"HEADERS body OOB");

  *(uint32_t*) body = htonl(stream_id & 0x7fffffff);

  [self controlHeader: kISpdyHeaders
                flags: 0
               length: (uint32_t) (body_size + [[comp_ output] length])];
  [output_ appendBytes: (const void*) body length: body_size];
  [output_ appendData: [comp_ output]];
}


- (void) dataFrame: (uint32_t) stream_id
               fin: (BOOL) fin
          withData: (NSData*) data {
  NSUInteger len = [data length];
  uint8_t header[8];

  *(uint32_t*) header = htonl(stream_id & 0x7fffffff);
  *(uint32_t*) (header + 4) = htonl(len & 0x00ffffff);
  header[4] = fin == YES ? kISpdyFlagFin : 0;

  [output_ appendBytes: (const void*) header length: sizeof(header)];
  [output_ appendData: data];
}


- (void) rst: (uint32_t) stream_id code: (ISpdyRstCode) code {
  NSAssert(code <= 0xff, @"Incorrect RST code");

  uint8_t body[8];
  *(uint32_t*) body = htonl(stream_id & 0x7fffffff);
  *(uint32_t*) (body + 4) = htonl(code & 0x000000ff);

  [self controlHeader: kISpdyRstStream flags: 0 length: sizeof(body)];
  [output_ appendBytes: (const void*) body length: sizeof(body)];
}


- (void) initialWindow: (uint32_t) window {
  // V2 has endianness issue, don't support it
  NSAssert(version_ != kISpdyV2, @"Settings frame unsupported in V2");

  uint8_t body[12];

  // Number of settings pairs
  *(uint32_t*) body = htonl(1);

  // Id and flag
  *(uint32_t*) (body + 4) = htonl(kISpdySettingInitialWindowSize & 0x00ffffff);
  body[4] = 0;

  // Value
  *(uint32_t*) (body + 8) = htonl(window);

  [self controlHeader: kISpdySettings flags: 0 length: sizeof(body)];
  [output_ appendBytes: (const void*) body length: sizeof(body)];
}


- (void) windowUpdate: (uint32_t) stream_id update: (uint32_t) update {
  uint8_t body[8];
  *(uint32_t*) body = htonl(stream_id & 0x7fffffff);
  *(uint32_t*) (body + 4) = htonl(update & 0x7fffffff);

  [self controlHeader: kISpdyWindowUpdate flags: 0 length: sizeof(body)];
  [output_ appendBytes: (const void*) body length: sizeof(body)];
}


- (void) ping: (uint32_t) ping_id {
  uint32_t body;
  body = htonl(ping_id);
  [self controlHeader: kISpdyPing flags: 0 length: sizeof(body)];
  [output_ appendBytes: (const void*) &body length: sizeof(body)];
}


- (void) goaway: (uint32_t) stream_id status: (ISpdyGoawayStatus) status {
  uint8_t body[8];
  *(uint32_t*) body = htonl(stream_id & 0x7fffffff);
  *(uint32_t*) (body + 4) = htonl(status);
  int size = sizeof(body);

  if (version_ == kISpdyV2)
    size -= 4;
  [self controlHeader: kISpdyGoaway flags: 0 length: size];
  [output_ appendBytes: (const void*) &body length: size];
}

@end
