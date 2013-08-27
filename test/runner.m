#import <assert.h>
#import <Foundation/Foundation.h>
#import <ispdy.h>

void basic_test() {
  iSpdy* c = [[iSpdy alloc] init: iSpdyV2];

  BOOL r = [c connect:@"api.hackerdns.com" port:3232];
  assert(r == YES);

  iSpdyRequest* req = [[iSpdyRequest alloc] init: @"POST" url: @"/"];
  [c send: req];
  [req writeString: @"hello world"];
  [req end];

  [[NSRunLoop currentRunLoop] run];

  [c release];
}

int main() {
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  NSLog(@"Running tests...");

  basic_test();

  [pool release];
  return 0;
}
