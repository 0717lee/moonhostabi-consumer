///|
pub(all) suberror ContractError {
  ContractInputTooLarge
  InvalidContractJson
  InvalidContractShape(String)
  UnsupportedContractVersion
  InvalidAbiFingerprint
  ContractAbiMismatch
  NonCanonicalContract
  MissingExternrefPath(String)
  UnexpectedExternrefPath(String)
  UnsafeExternrefAlias(String)
  ConflictingExternrefAlias(String)
  AmbiguousExternrefPath(String)
  InvalidLegacyImport(String)
} derive(Debug)

///|
pub impl Show for ContractError with fn output(self, logger) {
  let message = match self {
    ContractInputTooLarge => "contract: input exceeds 1 MiB limit"
    InvalidContractJson => "contract: invalid JSON"
    InvalidContractShape(message) => message
    UnsupportedContractVersion =>
      "contract.schemaVersion: expected version 1 or 2"
    InvalidAbiFingerprint => "contract.abiSha256: expected lowercase SHA-256"
    ContractAbiMismatch =>
      "contract.abiSha256: contract does not match artifact ABI"
    NonCanonicalContract => "contract: expected canonical byte representation"
    MissingExternrefPath(path) =>
      "contract.externrefs[\{path}]: required path is missing"
    UnexpectedExternrefPath(path) =>
      "contract.externrefs[\{path}]: unexpected path"
    UnsafeExternrefAlias(path) =>
      "contract.externrefs[\{path}]: expected a safe TypeScript identifier"
    ConflictingExternrefAlias(path) =>
      "contract.externrefs[\{path}]: alias conflicts with generated TypeScript identifiers"
    AmbiguousExternrefPath(path) =>
      "contract ABI has ambiguous externref path \{path}"
    InvalidLegacyImport(path) => "\{path}: import contract does not match ABI"
  }
  logger.write_string(message)
}

///|
pub struct ExternrefBinding {
  path : String
  semantic_name : String
} derive(Eq, Debug)

///|
/// A validated, canonical schema-v2 Host ABI contract.
pub struct Contract {
  abi_sha256 : String
  bindings : Array[ExternrefBinding]
} derive(Eq, Debug)

///|
fn is_identifier_start(character : Char) -> Bool {
  (character >= 'a' && character <= 'z') ||
  (character >= 'A' && character <= 'Z') ||
  character == '_'
}

///|
fn is_identifier_continue(character : Char) -> Bool {
  is_identifier_start(character) || (character >= '0' && character <= '9')
}

///|
fn is_safe_typescript_identifier(value : String) -> Bool {
  if value.is_empty() ||
    [
      "abstract", "any", "as", "asserts", "async", "await", "bigint", "boolean",
      "break", "case", "catch", "class", "const", "constructor", "continue", "debugger",
      "declare", "default", "delete", "do", "else", "enum", "export", "extends",
      "false", "finally", "for", "from", "function", "get", "global", "if", "implements",
      "import", "in", "infer", "instanceof", "interface", "intrinsic", "is", "keyof",
      "let", "module", "namespace", "never", "new", "null", "number", "object", "of",
      "out", "override", "package", "private", "protected", "public", "readonly",
      "require", "return", "satisfies", "set", "static", "string", "super", "switch",
      "symbol", "this", "throw", "true", "try", "type", "typeof", "undefined", "unique",
      "unknown", "using", "var", "void", "while", "with", "yield",
    ].contains(value) {
    return false
  }
  let mut index = 0
  for character in value {
    if (index == 0 && !is_identifier_start(character)) ||
      (index > 0 && !is_identifier_continue(character)) {
      return false
    }
    index += 1
  }
  true
}

///|
fn conflicts_with_generated_typescript(value : String) -> Bool {
  ["BufferSource", "HostImports", "ModuleExports", "Promise", "Record"].contains(
    value,
  )
}

///|
fn add_externref_path(
  paths : Array[String],
  seen : Map[String, Bool],
  path : String,
) -> Unit raise ContractError {
  if seen.get(path) is Some(_) {
    raise AmbiguousExternrefPath(path)
  }
  seen[path] = true
  paths.push(path)
}

///|
fn collect_function_externrefs(
  paths : Array[String],
  seen : Map[String, Bool],
  function : @model.AbiFunction,
  boundary : String,
) -> Unit raise ContractError {
  for index, value in function.params {
    if value == @model.ExternRef {
      add_externref_path(paths, seen, "\{boundary}.params[\{index}]")
    }
  }
  for index, value in function.results {
    if value == @model.ExternRef {
      add_externref_path(paths, seen, "\{boundary}.results[\{index}]")
    }
  }
}

///|
fn expected_externref_paths(
  abi : @model.HostAbi,
) -> Array[String] raise ContractError {
  let canonical = @lockfile.canonicalize_host_abi(abi)
  let paths : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for function in canonical.imports {
    let module_name = function.module_name.unwrap_or("")
    collect_function_externrefs(
      paths,
      seen,
      function,
      "imports[\{module_name}.\{function.name}]",
    )
  }
  for function in canonical.exports {
    collect_function_externrefs(
      paths,
      seen,
      function,
      "exports[\{function.name}]",
    )
  }
  paths
}

///|
fn validate_semantic_name(
  path : String,
  name : String,
) -> Unit raise ContractError {
  if !is_safe_typescript_identifier(name) {
    raise UnsafeExternrefAlias(path)
  }
  if conflicts_with_generated_typescript(name) {
    raise ConflictingExternrefAlias(path)
  }
}

///|
fn make_contract(
  abi : @model.HostAbi,
  names : Array[String],
) -> Contract raise ContractError {
  let canonical = @lockfile.canonicalize_host_abi(abi)
  let paths = expected_externref_paths(canonical)
  if names.length() != paths.length() {
    raise InvalidContractShape(
      "contract.externrefs: path count does not match ABI",
    )
  }
  let bindings : Array[ExternrefBinding] = []
  for index, path in paths {
    let name = names[index]
    validate_semantic_name(path, name)
    bindings.push({ path, semantic_name: name, })
  }
  Contract::{ abi_sha256: @lockfile.host_abi_sha256(canonical), bindings, }
}

///|
pub fn create_contract_draft(
  abi : @model.HostAbi,
) -> Contract raise ContractError {
  let paths = expected_externref_paths(abi)
  let names : Array[String] = []
  for index, _ in paths {
    names.push("TExtern\{index}")
  }
  make_contract(abi, names)
}

///|
pub fn Contract::abi_fingerprint(self : Contract) -> String {
  self.abi_sha256
}

///|
pub fn Contract::externref_alias(self : Contract, path : String) -> String? {
  for binding in self.bindings {
    if binding.path == path {
      return Some(binding.semantic_name)
    }
  }
  None
}

///|
pub fn Contract::semantic_aliases(self : Contract) -> Array[String] {
  let result : Array[String] = []
  for binding in self.bindings {
    if !result.contains(binding.semantic_name) {
      result.push(binding.semantic_name)
    }
  }
  result
}

///|
pub fn validate_contract(
  abi : @model.HostAbi,
  contract : Contract,
) -> Unit raise ContractError {
  let canonical = @lockfile.canonicalize_host_abi(abi)
  if contract.abi_sha256 != @lockfile.host_abi_sha256(canonical) {
    raise ContractAbiMismatch
  }
  let paths = expected_externref_paths(canonical)
  if paths.length() != contract.bindings.length() {
    raise ContractAbiMismatch
  }
  for index, path in paths {
    if contract.bindings[index].path != path {
      raise ContractAbiMismatch
    }
  }
}
