///|
const MAX_CONTRACT_LENGTH : Int = 1024 * 1024

///|
fn[T] invalid_shape(message : String) -> T raise ContractError {
  raise InvalidContractShape(message)
}

///|
fn parse_contract_json(text : String) -> Json raise ContractError {
  if @encoding.encode(@encoding.UTF8, text).length() > MAX_CONTRACT_LENGTH {
    raise ContractInputTooLarge
  }
  @json.parse(text) catch {
    _ => raise InvalidContractJson
  }
}

///|
fn require_contract_object(
  root : Json,
) -> Map[String, Json] raise ContractError {
  match root {
    Object(object) => object
    _ => invalid_shape("contract: expected object")
  }
}

///|
fn require_keys(
  object : Map[String, Json],
  keys : Array[String],
  path : String,
) -> Unit raise ContractError {
  if object.length() != keys.length() {
    invalid_shape("\{path}: unexpected or missing fields")
  }
  for key in keys {
    if object.get(key) is None {
      invalid_shape("\{path}.\{key}: required field is missing")
    }
  }
}

///|
fn contract_value(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Json raise ContractError {
  match object.get(key) {
    Some(value) => value
    None => invalid_shape("\{path}.\{key}: required field is missing")
  }
}

///|
fn contract_string(
  object : Map[String, Json],
  key : String,
  path : String,
) -> String raise ContractError {
  match contract_value(object, key, path) {
    String(value) => value
    _ => invalid_shape("\{path}.\{key}: expected string")
  }
}

///|
fn contract_strings(
  value : Json,
  path : String,
) -> Array[String] raise ContractError {
  guard value is Array(values) else {
    return invalid_shape("\{path}: expected string array")
  }
  let result : Array[String] = []
  for index, item in values {
    match item {
      String(text) => result.push(text)
      _ => invalid_shape("\{path}[\{index}]: expected string")
    }
  }
  result
}

///|
fn contract_version(object : Map[String, Json]) -> Int raise ContractError {
  guard contract_value(object, "schemaVersion", "contract")
    is Number(version, ..) else {
    return invalid_shape("contract.schemaVersion: expected integer")
  }
  if version == 1.0 {
    1
  } else if version == 2.0 {
    2
  } else {
    raise UnsupportedContractVersion
  }
}

///|
fn is_lower_hex_sha256(value : String) -> Bool {
  if value.length() != 64 {
    return false
  }
  for character in value {
    if !((character >= '0' && character <= '9') ||
      (character >= 'a' && character <= 'f')) {
      return false
    }
  }
  true
}

///|
fn validate_abi_fingerprint(
  object : Map[String, Json],
  abi : @model.HostAbi,
) -> Unit raise ContractError {
  let fingerprint = contract_string(object, "abiSha256", "contract")
  if !is_lower_hex_sha256(fingerprint) {
    raise InvalidAbiFingerprint
  }
  if fingerprint != @lockfile.host_abi_sha256(abi) {
    raise ContractAbiMismatch
  }
}

///|
fn decode_v2_contract(
  abi : @model.HostAbi,
  text : String,
) -> Contract raise ContractError {
  let object = require_contract_object(parse_contract_json(text))
  require_keys(
    object,
    ["schemaVersion", "abiSha256", "externrefs", "imports"],
    "contract",
  )
  if contract_version(object) != 2 {
    raise UnsupportedContractVersion
  }
  let canonical = @lockfile.canonicalize_host_abi(abi)
  validate_abi_fingerprint(object, canonical)
  guard contract_value(object, "externrefs", "contract") is Object(externrefs) else {
    return invalid_shape("contract.externrefs: expected object")
  }
  let paths = expected_externref_paths(canonical)
  let names : Array[String] = []
  for path in paths {
    match externrefs.get(path) {
      None => raise MissingExternrefPath(path)
      Some(String(name)) => names.push(name)
      Some(_) => invalid_shape("contract.externrefs[\{path}]: expected string")
    }
  }
  let extra_paths : Array[String] = []
  for path, _ in externrefs {
    if !paths.contains(path) {
      extra_paths.push(path)
    }
  }
  extra_paths.sort_by(fn(left, right) { left.compare(right) })
  if extra_paths is [first, ..] {
    raise UnexpectedExternrefPath(first)
  }
  guard contract_value(object, "imports", "contract") is Array(imports) else {
    return invalid_shape("contract.imports: expected array")
  }
  if !imports.is_empty() {
    invalid_shape("contract.imports: expected empty array")
  }
  let contract = make_contract(canonical, names)
  if encode_contract(contract) != text {
    raise NonCanonicalContract
  }
  contract
}

///|
/// Decode canonical v2 or explicitly migrate a canonical v1 contract.
pub fn decode_contract(
  abi : @model.HostAbi,
  text : String,
) -> Contract raise ContractError {
  let object = require_contract_object(parse_contract_json(text))
  match contract_version(object) {
    1 => migrate_v1_contract(abi, text)
    2 => decode_v2_contract(abi, text)
    _ => raise UnsupportedContractVersion
  }
}
