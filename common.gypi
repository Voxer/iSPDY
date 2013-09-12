{
  'variables': {
    'visibility%': 'hidden',         # V8's visibility setting
    'target_arch%': 'ia32',          # set v8's target architecture
    'host_arch%': 'ia32',            # set v8's host architecture
    'library%': 'static_library',    # allow override to 'shared_library' for DLL/.so builds
    'component%': 'static_library',  # NB. these names match with what V8 expects
    'msvs_multi_core_compile': '0',  # we do enable multicore compiles, but not using the V8 way
    'gcc_version%': 'unknown',
    'clang%': 1,
  },

  'target_defaults': {
    'default_configuration': 'Debug',
    'configurations': {
      'Debug': {
        'defines': [ 'DEBUG', '_DEBUG' ],
        'cflags': [ '-g', '-O0', '-fwrapv' ],
        'xcode_settings': {
          'GCC_OPTIMIZATION_LEVEL': '0'
        },
      },
      'Release': {
        'defines': [ 'NDEBUG' ],
      }
    },
    'xcode_settings': {
      'SDKROOT': '<(sdk)',
      'GCC_VERSION': 'com.apple.compilers.llvm.clang.1_0',
      'GCC_WARN_ABOUT_MISSING_NEWLINE': 'YES',  # -Wnewline-eof
      'PREBINDING': 'NO',                       # No -Wl,-prebind
      'OTHER_CFLAGS': [
        '-fstrict-aliasing',
        '-F<(sdk_path)/Developer/Library/Frameworks',
        '-F<(sdk_dev_path)/Library/Frameworks',
      ],
      'WARNING_CFLAGS': [
        '-Wall',
        '-Wendif-labels',
        '-W',
        '-Wno-unused-parameter',
        '-Wundeclared-selector',
      ],
    },
    'library_paths': [
      '<(sdk_path)/Developer/Library/Frameworks',
      '<(sdk_dev_path)/Library/Frameworks',
    ],
    'conditions': [
      ['sdk == "macosx"', {
        'conditions': [
          ['target_arch=="ia32"', {
            'xcode_settings': {'ARCHS': ['i386']},
          }],
          ['target_arch=="x64"', {
            'xcode_settings': {'ARCHS': ['x86_64']},
          }],
        ],
      }],
      ['sdk.startswith("iphoneos")', {
        'xcode_settings': {'ARCHS': ['armv7', 'armv7s', 'arm64']},
      }],
      ['sdk.startswith("iphonesimulator")', {
        'xcode_settings': {'ARCHS': ['x86_64', 'i386']},
      }],
    ],
  },
}
