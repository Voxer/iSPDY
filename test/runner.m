#import <assert.h>
#import <Foundation/Foundation.h>
#import <ispdy.h>

void basic_test() {
  ISpdy* c = [[ISpdy alloc] init: kISpdyV2];

  BOOL r = [c connect:@"api.hackerdns.com" port:3232 secure: NO];
  assert(r == YES);

  ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];
  [c send: req];
  [req writeString: @"hello world"];
  [req end];

  [[NSRunLoop currentRunLoop] run];
}

int main() {
  @autoreleasepool {
    NSLog(@"Running tests...");

    basic_test();
  }

  return 0;
}
