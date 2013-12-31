# ISpdy

SPDY client for OS X and iOS.

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

## Features

* Low-latency tuning options
* Low-memory footprint
* Push stream support
* Basic priority scheduling for outgoing data
* Trailing headers
* Ping support
* Transparent decompression of response using Content-Encoding header
* Background socket reclaim detection and support on iOS
* VoIP mode support on iOS

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
* `./out/Release/iphoneos/ISpdy.framework`
* `./out/Release/macosx/ISpdy.framework`

## Running tests

Preparing:
```
svn co http://gyp.googlecode.com/svn/trunk build/gyp
```

Running (with the help of xcode):
```
git submodule update --init
make test
```

#### LICENSE

The MIT License (MIT)

Copyright (c) 2013 Voxer

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

[0]: http://martine.github.io/ninja/
[1]: http://www.gnu.org/software/make/
[2]: https://developer.apple.com/xcode/
[3]: https://github.com/indutny/node-spdy
[4]: https://github.com/Voxer/ispdy/blob/master/include/ispdy.h
