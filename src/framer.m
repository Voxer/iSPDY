#import <Foundation/Foundation.h>
#import <arpa/inet.h>  // htonl

#import "framer.h"  // ISpdyFramer
#import "ispdy.h"  // ISpdyVersion
#import "compressor.h"  // ISpdyCompressor

@implementation ISpdyFramer

- (id) init: (ISpdyVersion) version compressor: (ISpdyCompressor*) comp {
  NSAssert(version == kISpdyV2, @"Only spdyv2 is supported now");

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

  uint16_t ckey_repr = htons(ckey_len);
  [pairs_ appendBytes: (const void*) &ckey_repr length: sizeof(ckey_repr)];
  [pairs_ appendBytes: [key cStringUsingEncoding: NSUTF8StringEncoding]
               length: ckey_len];

  uint16_t cvalue_repr = htons(cvalue_len);
  [pairs_ appendBytes: (const void*) &cvalue_repr length: sizeof(cvalue_repr)];
  [pairs_ appendBytes: [value cStringUsingEncoding: NSUTF8StringEncoding]
               length: cvalue_len];
}


- (void) synStream: (uint32_t) stream_id
          priority: (uint8_t) priority
            method: (NSString*) method
                to: (NSString*) url
           headers: (NSDictionary*) headers {
  // Truncate pairs
  // Put some space for length ahead of time, we'll change it later
  [pairs_ setLength: 2];

  // Put system headers
  __block NSInteger count = 4;
  [self putValue: @"https" withKey: @"scheme"];
  [self putValue: @"HTTP/1.1" withKey: @"version"];
  [self putValue: method withKey: @"method"];
  [self putValue: url withKey: @"url"];

  [headers enumerateKeysAndObjectsUsingBlock: ^(NSString* key,
                                                NSString* val,
                                                BOOL* stop) {
    NSString* lckey = [key lowercaseString];
    if (![lckey isEqualToString: @"scheme"] &&
        ![lckey isEqualToString: @"version"] &&
        ![lckey isEqualToString: @"method"] &&
        ![lckey isEqualToString: @"url"]) {
      [self putValue: val withKey: lckey];
      count++;
    }
  }];

  // Now insert a proper length
  uint8_t* data = [pairs_ mutableBytes];
  *(uint16_t*) data = htons(count);

  // And compress pairs
  [comp_ deflate: pairs_];

  // Finally, write body
  uint8_t body[10];

  *(uint32_t*) body = htonl(stream_id & 0x7fffffff);
  *(uint32_t*) (body + 4) = 0;  // Associated stream_id

  // Priority and unused
  body[8] = (priority & 0x3) << 6;
  body[9] = 0;

  [self controlHeader: kISpdySynStream
                flags: 0
               length: sizeof(body) + [[comp_ output] length]];
  [output_ appendBytes: (const void*) body length: sizeof(body)];
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

@end
