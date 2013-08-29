{
  "targets": [{
    "target_name": "ispdy",
    "type": "<(library)",
    "direct_dependent_settings": {
      "include_dirs": [ "include" ],
    },
    "dependencies": [
      "deps/zlib/zlib.gyp:zlib",
    ],
    "include_dirs": [
      "include",
      ".",
    ],
    "sources": [
      "src/ispdy.m",
      "src/compressor.m",
      "src/framer.m",
      "src/parser.m",
    ],
    "xcode_settings": {
      "CLANG_ENABLE_OBJC_ARC": "YES",
    }
  }]
}
