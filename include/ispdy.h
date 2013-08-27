#import <CoreFoundation/CFStream.h>
#import <Foundation/Foundation.h>

// Forward-declarations
@class iSpdy;
@class iSpdyFramer;

typedef enum {
  iSpdyV2,
  iSpdyV3
} iSpdyVersion;

typedef enum {
  iSpdyConnectionEnd
} iSpdyErrorCode;

@interface iSpdyRequest : NSObject

@property uint32_t stream_id;
@property (retain) iSpdy* connection;
@property (retain) NSString* method;
@property (retain) NSString* url;
@property (retain) NSDictionary* headers;

- (id) init: (NSString*) method url: (NSString*) url;
- (void) writeData: (NSData*) data;
- (void) writeString: (NSString*) data;
- (void) end;

@end

@protocol iSpdyDelegate

- (void) connection: (iSpdy*) conn handleError: (NSError*) err;
- (void) request: (iSpdyRequest*) req handleError: (NSError*) err;
- (void) request: (iSpdyRequest*) req onInput: (NSData*) input;

@end

@interface iSpdy : NSObject <NSStreamDelegate> {
  iSpdyVersion version_;
  NSInputStream* in_stream_;
  NSOutputStream* out_stream_;
  iSpdyFramer* framer_;
  uint32_t stream_id_;

  // Dictionary of all streams
  NSMutableDictionary* streams_;

  // Connection write buffer
  NSMutableData* buffer_;
}

@property (retain) id <iSpdyDelegate> delegate;

- (id) init: (iSpdyVersion) version;
- (BOOL) connect: (NSString*) host port: (UInt32) port;
- (void) writeRaw: (NSData*) data;
- (void) handleError: (NSError*) err;

- (void) send: (iSpdyRequest*) request;
- (void) writeData: (NSData*) data to: (iSpdyRequest*) request;
- (void) end: (iSpdyRequest*) request;

@end
