///|
pub(all) enum AbiValueType {
  I32
  I64
  F32
  F64
  V128
  ExternRef
  FuncRef
  TypedRef(String, Bool)
  Unknown(String)
} derive(Eq, Debug)

///|
pub fn AbiValueType::stable_text(self : AbiValueType) -> String {
  match self {
    I32 => "i32"
    I64 => "i64"
    F32 => "f32"
    F64 => "f64"
    V128 => "v128"
    ExternRef => "externref"
    FuncRef => "funcref"
    TypedRef(type_id, nullable) =>
      if nullable {
        "ref null \{type_id}"
      } else {
        "ref \{type_id}"
      }
    Unknown(source) => "unknown(\{source})"
  }
}

///|
pub(all) struct AbiFunction {
  module_name : String?
  name : String
  params : Array[AbiValueType]
  results : Array[AbiValueType]
} derive(Eq, Debug)

///|
pub fn AbiFunction::stable_text(self : AbiFunction) -> String {
  let function_name = match self.module_name {
    Some(module_name) => "func import \{module_name}.\{self.name}"
    None => "func export \{self.name}"
  }
  let params = self.params.map(fn(value) { value.stable_text() }).join(",")
  let results = self.results.map(fn(value) { value.stable_text() }).join(",")
  "\{function_name}(\{params})->(\{results})"
}

///|
fn AbiFunction::surface_kind_order(self : AbiFunction) -> Int {
  match self.module_name {
    Some(_) => 0
    None => 1
  }
}

///|
pub fn sort_abi_functions(functions : Array[AbiFunction]) -> Array[AbiFunction] {
  let sorted = functions.copy()
  sorted.sort_by(fn(left, right) {
    let module_order = left.module_name
      .unwrap_or("")
      .compare(right.module_name.unwrap_or(""))
    if module_order != 0 {
      module_order
    } else {
      let name_order = left.name.compare(right.name)
      if name_order != 0 {
        name_order
      } else {
        let kind_order = left.surface_kind_order() - right.surface_kind_order()
        if kind_order != 0 {
          kind_order
        } else {
          left.stable_text().compare(right.stable_text())
        }
      }
    }
  })
  sorted
}

///|
pub(all) enum AbiStorageType {
  PackedI8
  PackedI16
  Value(AbiValueType)
} derive(Eq, Debug)

///|
pub(all) struct AbiField {
  storage : AbiStorageType
  mutable : Bool
} derive(Eq, Debug)

///|
pub(all) struct AbiStructType {
  id : String
  supertypes : Array[String]
  final_ : Bool
  fields : Array[AbiField]
} derive(Eq, Debug)

///|
pub(all) struct AbiArrayType {
  id : String
  supertypes : Array[String]
  final_ : Bool
  element : AbiField
} derive(Eq, Debug)

///|
pub(all) enum AbiTypeDef {
  Struct(AbiStructType)
  Array(AbiArrayType)
} derive(Eq, Debug)

///|
pub(all) struct HostAbi {
  schema_version : Int
  imports : Array[AbiFunction]
  exports : Array[AbiFunction]
  types : Array[AbiTypeDef]
  features : Array[String]
} derive(Eq, Debug)
