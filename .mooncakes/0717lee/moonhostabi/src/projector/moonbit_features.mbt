///|
pub(all) struct JsCapabilityPolicy {
  allow_typed_gc_refs : Bool
  allow_v128 : Bool
  externref_symbol : String?
} derive(Eq, Debug)

///|
pub fn default_js_capability_policy() -> JsCapabilityPolicy {
  { allow_typed_gc_refs: false, allow_v128: false, externref_symbol: None, }
}

///|
pub(all) enum JsRepresentation {
  Number
  BigInt
  Callable
  Opaque(String)
  Unsupported(String)
} derive(Eq, Debug)

///|
pub(all) struct ProjectionAnalysis {
  abi : @model.HostAbi
  diagnostics : Array[@model.Diagnostic]
} derive(Debug)

///|
fn unrepresentable(path : String, message : String) -> @model.Diagnostic {
  @model.Diagnostic::{
    code: @model.MHA_PROJECT_UNREPRESENTABLE,
    severity: @model.Error,
    path,
    message,
    byte_offset: None,
  }
}

///|
pub fn classify_js_value_type(
  value_type : @model.AbiValueType,
  path : String,
  policy : JsCapabilityPolicy,
) -> (JsRepresentation, @model.Diagnostic?) {
  match value_type {
    @model.I32 | @model.F32 | @model.F64 => (Number, None)
    @model.I64 => (BigInt, None)
    @model.ExternRef =>
      (Opaque(policy.externref_symbol.unwrap_or("unknown")), None)
    @model.FuncRef => (Callable, None)
    @model.V128 =>
      if policy.allow_v128 {
        (Opaque("v128"), None)
      } else {
        (
          Unsupported("v128"),
          Some(
            unrepresentable(
              path, "v128 is not representable through the configured JavaScript host",
            ),
          ),
        )
      }
    @model.TypedRef(type_id, _) =>
      if policy.allow_typed_gc_refs {
        (Opaque(type_id), None)
      } else {
        (
          Unsupported(type_id),
          Some(
            unrepresentable(
              path,
              "typed GC reference \{type_id} is not representable through the configured JavaScript host",
            ),
          ),
        )
      }
    @model.Unknown(source) =>
      (
        Unsupported(source),
        Some(unrepresentable(path, "unsupported Wasm value type at \{source}")),
      )
  }
}

///|
fn append_function_diagnostics(
  function : @model.AbiFunction,
  function_path : String,
  policy : JsCapabilityPolicy,
  diagnostics : Array[@model.Diagnostic],
) -> Unit {
  for index, value_type in function.params {
    let (_, diagnostic) = classify_js_value_type(
      value_type,
      "\{function_path}.params[\{index}]",
      policy,
    )
    if diagnostic is Some(value) {
      diagnostics.push(value)
    }
  }
  for index, value_type in function.results {
    let (_, diagnostic) = classify_js_value_type(
      value_type,
      "\{function_path}.results[\{index}]",
      policy,
    )
    if diagnostic is Some(value) {
      diagnostics.push(value)
    }
  }
}

///|
fn unsupported_item(path : String, kind : String) -> @model.Diagnostic {
  @model.Diagnostic::{
    code: @model.MHA_PROJECT_UNSUPPORTED_ITEM,
    severity: @model.Error,
    path,
    message: "public \{kind} is not supported by the Spike adapter",
    byte_offset: None,
  }
}

///|
fn append_non_function_diagnostics(
  wasm_module : @wasm_types.Module,
  diagnostics : Array[@model.Diagnostic],
) -> Unit {
  for imported in wasm_module.imports {
    let kind = match imported.desc {
      Func(_) => None
      Table(_) => Some("table import")
      Memory(_) => Some("memory import")
      Global(_) => Some("global import")
      Tag(_) => Some("tag import")
    }
    if kind is Some(value) {
      diagnostics.push(
        unsupported_item(
          "imports[\{imported.mod_name}.\{imported.name}]",
          value,
        ),
      )
    }
  }
  for exported in wasm_module.exports {
    let kind = match exported.desc {
      Func(_) => None
      Table(_) => Some("table export")
      Memory(_) => Some("memory export")
      Global(_) => Some("global export")
      Tag(_) => Some("tag export")
    }
    if kind is Some(value) {
      diagnostics.push(unsupported_item("exports[\{exported.name}]", value))
    }
  }
}

///|
pub fn analyze_host_abi(
  wasm_module : @wasm_types.Module,
  policy : JsCapabilityPolicy,
) -> ProjectionAnalysis {
  let abi = project_host_abi(wasm_module)
  let diagnostics : Array[@model.Diagnostic] = []
  append_non_function_diagnostics(wasm_module, diagnostics)
  for function in abi.imports {
    let module_name = function.module_name.unwrap_or("")
    append_function_diagnostics(
      function,
      "imports[\{module_name}.\{function.name}]",
      policy,
      diagnostics,
    )
  }
  for function in abi.exports {
    append_function_diagnostics(
      function,
      "exports[\{function.name}]",
      policy,
      diagnostics,
    )
  }
  { abi, diagnostics, }
}

///|
fn detect_moonbit_features(wasm_module : @wasm_types.Module) -> Array[String] {
  for imported in wasm_module.imports {
    if imported.mod_name == "moonbit:ffi" && imported.name == "make_closure" {
      match imported.desc {
        Func(_) => return ["moonbit.make_closure"]
        _ => ()
      }
    }
  }
  []
}
