// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "0717lee/moonhostabi"

version = "0.1.1"

readme = "README.md"

repository = "https://github.com/0717lee/moonhostabi"

license = "Apache-2.0"

keywords = [ "wasm-gc", "abi", "ffi", "host", "compatibility" ]

preferred_target = "native"

description = "Artifact-first MoonBit Wasm-GC Host ABI lock, adapter, and validation toolchain"

import {
  "Milky2018/wasm_core@0.14.0",
  "moonbitlang/x@0.5.1",
}
