(module $moonhostabi-fixtures/breaking_v1@0.1.0
  (type (;0;) (func (param i32 i32) (result i32)))
  (memory (;0;) 1)
  (export "add" (func 0))
  (func (;0;) (type 0) (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
  )
  (@producers
    (language "MoonBit" "")
    (processed-by "moonc" "v0.10.11+6ff76a5f9")
  )
)
