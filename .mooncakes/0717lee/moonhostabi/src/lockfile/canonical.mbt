///|
fn type_definition_id(definition : @model.AbiTypeDef) -> String {
  match definition {
    Struct(value) => value.id
    Array(value) => value.id
  }
}

///|
fn assign_canonical_id(
  source_id : String,
  assigned : Map[String, String],
  worklist : Array[String],
) -> String {
  match assigned.get(source_id) {
    Some(canonical_id) => canonical_id
    None => {
      let canonical_id = "type[\{worklist.length()}]"
      assigned[source_id] = canonical_id
      worklist.push(source_id)
      canonical_id
    }
  }
}

///|
fn discover_value_type(
  value_type : @model.AbiValueType,
  assigned : Map[String, String],
  worklist : Array[String],
) -> Unit {
  match value_type {
    TypedRef(source_id, _) =>
      ignore(assign_canonical_id(source_id, assigned, worklist))
    _ => ()
  }
}

///|
fn discover_function_types(
  function : @model.AbiFunction,
  assigned : Map[String, String],
  worklist : Array[String],
) -> Unit {
  for value_type in function.params {
    discover_value_type(value_type, assigned, worklist)
  }
  for value_type in function.results {
    discover_value_type(value_type, assigned, worklist)
  }
}

///|
fn discover_field_type(
  field : @model.AbiField,
  assigned : Map[String, String],
  worklist : Array[String],
) -> Unit {
  match field.storage {
    Value(value_type) => discover_value_type(value_type, assigned, worklist)
    PackedI8 | PackedI16 => ()
  }
}

///|
fn discover_definition_types(
  definition : @model.AbiTypeDef,
  assigned : Map[String, String],
  worklist : Array[String],
) -> Unit {
  match definition {
    Struct(value) => {
      for supertype in value.supertypes {
        ignore(assign_canonical_id(supertype, assigned, worklist))
      }
      for field in value.fields {
        discover_field_type(field, assigned, worklist)
      }
    }
    Array(value) => {
      for supertype in value.supertypes {
        ignore(assign_canonical_id(supertype, assigned, worklist))
      }
      discover_field_type(value.element, assigned, worklist)
    }
  }
}

///|
fn remap_value_type(
  value_type : @model.AbiValueType,
  assigned : Map[String, String],
) -> @model.AbiValueType {
  match value_type {
    TypedRef(source_id, nullable) =>
      match assigned.get(source_id) {
        Some(canonical_id) => @model.TypedRef(canonical_id, nullable)
        None => @model.Unknown("unreachable-type-reference")
      }
    I32 => @model.I32
    I64 => @model.I64
    F32 => @model.F32
    F64 => @model.F64
    V128 => @model.V128
    ExternRef => @model.ExternRef
    FuncRef => @model.FuncRef
    Unknown(source) => @model.Unknown(source)
  }
}

///|
fn remap_function(
  function : @model.AbiFunction,
  assigned : Map[String, String],
) -> @model.AbiFunction {
  @model.AbiFunction::{
    module_name: function.module_name,
    name: function.name,
    params: function.params.map(fn(value_type) {
      remap_value_type(value_type, assigned)
    }),
    results: function.results.map(fn(value_type) {
      remap_value_type(value_type, assigned)
    }),
  }
}

///|
fn remap_field(
  field : @model.AbiField,
  assigned : Map[String, String],
) -> @model.AbiField {
  let storage = match field.storage {
    PackedI8 => @model.PackedI8
    PackedI16 => @model.PackedI16
    Value(value_type) => @model.Value(remap_value_type(value_type, assigned))
  }
  { storage, mutable: field.mutable, }
}

///|
fn remap_supertypes(
  supertypes : Array[String],
  assigned : Map[String, String],
) -> Array[String] {
  supertypes.map(fn(source_id) {
    assigned.get(source_id).unwrap_or("unreachable-type-reference")
  })
}

///|
fn remap_definition(
  definition : @model.AbiTypeDef,
  canonical_id : String,
  assigned : Map[String, String],
) -> @model.AbiTypeDef {
  match definition {
    Struct(value) =>
      @model.Struct(@model.AbiStructType::{
        id: canonical_id,
        supertypes: remap_supertypes(value.supertypes, assigned),
        final_: value.final_,
        fields: value.fields.map(fn(field) { remap_field(field, assigned) }),
      })
    Array(value) =>
      @model.Array(@model.AbiArrayType::{
        id: canonical_id,
        supertypes: remap_supertypes(value.supertypes, assigned),
        final_: value.final_,
        element: remap_field(value.element, assigned),
      })
  }
}

///| Canonical IDs follow first reachability from the sorted public boundary.

///|
/// Source type IDs and declaration order therefore never become ABI identity.
pub fn canonicalize_host_abi(abi : @model.HostAbi) -> @model.HostAbi {
  let imports = @model.sort_abi_functions(abi.imports)
  let exports = @model.sort_abi_functions(abi.exports)
  let definitions : Map[String, @model.AbiTypeDef] = Map([])
  for definition in abi.types {
    let source_id = type_definition_id(definition)
    if definitions.get(source_id) is None {
      definitions[source_id] = definition
    }
  }

  let assigned : Map[String, String] = Map([])
  let worklist : Array[String] = []
  for function in imports {
    discover_function_types(function, assigned, worklist)
  }
  for function in exports {
    discover_function_types(function, assigned, worklist)
  }

  let mut cursor = 0
  while cursor < worklist.length() {
    let source_id = worklist[cursor]
    cursor += 1
    if definitions.get(source_id) is Some(definition) {
      discover_definition_types(definition, assigned, worklist)
    }
  }

  let canonical_types : Array[@model.AbiTypeDef] = []
  for source_id in worklist {
    guard definitions.get(source_id) is Some(definition) else { continue }
    guard assigned.get(source_id) is Some(canonical_id) else { continue }
    canonical_types.push(remap_definition(definition, canonical_id, assigned))
  }

  let features = abi.features.copy()
  features.sort_by(fn(left, right) { left.compare(right) })
  let unique_features : Array[String] = []
  for feature in features {
    if unique_features.last() != Some(feature) {
      unique_features.push(feature)
    }
  }
  @model.HostAbi::{
    schema_version: abi.schema_version,
    imports: imports.map(fn(function) { remap_function(function, assigned) }),
    exports: exports.map(fn(function) { remap_function(function, assigned) }),
    types: canonical_types,
    features: unique_features,
  }
}
