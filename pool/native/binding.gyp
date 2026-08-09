{
  "targets": [
    {
      "target_name": "wamrandomx",
      "sources": [ "src/randomx_binding.cc" ],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")",
        "<!(node -e \"console.log(process.env.RANDOMX_INCLUDE || '/usr/local/include')\")"
      ],
      "libraries": [
        "<!(node -e \"console.log(process.env.RANDOMX_LIB || '/usr/local/lib/librandomx.a')\")"
      ],
      "cflags!": [ "-fno-exceptions" ],
      "cflags_cc!": [ "-fno-exceptions" ],
      "cflags_cc": [ "-std=c++17", "-O2" ],
      "defines": [ "NAPI_DISABLE_CPP_EXCEPTIONS" ],
      "conditions": [
        [ "OS==\"mac\"", {
          "xcode_settings": {
            "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
            "CLANG_CXX_LIBRARY": "libc++",
            "MACOSX_DEPLOYMENT_TARGET": "10.15"
          }
        }],
        [ "OS==\"linux\"", {
          "libraries": [ "-lpthread" ]
        }]
      ]
    }
  ]
}
