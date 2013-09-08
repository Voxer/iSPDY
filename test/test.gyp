{
  "targets": [{
    "target_name": "test-runner",
    "type": "executable",
    "dependencies": [
      "../ispdy.gyp:ispdy",
      "../deps/Kiwi/kiwi.gyp:Kiwi",
    ],
    "include_dirs": [
      "../src",
    ],
    "link_settings": {
      "libraries": [
        "Foundation.framework",
        "CoreFoundation.framework",
      ],
    },
    "sources": [
      "runner.m",
    ],
    "xcode_settings": {
      "CLANG_ENABLE_OBJC_ARC": "YES",
    }
  }]
}
