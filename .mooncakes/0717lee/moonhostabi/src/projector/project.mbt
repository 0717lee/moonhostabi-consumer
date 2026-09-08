///|
fn canonical_type_id(
  raw_type_index : Int,
  canonical_type_indices : Array[Int],
) -> String? {
  if raw_type_index < 0 || raw_type_index >= canonical_type_indices.length() {
    return None
  }
  let canonical_index = canonical_type_indices[raw_type_index]
  if canonical_index < 0 {
    None
  } else {
    Some("type[\{canonical_index}]")
  }
}

///|
fn typed_ref(
  raw_type_index : Int,
  nullable : Bool,
  canonical_type_indices : Array[Int],
) -> @model.AbiValueType {
  match canonical_type_id(raw_type_index, canonical_type_indices) {
    Some(type_id) => @model.TypedRef(type_id, nullable)
    None => @model.Unknown("types[\{raw_type_index}]")
  }
}

///|
fn map_value_type(
  value_type : @wasm_types.ValueType,
  canonical_type_indices : Array[Int],
) -> @model.AbiValueType {
  match value_type {
    I32 => @model.I32
    I64 => @model.I64
    F32 => @model.F32
    F64 => @model.F64
    V128 => @model.V128
    ExternRef | RefExtern => @model.ExternRef
    FuncRef | RefFunc => @model.FuncRef
    RefFuncTyped(type_index) | RefStruct(type_index) | RefArray(type_index) =>
      typed_ref(type_index, false, canonical_type_indices)
    RefNullFuncTyped(type_index)
    | RefNullStruct(type_index)
    | RefNullArray(type_index) =>
      typed_ref(type_index, true, canonical_type_indices)
    AnyRef => @model.Unknown("value_type.anyref")
    ExnRef => @model.Unknown("value_type.exnref")
    StructRef => @model.Unknown("value_type.structref")
    ArrayRef => @model.Unknown("value_type.arrayref")
    RefAny => @model.Unknown("value_type.ref_any")
    RefEq => @model.Unknown("value_type.ref_eq")
    RefNullEq => @model.Unknown("value_type.ref_null_eq")
    RefI31 => @model.Unknown("value_type.ref_i31")
    RefNullI31 => @model.Unknown("value_type.ref_null_i31")
    RefStructAbs => @model.Unknown("value_type.ref_struct")
    RefArrayAbs => @model.Unknown("value_type.ref_array")
    RefNone => @model.Unknown("value_type.ref_none")
    NullRef => @model.Unknown("value_type.nullref")
    NullFuncRef => @model.Unknown("value_type.nullfuncref")
    NullExnRef => @model.Unknown("value_type.nullexnref")
    NullExternRef => @model.Unknown("value_type.nullexternref")
  }
}

///|
fn project_function(
  module_name : String?,
  name : String,
  function_type : @wasm_types.FuncType,
  canonical_type_indices : Array[Int],
) -> @model.AbiFunction {
  @model.AbiFunction::{
    module_name,
    name,
    params: function_type.params.map(fn(value_type) {
      map_value_type(value_type, canonical_type_indices)
    }),
    results: function_type.results.map(fn(value_type) {
      map_value_type(value_type, canonical_type_indices)
    }),
  }
}

///|
fn unresolved_function(
  module_name : String?,
  name : String,
  path : String,
) -> @model.AbiFunction {
  @model.AbiFunction::{
    module_name,
    name,
    params: [@model.Unknown(path)],
    results: [],
  }
}

///|
fn function_type_index_at_index(
  wasm_module : @wasm_types.Module,
  function_index : Int,
) -> Int? {
  if function_index < 0 {
    return None
  }
  let mut imported_function_count = 0
  for imported in wasm_module.imports {
    match imported.desc {
      Func(type_index) => {
        if imported_function_count == function_index {
          return Some(type_index)
        }
        imported_function_count += 1
      }
      _ => ()
    }
  }
  let defined_index = function_index - imported_function_count
  if defined_index < 0 || defined_index >= wasm_module.funcs.length() {
    return None
  }
  Some(wasm_module.funcs[defined_index])
}

///|
fn function_type_at_index(
  wasm_module : @wasm_types.Module,
  function_index : Int,
) -> @wasm_types.FuncType? {
  match function_type_index_at_index(wasm_module, function_index) {
    Some(type_index) => wasm_module.func_type_at(type_index)
    None => None
  }
}

///|
fn enqueue_value_type(
  value_type : @wasm_types.ValueType,
  worklist : Array[Int],
) -> Unit {
  match value_type {
    RefFuncTyped(type_index)
    | RefNullFuncTyped(type_index)
    | RefStruct(type_index)
    | RefNullStruct(type_index)
    | RefArray(type_index)
    | RefNullArray(type_index) => worklist.push(type_index)
    _ => ()
  }
}

///|
fn enqueue_function_type(
  function_type : @wasm_types.FuncType,
  worklist : Array[Int],
) -> Unit {
  for value_type in function_type.params {
    enqueue_value_type(value_type, worklist)
  }
  for value_type in function_type.results {
    enqueue_value_type(value_type, worklist)
  }
}

///|
fn enqueue_field_type(
  field : @wasm_types.FieldType,
  worklist : Array[Int],
) -> Unit {
  match field.storage_type {
    Val(value_type) => enqueue_value_type(value_type, worklist)
    Packed(_) => ()
  }
}

///|
fn project_field(
  field : @wasm_types.FieldType,
  canonical_type_indices : Array[Int],
) -> @model.AbiField {
  let storage = match field.storage_type {
    Val(value_type) =>
      @model.Value(map_value_type(value_type, canonical_type_indices))
    Packed(I8) => @model.PackedI8
    Packed(I16) => @model.PackedI16
  }
  { storage, mutable: field.mutable, }
}

///|
fn project_supertypes(
  supertypes : Array[Int],
  canonical_type_indices : Array[Int],
) -> Array[String] {
  let projected : Array[String] = []
  for supertype in supertypes {
    if canonical_type_id(supertype, canonical_type_indices) is Some(type_id) {
      projected.push(type_id)
    }
  }
  projected
}

///|
fn project_reachable_types(
  wasm_module : @wasm_types.Module,
  canonical_type_indices : Array[Int],
) -> Array[@model.AbiTypeDef] {
  let worklist : Array[Int] = []
  for imported in wasm_module.imports {
    if imported.desc is Func(type_index) {
      worklist.push(type_index)
    }
  }
  for exported in wasm_module.exports {
    if exported.desc is Func(function_index) {
      if function_type_index_at_index(wasm_module, function_index)
        is Some(type_index) {
        worklist.push(type_index)
      }
    }
  }

  let visited : Array[Int] = []
  let reachable : Array[Int] = []
  let mut cursor = 0
  while cursor < worklist.length() {
    let type_index = worklist[cursor]
    cursor += 1
    if type_index < 0 ||
      type_index >= wasm_module.types.length() ||
      visited.contains(type_index) {
      continue
    }
    visited.push(type_index)
    reachable.push(type_index)
    let subtype = wasm_module.types[type_index]
    for supertype in subtype.supertypes {
      worklist.push(supertype)
    }
    match subtype.composite {
      Func(function_type) => enqueue_function_type(function_type, worklist)
      Struct(struct_type) =>
        for field in struct_type.fields {
          enqueue_field_type(field, worklist)
        }
      Array(array_type) => enqueue_field_type(array_type.element, worklist)
    }
  }

  reachable.sort_by(fn(left, right) {
    let left_id = if left >= 0 && left < canonical_type_indices.length() {
      canonical_type_indices[left]
    } else {
      left
    }
    let right_id = if right >= 0 && right < canonical_type_indices.length() {
      canonical_type_indices[right]
    } else {
      right
    }
    if left_id != right_id {
      left_id - right_id
    } else {
      left - right
    }
  })

  let definitions : Array[@model.AbiTypeDef] = []
  let emitted_ids : Array[String] = []
  for type_index in reachable {
    guard canonical_type_id(type_index, canonical_type_indices) is Some(type_id) else {
      continue
    }
    if emitted_ids.contains(type_id) {
      continue
    }
    let subtype = wasm_module.types[type_index]
    let supertypes = project_supertypes(
      subtype.supertypes,
      canonical_type_indices,
    )
    match subtype.composite {
      Struct(struct_type) => {
        definitions.push(
          @model.Struct(@model.AbiStructType::{
            id: type_id,
            supertypes,
            final_: subtype.final_,
            fields: struct_type.fields.map(fn(field) {
              project_field(field, canonical_type_indices)
            }),
          }),
        )
        emitted_ids.push(type_id)
      }
      Array(array_type) => {
        definitions.push(
          @model.Array(@model.AbiArrayType::{
            id: type_id,
            supertypes,
            final_: subtype.final_,
            element: project_field(array_type.element, canonical_type_indices),
          }),
        )
        emitted_ids.push(type_id)
      }
      Func(_) => ()
    }
  }
  definitions
}

///|
fn project_host_abi(wasm_module : @wasm_types.Module) -> @model.HostAbi {
  let canonical_type_indices = @wasm_types.compute_canonical_type_indices(
    wasm_module.types,
    type_rec_groups=wasm_module.type_rec_groups,
  )
  let imports : Array[@model.AbiFunction] = []
  for imported in wasm_module.imports {
    match imported.desc {
      Func(type_index) =>
        match wasm_module.func_type_at(type_index) {
          Some(function_type) =>
            imports.push(
              project_function(
                Some(imported.mod_name),
                imported.name,
                function_type,
                canonical_type_indices,
              ),
            )
          None =>
            imports.push(
              unresolved_function(
                Some(imported.mod_name),
                imported.name,
                "imports[\{imported.mod_name}.\{imported.name}].type[\{type_index}]",
              ),
            )
        }
      _ => ()
    }
  }
  let exports : Array[@model.AbiFunction] = []
  for exported in wasm_module.exports {
    match exported.desc {
      Func(function_index) =>
        match function_type_at_index(wasm_module, function_index) {
          Some(function_type) =>
            exports.push(
              project_function(
                None,
                exported.name,
                function_type,
                canonical_type_indices,
              ),
            )
          None =>
            exports.push(
              unresolved_function(
                None,
                exported.name,
                "exports[\{exported.name}].functions[\{function_index}]",
              ),
            )
        }
      _ => ()
    }
  }
  @model.HostAbi::{
    schema_version: 1,
    imports: @model.sort_abi_functions(imports),
    exports: @model.sort_abi_functions(exports),
    types: project_reachable_types(wasm_module, canonical_type_indices),
    features: detect_moonbit_features(wasm_module),
  }
}
