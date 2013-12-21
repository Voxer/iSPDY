# spdy-ios

spdy-ios

## Usage example

```objc
#import <ispdy.h>

int main() {
  ISpdy* conn = [[ISpdy alloc] init: kISpdyV3
                               host: @"voxer.com"
                               port: 443
                             secure: YES];

  [conn connect];

  ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];
  [conn send: req];

  [req writeString: @"omg this is spdy body"];
  [req writeString: @"and another chunk"];
  [req end];

  [conn closeSoon: 0.0];
}
```

For more info - please read the [include file][4] it is quite informative and
documented.

## NPN

Note that ispdy doesn't support neither NPN, nor ALPN, because doing this will
require us bundling a last version of statically built openssl, which is quite
bad for the resulting binary size (and rather complicated too).

However, it works perfectly with [node-spdy][3]'s `plain` mode, in which it
autodetects the incoming protocol by looking at the incoming data, instead of
relying on NPN/ALPN.

## AFNetworking support

...Not yet, but in future plans!

## Bulding

Preparing:
```
svn co http://gyp.googlecode.com/svn/trunk build/gyp
```

Building:
```
make
```

The results will be located at:

* `./out/Release/libispdy.a` static library for both iphoneos and
  iphonesimulator
* `./out/Release/libispdy-macosx.a` static library for macosx
* `./out/Release/ISpdy-iphoneos.framework`
* `./out/Release/ISpdy-macosx.framework`

## Running tests

Preparing:
```
svn co http://gyp.googlecode.com/svn/trunk build/gyp
```

Running (with the help of xcode):
```
make test
```

[0]: http://martine.github.io/ninja/
[1]: http://www.gnu.org/software/make/
[2]: https://developer.apple.com/xcode/
[3]: https://github.com/indutny/node-spdy
[4]: https://github.com/Voxer/ispdy/blob/master/include/ispdy.h
