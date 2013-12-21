{
  "targets": [{
    "target_name": "ispdy",
    "type": "<(library)",
    "direct_dependent_settings": {
      "include_dirs": [ "include" ],
    },
    "include_dirs": [
      "include",
      ".",
    ],
    "sources": [
      "src/ispdy.m",
      "src/compressor.m",
      "src/framer.m",
      "src/loop.m",
      "src/parser.m",
      "src/request.m",
      "src/scheduler.m",
    ],
    "link_settings": {
      "libraries": [
        "CoreServices.framework",
        "Security.framework",
      ],
    },
    "xcode_settings": {
      "CLANG_ENABLE_OBJC_ARC": "YES",
    },
    "conditions": [
      ["library == 'static_library'", {
        "standalone_static_library": 1,
      }],
      ["library == 'shared_library' and GENERATOR == 'xcode'", {
        "mac_bundle": 1,
        "mac_framework_headers": [
          "include/ispdy.h",
        ],
      }]
    ],
  }]
}
