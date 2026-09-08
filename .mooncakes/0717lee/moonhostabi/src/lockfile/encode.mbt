///|
pub struct AbiLockfile {
  lockfile_version : Int
  schema_sha256 : String
  artifact_sha256 : String
  abi_sha256 : String
  abi : @model.HostAbi
} derive(Eq, Debug)

///|
pub fn sha256_hex(bytes : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
}

///|
fn sha256_text(text : String) -> String {
  sha256_hex(@encoding.encode(@encoding.UTF8, text))
}

///|
fn json_string(value : String) -> String {
  Json::string(value).stringify()
}

///|
fn json_bool(value : Bool) -> String {
  if value {
    "true"
  } else {
    "false"
  }
}

///|
fn encode_string_array(values : Array[String]) -> String {
  "[\{values.map(fn(value) { json_string(value) }).join(",")}]"
}

///|
fn encode_value_type(value_type : @model.AbiValueType) -> String {
  json_string(value_type.stable_text())
}

///|
fn encode_value_types(value_types : Array[@model.AbiValueType]) -> String {
  "[\{value_types.map(fn(value) { encode_value_type(value) }).join(",")}]"
}

///|
fn encode_function(function : @model.AbiFunction) -> String {
  let module_name = match function.module_name {
    Some(value) => json_string(value)
    None => "null"
  }
  "{\"module\":\{module_name},\"name\":\{json_string(function.name)},\"params\":\{encode_value_types(function.params)},\"results\":\{encode_value_types(function.results)}}"
}

///|
fn encode_functions(functions : Array[@model.AbiFunction]) -> String {
  "[\{functions.map(fn(function) { encode_function(function) }).join(",")}]"
}

///|
fn encode_field(field : @model.AbiField) -> String {
  let storage = match field.storage {
    PackedI8 => "i8"
    PackedI16 => "i16"
    Value(value_type) => value_type.stable_text()
  }
  "{\"storage\":\{json_string(storage)},\"mutable\":\{json_bool(field.mutable)}}"
}

///|
fn encode_fields(fields : Array[@model.AbiField]) -> String {
  "[\{fields.map(fn(field) { encode_field(field) }).join(",")}]"
}

///|
fn encode_type_definition(definition : @model.AbiTypeDef) -> String {
  match definition {
    Struct(value) =>
      "{\"kind\":\"struct\",\"id\":\{json_string(value.id)},\"supertypes\":\{encode_string_array(value.supertypes)},\"final\":\{json_bool(value.final_)},\"fields\":\{encode_fields(value.fields)}}"
    Array(value) =>
      "{\"kind\":\"array\",\"id\":\{json_string(value.id)},\"supertypes\":\{encode_string_array(value.supertypes)},\"final\":\{json_bool(value.final_)},\"element\":\{encode_field(value.element)}}"
  }
}

///|
fn encode_type_definitions(definitions : Array[@model.AbiTypeDef]) -> String {
  "[\{definitions.map(fn(definition) { encode_type_definition(definition) }).join(",")}]"
}

///|
fn encode_canonical_host_abi(abi : @model.HostAbi) -> String {
  "{\"schemaVersion\":\{abi.schema_version},\"imports\":\{encode_functions(abi.imports)},\"exports\":\{encode_functions(abi.exports)},\"types\":\{encode_type_definitions(abi.types)},\"features\":\{encode_string_array(abi.features)}}"
}

///|
pub fn encode_canonical_abi(abi : @model.HostAbi) -> String {
  encode_canonical_host_abi(canonicalize_host_abi(abi))
}

///|
pub fn host_abi_sha256(abi : @model.HostAbi) -> String {
  sha256_text(encode_canonical_abi(abi))
}

///|
pub fn create_lockfile(abi : @model.HostAbi, artifact : Bytes) -> AbiLockfile {
  let canonical_abi = canonicalize_host_abi(abi)
  let encoded_abi = encode_canonical_host_abi(canonical_abi)
  AbiLockfile::{
    lockfile_version: 1,
    schema_sha256: sha256_text("moonhostabi.abi.lock/v1"),
    artifact_sha256: sha256_hex(artifact),
    abi_sha256: sha256_text(encoded_abi),
    abi: canonical_abi,
  }
}

///|
pub fn encode_lockfile(lockfile : AbiLockfile) -> String {
  "{\"lockfileVersion\":\{lockfile.lockfile_version},\"schemaSha256\":\{json_string(lockfile.schema_sha256)},\"artifactSha256\":\{json_string(lockfile.artifact_sha256)},\"abiSha256\":\{json_string(lockfile.abi_sha256)},\"abi\":\{encode_canonical_host_abi(lockfile.abi)}}"
}

///|
/// Return a fresh canonical ABI value without exposing mutable lockfile fields.
pub fn AbiLockfile::canonical_abi(self : AbiLockfile) -> @model.HostAbi {
  canonicalize_host_abi(self.abi)
}

///|
/// Return the fingerprint of the exact artifact bytes that created this lockfile.
pub fn AbiLockfile::artifact_fingerprint(self : AbiLockfile) -> String {
  self.artifact_sha256
}

///|
/// Return the fingerprint of the canonical ABI stored in this lockfile.
pub fn AbiLockfile::abi_fingerprint(self : AbiLockfile) -> String {
  self.abi_sha256
}
