# spdy-ios

spdy-ios

## Instructions

WIP
```
svn co http://gyp.googlecode.com/svn/trunk build/gyp
CC=`xcrun -find clang` CXX=`xcrun -find clang++` ./gyp_ispdy -f ninja
ninja -C out/Debug && ./out/Debug/test-runner
```
