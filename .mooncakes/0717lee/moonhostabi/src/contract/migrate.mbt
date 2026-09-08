///|
priv struct LegacySettings {
  externref_generic : String?
}

///|
fn legacy_function_signature(function : @model.AbiFunction) -> String {
  let params = function.params.map(fn(value) { value.stable_text() }).join(",")
  let results = function.results
    .map(fn(value) { value.stable_text() })
    .join(",")
  "(\{params})->(\{results})"
}

///|
fn legacy_is_make_closure(function : @model.AbiFunction) -> Bool {
  function.module_name == Some("moonbit:ffi") && function.name == "make_closure"
}

///|
fn legacy_unresolved_locations(
  function : @model.AbiFunction,
  settings : LegacySettings,
) -> Array[String] {
  if settings.externref_generic is Some(_) {
    return []
  }
  let locations : Array[String] = []
  for index, value in function.params {
    if value == @model.ExternRef {
      locations.push("params[\{index}]")
    }
  }
  for index, value in function.results {
    if value == @model.ExternRef {
      locations.push("results[\{index}]")
    }
  }
  locations
}

///|
fn encode_legacy_import(
  function : @model.AbiFunction,
  settings : LegacySettings,
) -> String {
  let implementation = if legacy_is_make_closure(function) {
    "generated"
  } else {
    "required"
  }
  let unresolved = legacy_unresolved_locations(function, settings)
  "{\"module\":\{contract_json_string(function.module_name.unwrap_or(""))},\"name\":\{contract_json_string(function.name)},\"signature\":\{contract_json_string(legacy_function_signature(function))},\"implementation\":\{contract_json_string(implementation)},\"unresolvedSemanticNames\":[\{unresolved.map(fn(value) { contract_json_string(value) }).join(",")}]}"
}

///|
fn encode_legacy_contract(
  abi : @model.HostAbi,
  settings : LegacySettings,
) -> String {
  let fingerprint = @lockfile.host_abi_sha256(abi)
  let generic = match settings.externref_generic {
    Some(name) => contract_json_string(name)
    None => "null"
  }
  let imports = @model.sort_abi_functions(abi.imports)
  "{\"schemaVersion\":1,\"abiSha256\":\{contract_json_string(fingerprint)},\"externrefGeneric\":\{generic},\"imports\":[\{imports.map(fn(function) { encode_legacy_import(function, settings) }).join(",")}]}\n"
}

///|
pub fn migrate_v1_contract(
  abi : @model.HostAbi,
  text : String,
) -> Contract raise ContractError {
  let object = require_contract_object(parse_contract_json(text))
  require_keys(
    object,
    ["schemaVersion", "abiSha256", "externrefGeneric", "imports"],
    "contract",
  )
  if contract_version(object) != 1 {
    raise UnsupportedContractVersion
  }
  let canonical = @lockfile.canonicalize_host_abi(abi)
  validate_abi_fingerprint(object, canonical)
  let externref_generic : String? = match
    contract_value(object, "externrefGeneric", "contract") {
    Null => None
    String(name) => {
      if !is_safe_typescript_identifier(name) {
        raise UnsafeExternrefAlias("*")
      }
      if conflicts_with_generated_typescript(name) {
        raise ConflictingExternrefAlias("*")
      }
      Some(name)
    }
    _ => invalid_shape("contract.externrefGeneric: expected string or null")
  }
  let settings = LegacySettings::{ externref_generic, }
  guard contract_value(object, "imports", "contract") is Array(imports) else {
    return invalid_shape("contract.imports: expected array")
  }
  let expected = @model.sort_abi_functions(canonical.imports)
  if imports.length() != expected.length() {
    raise InvalidLegacyImport("contract.imports")
  }
  for index, value in imports {
    let path = "contract.imports[\{index}]"
    guard value is Object(import_object) else {
      return invalid_shape("\{path}: expected object")
    }
    require_keys(
      import_object,
      [
        "module", "name", "signature", "implementation", "unresolvedSemanticNames",
      ],
      path,
    )
    let function = expected[index]
    let implementation = if legacy_is_make_closure(function) {
      "generated"
    } else {
      "required"
    }
    if contract_string(import_object, "module", path) !=
      function.module_name.unwrap_or("") ||
      contract_string(import_object, "name", path) != function.name ||
      contract_string(import_object, "signature", path) !=
      legacy_function_signature(function) ||
      contract_string(import_object, "implementation", path) != implementation ||
      contract_strings(
        contract_value(import_object, "unresolvedSemanticNames", path),
        "\{path}.unresolvedSemanticNames",
      ) !=
      legacy_unresolved_locations(function, settings) {
      raise InvalidLegacyImport(path)
    }
  }
  if encode_legacy_contract(canonical, settings) != text {
    raise NonCanonicalContract
  }
  let paths = expected_externref_paths(canonical)
  let names : Array[String] = []
  for index, _ in paths {
    names.push(externref_generic.unwrap_or("TExtern\{index}"))
  }
  make_contract(canonical, names)
}
