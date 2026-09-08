///|
fn contract_json_string(value : String) -> String {
  Json::string(value).stringify()
}

///|
pub fn encode_contract(contract : Contract) -> String {
  let entries = contract.bindings.map(fn(binding) {
    "\{contract_json_string(binding.path)}:\{contract_json_string(binding.semantic_name)}"
  })
  "{\"schemaVersion\":2,\"abiSha256\":\{contract_json_string(contract.abi_sha256)},\"externrefs\":{\{entries.join(",")}},\"imports\":[]}\n"
}
