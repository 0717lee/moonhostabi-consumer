///|
fn contract_json_string(value : String) -> String {
  Json::string(value).stringify()
}

///|
fn function_signature(function : @model.AbiFunction) -> String {
  let params = function.params.map(fn(value) { value.stable_text() }).join(",")
  let results = function.results
    .map(fn(value) { value.stable_text() })
    .join(",")
  "(\{params})->(\{results})"
}

///|
fn is_make_closure(function : @model.AbiFunction) -> Bool {
  function.module_name == Some("moonbit:ffi") && function.name == "make_closure"
}
