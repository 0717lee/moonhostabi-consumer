///|
pub struct Node {
  value : Int
  mut next : Node?
}

///|
#export_name("new_node")
pub fn new_node(value : Int) -> Node {
  let node : Node = { value, next: None }
  node.next = None
  node
}

///|
#export_name("node_value")
pub fn node_value(node : Node) -> Int {
  node.value
}
