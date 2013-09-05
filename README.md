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

  ISpdyRequest* req = [[ISpdyRequest alloc] init: @"POST" url: @"/"];
  [conn send: req];

  [req writeString: @"omg this is spdy body"];
  [req writeString: @"and another chunk"];
  [req end];
}
```

## Bulding for iOS

Preparing:
```
svn co http://gyp.googlecode.com/svn/trunk build/gyp
```

Building:
```
./gyp_ispdy -f xcode -Dsdk=iosphone
xcodebuild -configuration Release
```

The result will be located at: `./build/Release-iphoneos/libispdy-bundled.a`.

NOTE: you'll need to add `./deps/zlib/build/Release/libchrome_zlib.a` to the
list of libraries, as `libispdy.a` depends on it.

## Running tests

Preparing:
```
svn co http://gyp.googlecode.com/svn/trunk build/gyp
git clone git@github.com:allending/Kiwi.git deps/Kiwi/Kiwi
cd test && npm install && cd ..
node test/server.js & # To start SPDY server
```

Building and running test suite with [ninja][0]:
```
./gyp_ispdy -f ninja test
ninja -C out/Debug && ./out/Debug/test-runner
```

Building with [make][1]:
```
./gyp_ispdy -f make
make -C out && ./out/Debug/test-runner
```

Building with [Xcode][2]:
```
./gyp_ispdy -f xcode
cd ./test && xcodebuild && ./build/Debug/test-runner
```

[0]: http://martine.github.io/ninja/
[1]: http://www.gnu.org/software/make/
[2]: https://developer.apple.com/xcode/
