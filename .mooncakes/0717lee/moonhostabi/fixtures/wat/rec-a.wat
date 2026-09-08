(module
  (type $Private (struct (field i32)))
  (rec
    (type $Node (struct
      (field $next (mut (ref null $Node)))
      (field $bag (ref null $Bag))
      (field $tag (mut i16))
    ))
    (type $Bag (array (mut (ref null $Node))))
  )
  (func $node-null (result (ref null $Node))
    ref.null $Node)
  (export "node-null" (func $node-null))
)
