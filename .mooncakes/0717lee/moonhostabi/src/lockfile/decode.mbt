///|
pub(all) suberror LockfileError {
  InvalidLockfile(String)
} derive(Debug)

///|
pub impl Show for LockfileError with fn output(self, logger) {
  match self {
    InvalidLockfile(message) => logger.write_string(message)
  }
}

///|
const MAX_LOCKFILE_LENGTH : Int = 8 * 1024 * 1024

///|
fn[T] invalid_lockfile(message : String) -> T raise LockfileError {
  raise InvalidLockfile(message)
}

///|
fn require_keys(
  object : Map[String, Json],
  expected : Array[String],
  path : String,
) -> Unit raise LockfileError {
  if object.length() != expected.length() {
    invalid_lockfile("\{path}: unexpected or missing fields")
  }
  for key in expected {
    if object.get(key) is None {
      invalid_lockfile("\{path}.\{key}: required field is missing")
    }
  }
}

///|
fn required_value(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Json raise LockfileError {
  match object.get(key) {
    Some(value) => value
    None => invalid_lockfile("\{path}.\{key}: required field is missing")
  }
}

///|
fn required_string(
  object : Map[String, Json],
  key : String,
  path : String,
) -> String raise LockfileError {
  match required_value(object, key, path) {
    String(value) => value
    _ => invalid_lockfile("\{path}.\{key}: expected string")
  }
}

///|
fn required_bool(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Bool raise LockfileError {
  match required_value(object, key, path) {
    True => true
    False => false
    _ => invalid_lockfile("\{path}.\{key}: expected boolean")
  }
}

///|
fn required_array(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Array[Json] raise LockfileError {
  match required_value(object, key, path) {
    Array(values) => values
    _ => invalid_lockfile("\{path}.\{key}: expected array")
  }
}

///|
fn decode_value_type(
  text : String,
  path : String,
) -> @model.AbiValueType raise LockfileError {
  match text {
    "i32" => @model.I32
    "i64" => @model.I64
    "f32" => @model.F32
    "f64" => @model.F64
    "v128" => @model.V128
    "externref" => @model.ExternRef
    "funcref" => @model.FuncRef
    _ =>
      if text.strip_prefix("ref null ") is Some(type_id) {
        if type_id.is_empty() {
          invalid_lockfile("\{path}: empty typed reference")
        }
        @model.TypedRef(type_id.to_owned(), true)
      } else if text.strip_prefix("ref ") is Some(type_id) {
        if type_id.is_empty() {
          invalid_lockfile("\{path}: empty typed reference")
        }
        @model.TypedRef(type_id.to_owned(), false)
      } else if text.strip_prefix("unknown(") is Some(rest) &&
        rest.strip_suffix(")") is Some(source) {
        @model.Unknown(source.to_owned())
      } else {
        invalid_lockfile("\{path}: unsupported ABI value type '\{text}'")
      }
  }
}

///|
fn decode_value_types(
  values : Array[Json],
  path : String,
) -> Array[@model.AbiValueType] raise LockfileError {
  let decoded : Array[@model.AbiValueType] = []
  for index, value in values {
    match value {
      String(text) => decoded.push(decode_value_type(text, "\{path}[\{index}]"))
      _ => invalid_lockfile("\{path}[\{index}]: expected value-type string")
    }
  }
  decoded
}

///|
fn decode_function(
  value : Json,
  path : String,
  expect_import : Bool,
) -> @model.AbiFunction raise LockfileError {
  guard value is Object(object) else {
    return invalid_lockfile("\{path}: expected function object")
  }
  require_keys(object, ["module", "name", "params", "results"], path)
  let module_name : String? = match required_value(object, "module", path) {
    Null => None
    String(value) => Some(value)
    _ => invalid_lockfile("\{path}.module: expected string or null")
  }
  if expect_import && module_name is None {
    invalid_lockfile("\{path}.module: imports require a module name")
  }
  if !expect_import && module_name is Some(_) {
    invalid_lockfile("\{path}.module: exports require null")
  }
  @model.AbiFunction::{
    module_name,
    name: required_string(object, "name", path),
    params: decode_value_types(
      required_array(object, "params", path),
      "\{path}.params",
    ),
    results: decode_value_types(
      required_array(object, "results", path),
      "\{path}.results",
    ),
  }
}

///|
fn decode_functions(
  values : Array[Json],
  path : String,
  expect_import : Bool,
) -> Array[@model.AbiFunction] raise LockfileError {
  let decoded : Array[@model.AbiFunction] = []
  for index, value in values {
    decoded.push(decode_function(value, "\{path}[\{index}]", expect_import))
  }
  decoded
}

///|
fn decode_field(
  value : Json,
  path : String,
) -> @model.AbiField raise LockfileError {
  guard value is Object(object) else {
    return invalid_lockfile("\{path}: expected field object")
  }
  require_keys(object, ["storage", "mutable"], path)
  let storage_text = required_string(object, "storage", path)
  let storage = match storage_text {
    "i8" => @model.PackedI8
    "i16" => @model.PackedI16
    _ => @model.Value(decode_value_type(storage_text, "\{path}.storage"))
  }
  @model.AbiField::{ storage, mutable: required_bool(object, "mutable", path), }
}

///|
fn decode_fields(
  values : Array[Json],
  path : String,
) -> Array[@model.AbiField] raise LockfileError {
  let decoded : Array[@model.AbiField] = []
  for index, value in values {
    decoded.push(decode_field(value, "\{path}[\{index}]"))
  }
  decoded
}

///|
fn decode_strings(
  values : Array[Json],
  path : String,
) -> Array[String] raise LockfileError {
  let decoded : Array[String] = []
  for index, value in values {
    match value {
      String(text) => decoded.push(text)
      _ => invalid_lockfile("\{path}[\{index}]: expected string")
    }
  }
  decoded
}

///|
fn decode_type_definition(
  value : Json,
  path : String,
) -> @model.AbiTypeDef raise LockfileError {
  guard value is Object(object) else {
    return invalid_lockfile("\{path}: expected type object")
  }
  let kind = required_string(object, "kind", path)
  let id = required_string(object, "id", path)
  let supertypes = decode_strings(
    required_array(object, "supertypes", path),
    "\{path}.supertypes",
  )
  let final_ = required_bool(object, "final", path)
  match kind {
    "struct" => {
      require_keys(
        object,
        ["kind", "id", "supertypes", "final", "fields"],
        path,
      )
      @model.Struct(@model.AbiStructType::{
        id,
        supertypes,
        final_,
        fields: decode_fields(
          required_array(object, "fields", path),
          "\{path}.fields",
        ),
      })
    }
    "array" => {
      require_keys(
        object,
        ["kind", "id", "supertypes", "final", "element"],
        path,
      )
      @model.Array(@model.AbiArrayType::{
        id,
        supertypes,
        final_,
        element: decode_field(
          required_value(object, "element", path),
          "\{path}.element",
        ),
      })
    }
    _ => invalid_lockfile("\{path}.kind: unsupported type kind '\{kind}'")
  }
}

///|
fn decode_type_definitions(
  values : Array[Json],
  path : String,
) -> Array[@model.AbiTypeDef] raise LockfileError {
  let decoded : Array[@model.AbiTypeDef] = []
  for index, value in values {
    decoded.push(decode_type_definition(value, "\{path}[\{index}]"))
  }
  decoded
}

///|
fn decode_host_abi(
  value : Json,
  path : String,
) -> @model.HostAbi raise LockfileError {
  guard value is Object(object) else {
    return invalid_lockfile("\{path}: expected ABI object")
  }
  require_keys(
    object,
    ["schemaVersion", "imports", "exports", "types", "features"],
    path,
  )
  guard required_value(object, "schemaVersion", path) is Number(version, ..) &&
    version == 1.0 else {
    return invalid_lockfile("\{path}.schemaVersion: expected version 1")
  }
  @model.HostAbi::{
    schema_version: 1,
    imports: decode_functions(
      required_array(object, "imports", path),
      "\{path}.imports",
      true,
    ),
    exports: decode_functions(
      required_array(object, "exports", path),
      "\{path}.exports",
      false,
    ),
    types: decode_type_definitions(
      required_array(object, "types", path),
      "\{path}.types",
    ),
    features: decode_strings(
      required_array(object, "features", path),
      "\{path}.features",
    ),
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
pub fn decode_lockfile(text : String) -> AbiLockfile raise LockfileError {
  if text.length() > MAX_LOCKFILE_LENGTH {
    invalid_lockfile("lockfile: input exceeds 8 MiB limit")
  }
  let root : Json = @json.parse(text) catch {
    _ => invalid_lockfile("lockfile: invalid JSON")
  }
  guard root is Object(object) else {
    return invalid_lockfile("lockfile: expected object")
  }
  require_keys(
    object,
    ["lockfileVersion", "schemaSha256", "artifactSha256", "abiSha256", "abi"],
    "lockfile",
  )
  guard required_value(object, "lockfileVersion", "lockfile")
    is Number(version, ..) &&
    version == 1.0 else {
    return invalid_lockfile("lockfile.lockfileVersion: expected version 1")
  }
  let schema_sha256 = required_string(object, "schemaSha256", "lockfile")
  let artifact_sha256 = required_string(object, "artifactSha256", "lockfile")
  let abi_sha256 = required_string(object, "abiSha256", "lockfile")
  if !is_lower_hex_sha256(schema_sha256) ||
    schema_sha256 != sha256_text("moonhostabi.abi.lock/v1") {
    invalid_lockfile("lockfile.schemaSha256: schema fingerprint mismatch")
  }
  if !is_lower_hex_sha256(artifact_sha256) {
    invalid_lockfile("lockfile.artifactSha256: expected lowercase SHA-256")
  }
  if !is_lower_hex_sha256(abi_sha256) {
    invalid_lockfile("lockfile.abiSha256: expected lowercase SHA-256")
  }
  let decoded_abi = decode_host_abi(
    required_value(object, "abi", "lockfile"),
    "lockfile.abi",
  )
  let abi = canonicalize_host_abi(decoded_abi)
  if decoded_abi != abi {
    invalid_lockfile("lockfile.abi: expected canonical ordering and type IDs")
  }
  let computed_abi_sha256 = sha256_text(encode_canonical_host_abi(abi))
  if computed_abi_sha256 != abi_sha256 {
    invalid_lockfile("lockfile.abiSha256: ABI fingerprint mismatch")
  }
  let lockfile = AbiLockfile::{
    lockfile_version: 1,
    schema_sha256,
    artifact_sha256,
    abi_sha256,
    abi,
  }
  if encode_lockfile(lockfile) != text {
    invalid_lockfile("lockfile: expected canonical byte representation")
  }
  lockfile
}
