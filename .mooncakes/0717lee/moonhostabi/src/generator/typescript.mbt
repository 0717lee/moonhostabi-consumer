///|
pub(all) struct GenerationResult {
  typescript : String
  contract : String
  manifest : String
  abi_sha256 : String
  diagnostics : Array[@model.Diagnostic]
} derive(Eq, Debug)

///|
fn generator_diagnostic(path : String, message : String) -> @model.Diagnostic {
  @model.Diagnostic::{
    code: @model.MHA_PROJECT_UNREPRESENTABLE,
    severity: @model.Error,
    path,
    message,
    byte_offset: None,
  }
}

///|
fn validate_value_type(
  value : @model.AbiValueType,
  path : String,
  diagnostics : Array[@model.Diagnostic],
) -> Unit {
  match value {
    @model.TypedRef(type_id, _) =>
      diagnostics.push(
        generator_diagnostic(
          path,
          "typed GC reference \{type_id} cannot be represented by the JavaScript adapter",
        ),
      )
    @model.V128 =>
      diagnostics.push(
        generator_diagnostic(
          path, "v128 cannot be represented by the JavaScript adapter",
        ),
      )
    @model.Unknown(source) =>
      diagnostics.push(
        generator_diagnostic(path, "unsupported ABI value type at \{source}"),
      )
    _ => ()
  }
}

///|
fn validate_function(
  function : @model.AbiFunction,
  path : String,
  diagnostics : Array[@model.Diagnostic],
) -> Unit {
  for index, value in function.params {
    validate_value_type(value, "\{path}.params[\{index}]", diagnostics)
  }
  for index, value in function.results {
    validate_value_type(value, "\{path}.results[\{index}]", diagnostics)
  }
  if is_make_closure(function) &&
    !(function.params == [@model.FuncRef, @model.ExternRef] &&
    function.results == [@model.FuncRef]) {
    diagnostics.push(@model.Diagnostic::{
      code: @model.MHA_ADAPTER_MISMATCH,
      severity: @model.Error,
      path,
      message: "moonbit:ffi.make_closure has an unsupported signature",
      byte_offset: None,
    })
  }
}

///|
fn validate_generator_abi(abi : @model.HostAbi) -> Array[@model.Diagnostic] {
  let diagnostics : Array[@model.Diagnostic] = []
  let imports = @model.sort_abi_functions(abi.imports)
  let exports = @model.sort_abi_functions(abi.exports)
  for index, function in imports {
    let module_name = function.module_name.unwrap_or("")
    validate_function(
      function,
      "imports[\{module_name}.\{function.name}]",
      diagnostics,
    )
    let mut duplicate = false
    for previous in 0..<index {
      if imports[previous].module_name.unwrap_or("") == module_name &&
        imports[previous].name == function.name {
        duplicate = true
      }
    }
    if duplicate {
      diagnostics.push(@model.Diagnostic::{
        code: @model.MHA_ADAPTER_MISMATCH,
        severity: @model.Error,
        path: "imports[\{module_name}.\{function.name}]",
        message: "duplicate Wasm imports cannot be represented by one JavaScript property",
        byte_offset: None,
      })
    }
  }
  for index, function in exports {
    validate_function(function, "exports[\{function.name}]", diagnostics)
    let mut duplicate = false
    for previous in 0..<index {
      if exports[previous].name == function.name {
        duplicate = true
      }
    }
    if duplicate {
      diagnostics.push(@model.Diagnostic::{
        code: @model.MHA_ADAPTER_MISMATCH,
        severity: @model.Error,
        path: "exports[\{function.name}]",
        message: "duplicate Wasm exports cannot be represented by one TypeScript property",
        byte_offset: None,
      })
    }
  }
  diagnostics
}

///|
fn typescript_type(
  value : @model.AbiValueType,
  path : String,
  contract : @contract.Contract,
) -> String raise @contract.ContractError {
  match value {
    @model.I32 | @model.F32 | @model.F64 => "number"
    @model.I64 => "bigint"
    @model.ExternRef =>
      match contract.externref_alias(path) {
        Some(name) => name
        None => raise @contract.ContractAbiMismatch
      }
    @model.FuncRef => "(...args: unknown[]) => unknown"
    @model.V128 | @model.TypedRef(_, _) | @model.Unknown(_) => "never"
  }
}

///|
fn typescript_parameters(
  function : @model.AbiFunction,
  boundary : String,
  contract : @contract.Contract,
  prefix : String,
) -> String raise @contract.ContractError {
  let parameters : Array[String] = []
  for index, value in function.params {
    parameters.push(
      "\{prefix}\{index}: \{typescript_type(value, "\{boundary}.params[\{index}]", contract)}",
    )
  }
  parameters.join(", ")
}

///|
fn typescript_result(
  function : @model.AbiFunction,
  boundary : String,
  contract : @contract.Contract,
) -> String raise @contract.ContractError {
  match function.results {
    [] => "void"
    [value] => typescript_type(value, "\{boundary}.results[0]", contract)
    _ => {
      let result_types : Array[String] = []
      for index, value in function.results {
        result_types.push(
          typescript_type(value, "\{boundary}.results[\{index}]", contract),
        )
      }
      "[\{result_types.join(", ")}]"
    }
  }
}

///|
fn typescript_function_type(
  function : @model.AbiFunction,
  boundary : String,
  contract : @contract.Contract,
  parameter_prefix : String,
) -> String raise @contract.ContractError {
  "(\{typescript_parameters(function, boundary, contract, parameter_prefix)}) => \{typescript_result(function, boundary, contract)}"
}

///|
fn sorted_import_modules(imports : Array[@model.AbiFunction]) -> Array[String] {
  let modules : Array[String] = []
  for function in imports {
    let module_name = function.module_name.unwrap_or("")
    if modules.last() != Some(module_name) {
      modules.push(module_name)
    }
  }
  modules
}

///|
fn has_make_closure(imports : Array[@model.AbiFunction]) -> Bool {
  for function in imports {
    if is_make_closure(function) {
      return true
    }
  }
  false
}

///|
fn export_path(function_name : String) -> String {
  "exports[\{function_name}]"
}

///|
fn semantic_aliases_for_functions(
  functions : Array[@model.AbiFunction],
  contract : @contract.Contract,
) -> Array[String] raise @contract.ContractError {
  let names : Array[String] = []
  for function in functions {
    let boundary = match function.module_name {
      Some(module_name) => import_path(module_name, function.name)
      None => export_path(function.name)
    }
    for index, value in function.params {
      if value == @model.ExternRef {
        guard contract.externref_alias("\{boundary}.params[\{index}]")
          is Some(name) else {
          raise @contract.ContractAbiMismatch
        }
        if !names.contains(name) {
          names.push(name)
        }
      }
    }
    for index, value in function.results {
      if value == @model.ExternRef {
        guard contract.externref_alias("\{boundary}.results[\{index}]")
          is Some(name) else {
          raise @contract.ContractAbiMismatch
        }
        if !names.contains(name) {
          names.push(name)
        }
      }
    }
  }
  names
}

///|
fn type_parameter_declaration(names : Array[String], defaults : Bool) -> String {
  if names.is_empty() {
    return ""
  }
  let parameters = if defaults {
    names.map(fn(name) { "\{name} = unknown" })
  } else {
    names
  }
  "<\{parameters.join(", ")}>"
}

///|
fn type_arguments(names : Array[String]) -> String {
  if names.is_empty() {
    ""
  } else {
    "<\{names.join(", ")}>"
  }
}

///|
fn typescript_object_literal_key(value : String) -> String {
  let quoted = contract_json_string(value)
  if value == "__proto__" {
    "[\{quoted}]"
  } else {
    quoted
  }
}

///|
fn append_host_import_type(
  lines : Array[String],
  imports : Array[@model.AbiFunction],
  contract : @contract.Contract,
) -> Unit raise @contract.ContractError {
  let names = semantic_aliases_for_functions(imports, contract)
  lines.push(
    "export type HostImports\{type_parameter_declaration(names, true)} = {",
  )
  for module_name in sorted_import_modules(imports) {
    lines.push("  \{contract_json_string(module_name)}: {")
    for function in imports {
      if function.module_name.unwrap_or("") == module_name {
        let boundary = import_path(module_name, function.name)
        lines.push(
          "    \{contract_json_string(function.name)}: \{typescript_function_type(function, boundary, contract, "arg")};",
        )
      }
    }
    lines.push("  };")
  }
  lines.push("};")
}

///|
fn append_module_export_type(
  lines : Array[String],
  exports : Array[@model.AbiFunction],
  contract : @contract.Contract,
) -> Unit raise @contract.ContractError {
  let names = semantic_aliases_for_functions(exports, contract)
  lines.push(
    "export type ModuleExports\{type_parameter_declaration(names, true)} = {",
  )
  for function in exports {
    let boundary = export_path(function.name)
    lines.push(
      "  \{contract_json_string(function.name)}: \{typescript_function_type(function, boundary, contract, "arg")};",
    )
  }
  lines.push("};")
}

///|
fn append_make_closure_helper(lines : Array[String]) -> Unit {
  lines.push("export function makeMoonBitClosure<TContext>(")
  lines.push("  fn: (...args: unknown[]) => unknown,")
  lines.push("  context: TContext,")
  lines.push("): (...args: unknown[]) => unknown {")
  lines.push("  return (...args: unknown[]) => fn(context, ...args);")
  lines.push("}")
}

///|
fn throwing_stub(function : @model.AbiFunction) -> Array[String] {
  let params : Array[String] = []
  for index in 0..<function.params.length() {
    params.push("_arg\{index}")
  }
  let module_name = function.module_name.unwrap_or("")
  let message = "MHA_ADAPTER_MISMATCH: missing host import \{module_name}.\{function.name} \{function_signature(function)}"
  [
    "\{typescript_object_literal_key(function.name)}: (\{params.join(", ")}) => {",
    "  throw new Error(\{contract_json_string(message)});",
    "},",
  ]
}

///|
fn append_host_import_factory(
  lines : Array[String],
  imports : Array[@model.AbiFunction],
  contract : @contract.Contract,
) -> Unit raise @contract.ContractError {
  let names = semantic_aliases_for_functions(imports, contract)
  lines.push(
    "export function createHostImports\{type_parameter_declaration(names, true)}(): HostImports\{type_arguments(names)} {",
  )
  if imports.is_empty() {
    lines.push("  return {};")
    lines.push("}")
    return
  }
  lines.push("  return {")
  for module_name in sorted_import_modules(imports) {
    lines.push("    \{typescript_object_literal_key(module_name)}: {")
    for function in imports {
      if function.module_name.unwrap_or("") == module_name {
        if is_make_closure(function) {
          lines.push(
            "      \{typescript_object_literal_key(function.name)}: (fn, context) => makeMoonBitClosure(fn, context),",
          )
        } else {
          let stub = throwing_stub(function)
          lines.push("      \{stub[0]}")
          lines.push("      \{stub[1]}")
          lines.push("      \{stub[2]}")
        }
      }
    }
    lines.push("    },")
  }
  lines.push("  };")
  lines.push("}")
}

///|
fn import_path(module_name : String, function_name : String) -> String {
  "imports[\{module_name}.\{function_name}]"
}

///|
fn append_host_import_preflight(
  lines : Array[String],
  imports : Array[@model.AbiFunction],
  contract : @contract.Contract,
) -> Unit raise @contract.ContractError {
  let names = semantic_aliases_for_functions(imports, contract)
  lines.push(
    "function assertHostImports\{type_parameter_declaration(names, false)}(",
  )
  lines.push("  imports: HostImports\{type_arguments(names)},")
  lines.push("): void {")
  let first = imports[0]
  let first_path = import_path(first.module_name.unwrap_or(""), first.name)
  let first_message = "MHA_ADAPTER_MISMATCH: missing or invalid host import \{first_path}"
  lines.push("  if (typeof imports !== \"object\" || imports === null) {")
  lines.push("    throw new Error(\{contract_json_string(first_message)});")
  lines.push("  }")
  lines.push("  const root = imports as unknown as Record<string, unknown>;")
  for module_index, module_name in sorted_import_modules(imports) {
    let mut first_function_name = ""
    let mut found_first_function = false
    for function in imports {
      if function.module_name.unwrap_or("") == module_name &&
        !found_first_function {
        first_function_name = function.name
        found_first_function = true
      }
    }
    let module_path = import_path(module_name, first_function_name)
    let module_message = "MHA_ADAPTER_MISMATCH: missing or invalid host import \{module_path}"
    let module_key = contract_json_string(module_name)
    lines.push(
      "  if (!Object.prototype.hasOwnProperty.call(root, \{module_key})) {",
    )
    lines.push("    throw new Error(\{contract_json_string(module_message)});")
    lines.push("  }")
    lines.push("  const module\{module_index} = root[\{module_key}];")
    lines.push(
      "  if (typeof module\{module_index} !== \"object\" || module\{module_index} === null) {",
    )
    lines.push("    throw new Error(\{contract_json_string(module_message)});")
    lines.push("  }")
    lines.push(
      "  const module\{module_index}Record = module\{module_index} as Record<string, unknown>;",
    )
    for function in imports {
      if function.module_name.unwrap_or("") == module_name {
        let function_key = contract_json_string(function.name)
        let path = import_path(module_name, function.name)
        let message = "MHA_ADAPTER_MISMATCH: host import \{path} must be a function"
        lines.push(
          "  if (!Object.prototype.hasOwnProperty.call(module\{module_index}Record, \{function_key}) ||",
        )
        lines.push(
          "    typeof module\{module_index}Record[\{function_key}] !== \"function\") {",
        )
        lines.push("    throw new Error(\{contract_json_string(message)});")
        lines.push("  }")
      }
    }
  }
  lines.push("}")
}

///|
fn append_module_export_preflight(
  lines : Array[String],
  exports : Array[@model.AbiFunction],
) -> Unit {
  lines.push("function assertModuleExports(")
  lines.push("  exports: WebAssembly.Exports,")
  lines.push("): void {")
  lines.push("  const root = exports as unknown as Record<string, unknown>;")
  for function in exports {
    let function_key = contract_json_string(function.name)
    let path = export_path(function.name)
    let message = "MHA_ADAPTER_MISMATCH: module export \{path} must be a function"
    lines.push(
      "  if (!Object.prototype.hasOwnProperty.call(root, \{function_key}) ||",
    )
    lines.push("    typeof root[\{function_key}] !== \"function\") {")
    lines.push("    throw new Error(\{contract_json_string(message)});")
    lines.push("  }")
  }
  lines.push("}")
}

///|
fn render_typescript(
  abi : @model.HostAbi,
  abi_sha256 : String,
  contract : @contract.Contract,
) -> String raise @contract.ContractError {
  let imports = @model.sort_abi_functions(abi.imports)
  let exports = @model.sort_abi_functions(abi.exports)
  let lines : Array[String] = [
    "// Generated by MoonHostABI. Do not edit.",
    "// ABI SHA-256: \{abi_sha256}",
    "",
  ]
  append_host_import_type(lines, imports, contract)
  lines.push("")
  append_module_export_type(lines, exports, contract)
  if has_make_closure(imports) {
    lines.push("")
    append_make_closure_helper(lines)
  }
  lines.push("")
  append_host_import_factory(lines, imports, contract)
  if !imports.is_empty() {
    lines.push("")
    append_host_import_preflight(lines, imports, contract)
  }
  if !exports.is_empty() {
    lines.push("")
    append_module_export_preflight(lines, exports)
  }
  let all_names = contract.semantic_aliases()
  let import_names = semantic_aliases_for_functions(imports, contract)
  let export_names = semantic_aliases_for_functions(exports, contract)
  lines.push("")
  lines.push(
    "export async function instantiate\{type_parameter_declaration(all_names, true)}(",
  )
  lines.push("  bytes: BufferSource,")
  lines.push("  imports: HostImports\{type_arguments(import_names)},")
  lines.push("): Promise<ModuleExports\{type_arguments(export_names)}> {")
  if !imports.is_empty() {
    lines.push("  assertHostImports(imports);")
  }
  lines.push("  const result = await WebAssembly.instantiate(bytes, imports);")
  if !exports.is_empty() {
    lines.push("  assertModuleExports(result.instance.exports);")
  }
  lines.push(
    "  return result.instance.exports as unknown as ModuleExports\{type_arguments(export_names)};",
  )
  lines.push("}")
  lines.join("\n") + "\n"
}

///|
pub fn generate_typescript_adapter(
  abi : @model.HostAbi,
  contract : @contract.Contract,
) -> GenerationResult raise @contract.ContractError {
  let canonical_abi = @lockfile.canonicalize_host_abi(abi)
  let abi_sha256 = @lockfile.host_abi_sha256(canonical_abi)
  @contract.validate_contract(canonical_abi, contract)
  let diagnostics = validate_generator_abi(canonical_abi)
  let normalized_contract = @contract.encode_contract(contract)
  let typescript = if diagnostics.is_empty() {
    render_typescript(canonical_abi, abi_sha256, contract)
  } else {
    ""
  }
  let manifest = if diagnostics.is_empty() {
    encode_generation_manifest(
      create_generation_manifest(abi_sha256, normalized_contract, typescript),
    )
  } else {
    ""
  }
  {
    typescript,
    contract: normalized_contract,
    manifest,
    abi_sha256,
    diagnostics,
  }
}
