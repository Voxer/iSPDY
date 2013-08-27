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
    "include_dirs": [ "include" ],
    "sources": [
      "src/ispdy.m",
      "src/framer.m",
      "src/compressor.m",
    ],
  }, {
    "target_name": "test-runner",
    "type": "executable",
    "dependencies": [ "ispdy" ],
    "link_settings": {
      "libraries": [
        "-lobjc",
        "-framework Foundation",
        "-framework CoreFoundation",
      ],
    },
    "sources": [
      "test/runner.m",
    ],
  }]
}
