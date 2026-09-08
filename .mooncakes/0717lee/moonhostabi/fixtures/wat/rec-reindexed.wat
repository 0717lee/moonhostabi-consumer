(module
  (rec
    (type $Bag (array (mut (ref null $Node))))
    (type $Node (struct
      (field $next (mut (ref null $Node)))
      (field $bag (ref null $Bag))
      (field $tag (mut i16))
    ))
  )
  (type $Private (struct (field i32)))
  (func $node-null (result (ref null $Node))
    ref.null $Node)
  (export "node-null" (func $node-null))
)
