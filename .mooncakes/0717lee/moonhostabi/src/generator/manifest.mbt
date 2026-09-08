///|
const GENERATION_MANIFEST_VERSION : Int = 1

///|
pub const MOONHOSTABI_VERSION : String = "0.1.1"

///|
const MAX_GENERATION_MANIFEST_LENGTH : Int = 64 * 1024

///|
pub(all) suberror ManifestError {
  InvalidManifest(String)
} derive(Debug)

///|
pub impl Show for ManifestError with fn output(self, logger) {
  match self {
    InvalidManifest(message) => logger.write_string(message)
  }
}

///|
pub struct GenerationManifest {
  abi_sha256 : String
  generator_version : String
  contract_sha256 : String
  adapter_sha256 : String
} derive(Eq, Debug)

///|
fn[T] invalid_manifest(message : String) -> T raise ManifestError {
  raise InvalidManifest(message)
}

///|
fn manifest_json_string(value : String) -> String {
  Json::string(value).stringify()
}

///|
fn manifest_sha256(text : String) -> String {
  @lockfile.sha256_hex(@encoding.encode(@encoding.UTF8, text))
}

///|
fn is_manifest_sha256(value : String) -> Bool {
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
fn manifest_require_keys(
  object : Map[String, Json],
  keys : Array[String],
  path : String,
) -> Unit raise ManifestError {
  if object.length() != keys.length() {
    invalid_manifest("\{path}: unexpected or missing fields")
  }
  for key in keys {
    if object.get(key) is None {
      invalid_manifest("\{path}.\{key}: required field is missing")
    }
  }
}

///|
fn manifest_value(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Json raise ManifestError {
  match object.get(key) {
    Some(value) => value
    None => invalid_manifest("\{path}.\{key}: required field is missing")
  }
}

///|
fn manifest_string(
  object : Map[String, Json],
  key : String,
  path : String,
) -> String raise ManifestError {
  match manifest_value(object, key, path) {
    String(value) => value
    _ => invalid_manifest("\{path}.\{key}: expected string")
  }
}

///|
fn manifest_hash(
  object : Map[String, Json],
  key : String,
  path : String,
) -> String raise ManifestError {
  let value = manifest_string(object, key, path)
  if !is_manifest_sha256(value) {
    invalid_manifest("\{path}.\{key}: expected lowercase SHA-256")
  }
  value
}

///|
pub fn create_generation_manifest(
  abi_sha256 : String,
  contract : String,
  typescript : String,
) -> GenerationManifest {
  GenerationManifest::{
    abi_sha256,
    generator_version: MOONHOSTABI_VERSION,
    contract_sha256: manifest_sha256(contract),
    adapter_sha256: manifest_sha256(typescript),
  }
}

///|
pub fn encode_generation_manifest(manifest : GenerationManifest) -> String {
  "{\"schemaVersion\":\{GENERATION_MANIFEST_VERSION},\"abiSha256\":\{manifest_json_string(manifest.abi_sha256)},\"generatorVersion\":\{manifest_json_string(manifest.generator_version)},\"contractSha256\":\{manifest_json_string(manifest.contract_sha256)},\"files\":{\"adapter.ts\":\{manifest_json_string(manifest.adapter_sha256)},\"moonhostabi.contract.json\":\{manifest_json_string(manifest.contract_sha256)}}}\n"
}

///|
pub fn decode_generation_manifest(
  text : String,
) -> GenerationManifest raise ManifestError {
  if @encoding.encode(@encoding.UTF8, text).length() >
    MAX_GENERATION_MANIFEST_LENGTH {
    invalid_manifest("manifest: input exceeds 64 KiB limit")
  }
  let root : Json = @json.parse(text) catch {
    _ => invalid_manifest("manifest: invalid JSON")
  }
  guard root is Object(object) else {
    return invalid_manifest("manifest: expected object")
  }
  manifest_require_keys(
    object,
    [
      "schemaVersion", "abiSha256", "generatorVersion", "contractSha256", "files",
    ],
    "manifest",
  )
  guard manifest_value(object, "schemaVersion", "manifest")
    is Number(version, ..) &&
    version == 1.0 else {
    return invalid_manifest("manifest.schemaVersion: expected version 1")
  }
  let abi_sha256 = manifest_hash(object, "abiSha256", "manifest")
  let generator_version = manifest_string(
    object, "generatorVersion", "manifest",
  )
  if generator_version != MOONHOSTABI_VERSION {
    invalid_manifest("manifest.generatorVersion: unsupported generator version")
  }
  let contract_sha256 = manifest_hash(object, "contractSha256", "manifest")
  guard manifest_value(object, "files", "manifest") is Object(files) else {
    return invalid_manifest("manifest.files: expected object")
  }
  manifest_require_keys(
    files,
    ["adapter.ts", "moonhostabi.contract.json"],
    "manifest.files",
  )
  let adapter_sha256 = manifest_hash(files, "adapter.ts", "manifest.files")
  let contract_file_sha256 = manifest_hash(
    files, "moonhostabi.contract.json", "manifest.files",
  )
  if contract_sha256 != contract_file_sha256 {
    invalid_manifest(
      "manifest.contractSha256: must match moonhostabi.contract.json",
    )
  }
  let manifest = GenerationManifest::{
    abi_sha256,
    generator_version,
    contract_sha256,
    adapter_sha256,
  }
  if encode_generation_manifest(manifest) != text {
    invalid_manifest("manifest: expected canonical byte representation")
  }
  manifest
}

///|
pub fn GenerationManifest::abi_fingerprint(self : GenerationManifest) -> String {
  self.abi_sha256
}

///|
pub fn GenerationManifest::owned_file_names(
  self : GenerationManifest,
) -> Array[String] {
  ignore(self)
  ["adapter.ts", "moonhostabi.contract.json"]
}

///|
pub fn GenerationManifest::file_sha256(
  self : GenerationManifest,
  path : String,
) -> String? {
  match path {
    "adapter.ts" => Some(self.adapter_sha256)
    "moonhostabi.contract.json" => Some(self.contract_sha256)
    _ => None
  }
}
