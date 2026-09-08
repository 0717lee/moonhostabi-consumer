(module $moonhostabi-fixtures/recursive@0.1.0
  (type (;0;) (struct (field i32) (field (mut (ref null 0)))))
  (type (;1;) (func (param (ref 0)) (result i32)))
  (type (;2;) (func (param i32) (result (ref 0))))
  (memory (;0;) 1)
  (export "node_value" (func 0))
  (export "new_node" (func 1))
  (func (;0;) (type 1) (param (ref 0)) (result i32)
    local.get 0
    struct.get 0 0
  )
  (func (;1;) (type 2) (param i32) (result (ref 0))
    (local (ref 0))
    local.get 0
    ref.null none
    struct.new 0
    local.tee 1
    ref.null none
    struct.set 0 1
    local.get 1
  )
  (@producers
    (language "MoonBit" "")
    (processed-by "moonc" "v0.10.11+6ff76a5f9")
  )
)
