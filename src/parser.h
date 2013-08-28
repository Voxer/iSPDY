#import <Foundation/Foundation.h>
#import "ispdy.h"  // ISpdyVersion

@interface ISpdyParser : NSObject {
}

// Initialize framer with specific protocol version
- (id) init: (ISpdyVersion) version;

@end
