# spdy-ios

spdy-ios

## Instructions

WIP
```
svn co http://gyp.googlecode.com/svn/trunk build/gyp
git clone git@github.com:allending/Kiwi.git deps/Kiwi/Kiwi
CC=`xcrun -find clang` CXX=`xcrun -find clang++` ./gyp_ispdy -f ninja
ninja -C out/Debug && ./out/Debug/test-runner
```
