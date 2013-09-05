{
  "targets": [{
    "target_name": "ispdy",
    "type": "<(library)",
    "standalone_static_library": 1,
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
      "src/loop.m",
      "src/parser.m",
    ],
    "xcode_settings": {
      "CLANG_ENABLE_OBJC_ARC": "YES",
    },
  }, {
    "target_name": "ispdy-bundled",
    "type": "none",
    "dependencies": [
      "ispdy",
      "deps/zlib/zlib.gyp:zlib",
    ],
    "conditions": [
      ["library == 'static_library'", {
        "actions": [
          {
            "action_name": "link_with_zlib",
            "conditions": [
              ["GENERATOR == 'xcode'", {
                "conditions": [["sdk.startswith('iphoneos')", {
                  "inputs": [
                    "<(PRODUCT_DIR)/libispdy.a",
                    "deps/zlib/build/<(CONFIGURATION_NAME)-iphoneos/libchrome_zlib.a",
                  ],
                }, {
                  "conditions": [["sdk.startswith('iphonesimulator')", {
                    "inputs": [
                      "<(PRODUCT_DIR)/libispdy.a",
                      "deps/zlib/build/<(CONFIGURATION_NAME)-iphonesimulator/libchrome_zlib.a",
                    ],
                  }, {
                    "inputs": [
                      "<(PRODUCT_DIR)/libispdy.a",
                      "deps/zlib/build/<(CONFIGURATION_NAME)/libchrome_zlib.a",
                    ],
                  }]],
                }]],
              }, {
                "inputs": [
                  "<(PRODUCT_DIR)/libispdy.a",
                  "<(PRODUCT_DIR)/libchrome_zlib.a",
                ],
              }],
            ],
            "outputs": [
              "<(PRODUCT_DIR)/libispdy-bundled.a",
            ],
            "action": [
              "libtool",
              "-static",
              "<@(_inputs)",
              "-o",
              "<@(_outputs)",
            ],
          },
        ],
      }],
    ],
  }]
}
