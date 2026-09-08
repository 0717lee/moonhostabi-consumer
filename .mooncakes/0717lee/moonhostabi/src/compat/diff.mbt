///|
fn import_key_equal(
  left : @model.AbiFunction,
  right : @model.AbiFunction,
) -> Bool {
  left.module_name == right.module_name && left.name == right.name
}

///|
fn export_key_equal(
  left : @model.AbiFunction,
  right : @model.AbiFunction,
) -> Bool {
  left.name == right.name
}

///|
fn find_import(
  functions : Array[@model.AbiFunction],
  target : @model.AbiFunction,
) -> @model.AbiFunction? {
  for function in functions {
    if import_key_equal(function, target) {
      return Some(function)
    }
  }
  None
}

///|
fn find_export(
  functions : Array[@model.AbiFunction],
  target : @model.AbiFunction,
) -> @model.AbiFunction? {
  for function in functions {
    if export_key_equal(function, target) {
      return Some(function)
    }
  }
  None
}

///|
fn import_path(function : @model.AbiFunction) -> String {
  "imports[\{function.module_name.unwrap_or("")}.\{function.name}]"
}

///|
fn export_path(function : @model.AbiFunction) -> String {
  "exports[\{function.name}]"
}

///|
fn append_change(
  changes : Array[AbiChange],
  classification : Compatibility,
  code : String,
  path : String,
  message : String,
) -> Unit {
  changes.push({ classification, code, path, message, })
}

///|
fn strict_change_classification(policy : CompatibilityPolicy) -> Compatibility {
  if policy == Strict {
    Breaking
  } else {
    Compatible
  }
}

///|
fn append_surface_changes(
  baseline : @model.HostAbi,
  current : @model.HostAbi,
  policy : CompatibilityPolicy,
  changes : Array[AbiChange],
) -> Unit {
  let baseline_imports = @model.sort_abi_functions(baseline.imports)
  let current_imports = @model.sort_abi_functions(current.imports)
  for function in baseline_imports {
    if find_import(current_imports, function) is None {
      append_change(
        changes,
        strict_change_classification(policy),
        MHA_IMPORT_REMOVED,
        import_path(function),
        "required host import was removed",
      )
    }
  }
  for function in current_imports {
    if find_import(baseline_imports, function) is None {
      append_change(
        changes,
        Breaking,
        @model.MHA_IMPORT_ADDED,
        import_path(function),
        "new required host import was added",
      )
    }
  }

  let baseline_exports = @model.sort_abi_functions(baseline.exports)
  let current_exports = @model.sort_abi_functions(current.exports)
  for function in baseline_exports {
    if find_export(current_exports, function) is None {
      append_change(
        changes,
        Breaking,
        @model.MHA_EXPORT_REMOVED,
        export_path(function),
        "public export was removed",
      )
    }
  }
  for function in current_exports {
    if find_export(baseline_exports, function) is None {
      append_change(
        changes,
        strict_change_classification(policy),
        MHA_EXPORT_ADDED,
        export_path(function),
        "public export was added",
      )
    }
  }
}

///|
fn common_surface_abi(
  source : @model.HostAbi,
  other : @model.HostAbi,
) -> @model.HostAbi {
  let imports : Array[@model.AbiFunction] = []
  for function in source.imports {
    if find_import(other.imports, function) is Some(_) {
      imports.push(function)
    }
  }
  let exports : Array[@model.AbiFunction] = []
  for function in source.exports {
    if find_export(other.exports, function) is Some(_) {
      exports.push(function)
    }
  }
  @model.HostAbi::{
    schema_version: source.schema_version,
    imports,
    exports,
    types: source.types,
    features: [],
  }
}

///|
fn typed_ref_involved(
  baseline : @model.AbiValueType,
  current : @model.AbiValueType,
) -> Bool {
  match (baseline, current) {
    (@model.TypedRef(_, _), _) | (_, @model.TypedRef(_, _)) => true
    _ => false
  }
}

///|
fn append_value_list_changes(
  baseline : Array[@model.AbiValueType],
  current : Array[@model.AbiValueType],
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  if baseline.length() != current.length() {
    append_change(
      changes,
      Breaking,
      @model.MHA_SIGNATURE_CHANGED,
      path,
      "function value count changed",
    )
    return
  }
  for index, baseline_value in baseline {
    let current_value = current[index]
    if baseline_value != current_value {
      append_change(
        changes,
        Breaking,
        if typed_ref_involved(baseline_value, current_value) {
          @model.MHA_GC_TYPE_CHANGED
        } else {
          @model.MHA_SIGNATURE_CHANGED
        },
        "\{path}[\{index}]",
        "function value type changed",
      )
    }
  }
}

///|
fn append_function_changes(
  baseline : @model.AbiFunction,
  current : @model.AbiFunction,
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  append_value_list_changes(
    baseline.params,
    current.params,
    "\{path}.params",
    changes,
  )
  append_value_list_changes(
    baseline.results,
    current.results,
    "\{path}.results",
    changes,
  )
}

///|
fn append_common_function_changes(
  baseline : @model.HostAbi,
  current : @model.HostAbi,
  changes : Array[AbiChange],
) -> Unit {
  for baseline_function in baseline.imports {
    if find_import(current.imports, baseline_function) is Some(current_function) {
      append_function_changes(
        baseline_function,
        current_function,
        import_path(baseline_function),
        changes,
      )
    }
  }
  for baseline_function in baseline.exports {
    if find_export(current.exports, baseline_function) is Some(current_function) {
      append_function_changes(
        baseline_function,
        current_function,
        export_path(baseline_function),
        changes,
      )
    }
  }
}

///|
fn type_definition_id(definition : @model.AbiTypeDef) -> String {
  match definition {
    Struct(value) => value.id
    Array(value) => value.id
  }
}

///|
fn find_type_definition(
  definitions : Array[@model.AbiTypeDef],
  id : String,
) -> @model.AbiTypeDef? {
  for definition in definitions {
    if type_definition_id(definition) == id {
      return Some(definition)
    }
  }
  None
}

///|
fn append_string_list_changes(
  baseline : Array[String],
  current : Array[String],
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  if baseline.length() != current.length() {
    append_change(
      changes,
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      path,
      "GC type reference count changed",
    )
    return
  }
  for index, baseline_value in baseline {
    if baseline_value != current[index] {
      append_change(
        changes,
        Breaking,
        @model.MHA_GC_TYPE_CHANGED,
        "\{path}[\{index}]",
        "GC type reference changed",
      )
    }
  }
}

///|
fn append_field_changes(
  baseline : @model.AbiField,
  current : @model.AbiField,
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  if baseline.storage != current.storage {
    append_change(
      changes,
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      "\{path}.storage",
      "GC field storage type changed",
    )
  }
  if baseline.mutable != current.mutable {
    append_change(
      changes,
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      "\{path}.mutable",
      "GC field mutability changed",
    )
  }
}

///|
fn append_fields_changes(
  baseline : Array[@model.AbiField],
  current : Array[@model.AbiField],
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  if baseline.length() != current.length() {
    append_change(
      changes,
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      path,
      "GC field count changed",
    )
    return
  }
  for index, baseline_field in baseline {
    append_field_changes(
      baseline_field,
      current[index],
      "\{path}[\{index}]",
      changes,
    )
  }
}

///|
fn append_struct_changes(
  baseline : @model.AbiStructType,
  current : @model.AbiStructType,
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  if baseline.final_ != current.final_ {
    append_change(
      changes,
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      "\{path}.final",
      "GC struct finality changed",
    )
  }
  append_string_list_changes(
    baseline.supertypes,
    current.supertypes,
    "\{path}.supertypes",
    changes,
  )
  append_fields_changes(
    baseline.fields,
    current.fields,
    "\{path}.fields",
    changes,
  )
}

///|
fn append_array_changes(
  baseline : @model.AbiArrayType,
  current : @model.AbiArrayType,
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  if baseline.final_ != current.final_ {
    append_change(
      changes,
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      "\{path}.final",
      "GC array finality changed",
    )
  }
  append_string_list_changes(
    baseline.supertypes,
    current.supertypes,
    "\{path}.supertypes",
    changes,
  )
  append_field_changes(
    baseline.element,
    current.element,
    "\{path}.element",
    changes,
  )
}

///|
fn append_type_definition_changes(
  baseline : @model.AbiTypeDef,
  current : @model.AbiTypeDef,
  changes : Array[AbiChange],
) -> Unit {
  let path = "types[\{type_definition_id(baseline)}]"
  match (baseline, current) {
    (Struct(baseline_value), Struct(current_value)) =>
      append_struct_changes(baseline_value, current_value, path, changes)
    (Array(baseline_value), Array(current_value)) =>
      append_array_changes(baseline_value, current_value, path, changes)
    _ =>
      append_change(
        changes,
        Breaking,
        @model.MHA_GC_TYPE_CHANGED,
        "\{path}.kind",
        "GC type kind changed",
      )
  }
}

///|
fn append_gc_type_changes(
  baseline : @model.HostAbi,
  current : @model.HostAbi,
  changes : Array[AbiChange],
) -> Unit {
  for baseline_definition in baseline.types {
    let id = type_definition_id(baseline_definition)
    match find_type_definition(current.types, id) {
      Some(current_definition) =>
        append_type_definition_changes(
          baseline_definition, current_definition, changes,
        )
      None =>
        append_change(
          changes,
          Breaking,
          @model.MHA_GC_TYPE_CHANGED,
          "types[\{id}]",
          "reachable GC type was removed",
        )
    }
  }
  for current_definition in current.types {
    let id = type_definition_id(current_definition)
    if find_type_definition(baseline.types, id) is None {
      append_change(
        changes,
        Breaking,
        @model.MHA_GC_TYPE_CHANGED,
        "types[\{id}]",
        "reachable GC type was added",
      )
    }
  }
}

///|
fn append_unknown_feature_changes(
  baseline : @model.HostAbi,
  current : @model.HostAbi,
  changes : Array[AbiChange],
) -> Unit {
  let features = baseline.features.copy()
  for feature in current.features {
    features.push(feature)
  }
  features.sort_by(fn(left, right) { left.compare(right) })
  let mut previous : String? = None
  for feature in features {
    if feature != "moonbit.make_closure" && previous != Some(feature) {
      append_change(
        changes,
        Unknown,
        MHA_FEATURE_UNSUPPORTED,
        "features[\{feature}]",
        "Host ABI feature is not supported by this compatibility policy",
      )
    }
    previous = Some(feature)
  }
}

///|
fn has_change(changes : Array[AbiChange], code : String, path : String) -> Bool {
  for change in changes {
    if change.code == code && change.path == path {
      return true
    }
  }
  false
}

///|
fn append_unknown_value(
  value : @model.AbiValueType,
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  if value is @model.Unknown(source) {
    if !has_change(changes, @model.MHA_PROJECT_UNREPRESENTABLE, path) {
      append_change(
        changes,
        Unknown,
        @model.MHA_PROJECT_UNREPRESENTABLE,
        path,
        "unsupported ABI value type: \{source}",
      )
    }
  }
}

///|
fn append_unknown_function_values(
  function : @model.AbiFunction,
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  for index, value in function.params {
    append_unknown_value(value, "\{path}.params[\{index}]", changes)
  }
  for index, value in function.results {
    append_unknown_value(value, "\{path}.results[\{index}]", changes)
  }
}

///|
fn append_unknown_field_value(
  field : @model.AbiField,
  path : String,
  changes : Array[AbiChange],
) -> Unit {
  if field.storage is Value(value) {
    append_unknown_value(value, "\{path}.storage", changes)
  }
}

///|
fn append_unknown_values(
  abi : @model.HostAbi,
  changes : Array[AbiChange],
) -> Unit {
  let canonical = @lockfile.canonicalize_host_abi(abi)
  for function in canonical.imports {
    append_unknown_function_values(function, import_path(function), changes)
  }
  for function in canonical.exports {
    append_unknown_function_values(function, export_path(function), changes)
  }
  for definition in canonical.types {
    match definition {
      Struct(value) =>
        for index, field in value.fields {
          append_unknown_field_value(
            field,
            "types[\{value.id}].fields[\{index}]",
            changes,
          )
        }
      Array(value) =>
        append_unknown_field_value(
          value.element,
          "types[\{value.id}].element",
          changes,
        )
    }
  }
}

///|
fn compatibility_rank(value : Compatibility) -> Int {
  match value {
    Compatible => 0
    Breaking => 1
    Unknown => 2
  }
}

///|
fn finalize_report(changes : Array[AbiChange]) -> CompatibilityReport {
  changes.sort_by(fn(left, right) {
    let path_order = left.path.compare(right.path)
    if path_order != 0 {
      path_order
    } else {
      let code_order = left.code.compare(right.code)
      if code_order != 0 {
        code_order
      } else {
        let classification_order = compatibility_rank(left.classification) -
          compatibility_rank(right.classification)
        if classification_order != 0 {
          classification_order
        } else {
          left.message.compare(right.message)
        }
      }
    }
  })
  let mut classification = Compatible
  for change in changes {
    if compatibility_rank(change.classification) >
      compatibility_rank(classification) {
      classification = change.classification
    }
  }
  { classification, changes, }
}

///|
pub fn compare_host_abi(
  baseline : @model.HostAbi,
  current : @model.HostAbi,
  policy : CompatibilityPolicy,
) -> CompatibilityReport {
  let changes : Array[AbiChange] = []
  if baseline.schema_version != 1 || current.schema_version != 1 {
    append_change(
      changes,
      Unknown,
      MHA_SCHEMA_UNSUPPORTED,
      "schemaVersion",
      "Host ABI schema version changed",
    )
  }
  append_surface_changes(baseline, current, policy, changes)
  let canonical_baseline = @lockfile.canonicalize_host_abi(
    common_surface_abi(baseline, current),
  )
  let canonical_current = @lockfile.canonicalize_host_abi(
    common_surface_abi(current, baseline),
  )
  append_common_function_changes(canonical_baseline, canonical_current, changes)
  append_gc_type_changes(canonical_baseline, canonical_current, changes)
  append_unknown_feature_changes(baseline, current, changes)
  append_unknown_values(current, changes)
  append_unknown_values(baseline, changes)
  finalize_report(changes)
}

///|
pub fn compare_host_abi_with_diagnostics(
  baseline : @model.HostAbi,
  current : @model.HostAbi,
  diagnostics : Array[@model.Diagnostic],
  policy : CompatibilityPolicy,
) -> CompatibilityReport {
  let report = compare_host_abi(baseline, current, policy)
  let changes = report.changes
  for diagnostic in diagnostics {
    append_change(
      changes,
      Unknown,
      diagnostic.code,
      diagnostic.path,
      diagnostic.message,
    )
  }
  finalize_report(changes)
}

///|
pub fn compare_lockfiles(
  baseline : @lockfile.AbiLockfile,
  current : @lockfile.AbiLockfile,
  policy : CompatibilityPolicy,
) -> CompatibilityReport {
  compare_host_abi(baseline.canonical_abi(), current.canonical_abi(), policy)
}
