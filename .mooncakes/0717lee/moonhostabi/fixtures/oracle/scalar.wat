(module $moonhostabi-fixtures/scalar@0.1.0
  (type (;0;) (func (result i64)))
  (type (;1;) (func (param i32 i32) (result i32)))
  (memory (;0;) 1)
  (export "answer" (func 0))
  (export "add" (func 1))
  (func (;0;) (type 0) (result i64)
    i64.const 42
  )
  (func (;1;) (type 1) (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
  )
  (@producers
    (language "MoonBit" "")
    (processed-by "moonc" "v0.10.11+6ff76a5f9")
  )
)
