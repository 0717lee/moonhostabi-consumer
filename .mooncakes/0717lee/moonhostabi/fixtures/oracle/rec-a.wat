(module
  (type $Private (;0;) (struct (field i32)))
  (rec
    (type $Node (;1;) (struct (field (mut (ref null $Node))) (field (ref null $Bag)) (field (mut i16))))
    (type $Bag (;2;) (array (mut (ref null $Node))))
  )
  (type (;3;) (func (result (ref null $Node))))
  (export "node-null" (func $node-null))
  (func $node-null (;0;) (type 3) (result (ref null $Node))
    ref.null $Node
  )
)
