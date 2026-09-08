(module
  (rec
    (type $Bag (;0;) (array (mut (ref null $Node))))
    (type $Node (;1;) (struct (field (mut (ref null $Node))) (field (ref null $Bag)) (field (mut i16))))
  )
  (type $Private (;2;) (struct (field i32)))
  (type (;3;) (func (result (ref null $Node))))
  (export "node-null" (func $node-null))
  (func $node-null (;0;) (type 3) (result (ref null $Node))
    ref.null $Node
  )
)
