#import <Foundation/Foundation.h>

// Possible SPDY Protocol RST codes
typedef enum {
  kISpdyRstProtocolError = 0x1,
  kISpdyRstInvalidStream = 0x2,
  kISpdyRstRefusedStream = 0x3,
  kISpdyRstUnsupportedVersion = 0x4,
  kISpdyRstCancel = 0x5,
  kISpdyRstInternalError = 0x6,
  kISpdyRstFlowControlError = 0x7,
  kISpdyRstMax = 0xffffffff
} ISpdyRstCode;

typedef enum {
  kISpdySettingUpBandwidth = 0x1,
  kISpdySettingDownBandwidth = 0x2,
  kISpdySettingRTT = 0x3,
  kISpdySettingMaxConcurrentStreams = 0x4,
  kISpdySettingCurrentCWND = 0x5,
  kISpdySettingDownloadRetransRate = 0x6,
  kISpdySettingInitialWindowSize = 0x7,
  kISpdySettingClientCertificateVectorSize = 0x8,
  kISpdySettingMax = 0x00ffffff
} ISpdySetting;

typedef enum {
  kISpdySettingFlagPersist = 0x1,
  kISpdySettingFlagPersisted = 0x2
} kISpdySettingFlag;

typedef enum {
  kISpdyFlagFin = 0x1,
} ISpdyFlags;

// SPDY Frame types
typedef enum {
  kISpdySynStream = 1,
  kISpdySynReply = 2,
  kISpdyRstStream = 3,
  kISpdySettings = 4,
  kISpdyNoop = 5,
  kISpdyPing = 6,
  kISpdyGoaway = 7,
  kISpdyHeaders = 8,
  kISpdyWindowUpdate = 9,
  kISpdyCredential = 10,
  kISpdyData = 0xffff
} ISpdyFrameType;

@protocol ISpdyParserDelegate
- (void) handleFrame: (ISpdyFrameType) type
                body: (id) body
              is_fin: (BOOL) is_fin
           forStream: (uint32_t) stream_id;
- (void) handleParseError;
@end

@interface ISpdySettings : NSObject

@property int32_t initial_window;

@end
