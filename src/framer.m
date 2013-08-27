#import <Foundation/Foundation.h>

#import "framer.h"
#import "ispdy.h"  // iSpdyVersion
#import "compressor.h"  // iSpdyCompressor

typedef enum {
  SYN_STREAM = 1,
  SYN_REPLY = 2,
} iSpdyFrameType;

@implementation iSpdyFramer

- (id) init: (iSpdyVersion) version {
  NSAssert(version == iSpdyV2, @"Only spdyv2 is supported now");
  self = [super init];
  if (!self)
    return self;
  version_ = version;
  comp_ = [[iSpdyCompressor alloc] init: version];
  pairs_ = [[NSMutableData alloc] initWithCapacity: 4096];
  output_ = [[NSMutableData alloc] initWithCapacity: 4096];
  return self;
}

- (void) dealloc {
  [comp_ release];
  [pairs_ release];
  [output_ release];

  [super dealloc];
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
  const uint8_t header[] = {
    0x80, version_ == iSpdyV2 ? 2 : 3, (type >> 8) & 0xff, (type & 0xff),
    flags, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff
  };
  [output_ appendBytes: (const void*) header length: sizeof(header)];
}


- (void) putValue: (NSString*) value withKey: (NSString*) key {
  NSUInteger ckey_len = [key lengthOfBytesUsingEncoding: NSUTF8StringEncoding];
  NSUInteger cvalue_len =
      [value lengthOfBytesUsingEncoding: NSUTF8StringEncoding];

  uint8_t ckey_repr[] = { (ckey_len >> 8) & 0xff, ckey_len & 0xff };
  [pairs_ appendBytes: (const void*) ckey_repr length: sizeof(ckey_repr)];
  [pairs_ appendBytes: [key cStringUsingEncoding: NSUTF8StringEncoding]
               length: ckey_len];

  uint8_t cvalue_repr[] = { (cvalue_len >> 8) & 0xff, cvalue_len & 0xff };
  [pairs_ appendBytes: (const void*) cvalue_repr length: sizeof(cvalue_repr)];
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
    [lckey release];
  }];

  // Now insert a proper length
  uint8_t* data = [pairs_ mutableBytes];
  data[0] = (count >> 8) & 0xff;
  data[1] = count & 0xff;

  // And compress pairs
  [comp_ deflate: pairs_];

  // Finally, write body
  uint8_t body[] = {
    (stream_id >> 24) & 0x7f,
    (stream_id >> 16) & 0xff,
    (stream_id >> 8) & 0xff,
    stream_id & 0xff,
    0, 0, 0, 0, // Associated stream id
    (priority & 0x3) << 6, 0 // Priority and unused
  };

  [self controlHeader: SYN_STREAM
                flags: 0
               length: sizeof(body) + [[comp_ output] length]];
  [output_ appendBytes: (const void*) body length: sizeof(body)];
  [output_ appendData: [comp_ output]];
}


- (void) dataFrame: (uint32_t) stream_id
               fin: (BOOL) fin
          withData: (NSData*) data {
  NSUInteger len = [data length];
  const uint8_t header[] = {
    (stream_id >> 24) & 0x7f, (stream_id >> 16) & 0xff,
    (stream_id >> 8) & 0xff, stream_id & 0xff,
    fin == YES ? 1 : 0, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff
  };
  [output_ appendBytes: (const void*) header length: sizeof(header)];
  [output_ appendData: data];
}

@end
