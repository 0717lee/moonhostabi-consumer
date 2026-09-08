(module $moonhostabi-fixtures/externref@0.1.0
  (type (;0;) (func (param externref) (result externref)))
  (type (;1;) (func (param i32 i32) (result i32)))
  (import "host" "echo" (func (;0;) (type 0)))
  (memory (;0;) 1)
  (export "add" (func 1))
  (export "roundtrip" (func 2))
  (func (;1;) (type 1) (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
  )
  (func (;2;) (type 0) (param externref) (result externref)
    local.get 0
    call 3
  )
  (func (;3;) (type 0) (param externref) (result externref)
    local.get 0
    call 0
  )
  (@producers
    (language "MoonBit" "")
    (processed-by "moonc" "v0.10.11+6ff76a5f9")
  )
)
