///|
fn empty_abi() -> @model.HostAbi {
  @model.HostAbi::{
    schema_version: 1,
    imports: [],
    exports: [],
    types: [],
    features: [],
  }
}

///|
fn scalar_function(
  module_name : String?,
  name : String,
  params : Array[@model.AbiValueType],
  results : Array[@model.AbiValueType],
) -> @model.AbiFunction {
  @model.AbiFunction::{ module_name, name, params, results, }
}

///|
fn assert_single_change(
  report : CompatibilityReport,
  classification : Compatibility,
  code : String,
  path : String,
) -> Unit raise {
  inspect(report.classification == classification, content="true")
  inspect(report.changes.length(), content="1")
  inspect(report.changes[0].classification == classification, content="true")
  inspect(report.changes[0].code, content=code)
  inspect(report.changes[0].path, content=path)
}

///|
test "adding an export is semantic-compatible and strict-breaking" {
  let baseline = empty_abi()
  let current = empty_abi()
  current.exports.push(scalar_function(None, "add", [@model.I32], [@model.I32]))
  assert_single_change(
    compare_host_abi(baseline, current, semantic_policy()),
    Compatible,
    MHA_EXPORT_ADDED,
    "exports[add]",
  )
  assert_single_change(
    compare_host_abi(baseline, current, strict_policy()),
    Breaking,
    MHA_EXPORT_ADDED,
    "exports[add]",
  )
}

///|
test "removing an export is always breaking" {
  let baseline = empty_abi()
  baseline.exports.push(scalar_function(None, "render", [], [@model.ExternRef]))
  let current = empty_abi()
  for policy in [semantic_policy(), strict_policy()] {
    assert_single_change(
      compare_host_abi(baseline, current, policy),
      Breaking,
      @model.MHA_EXPORT_REMOVED,
      "exports[render]",
    )
  }
}

///|
test "removing an import is semantic-compatible and strict-breaking" {
  let baseline = empty_abi()
  baseline.imports.push(scalar_function(Some("clock"), "now", [], [@model.F64]))
  let current = empty_abi()
  assert_single_change(
    compare_host_abi(baseline, current, semantic_policy()),
    Compatible,
    MHA_IMPORT_REMOVED,
    "imports[clock.now]",
  )
  assert_single_change(
    compare_host_abi(baseline, current, strict_policy()),
    Breaking,
    MHA_IMPORT_REMOVED,
    "imports[clock.now]",
  )
}

///|
test "adding a required import is always breaking" {
  let baseline = empty_abi()
  let current = empty_abi()
  current.imports.push(
    scalar_function(Some("host"), "echo", [@model.ExternRef], [@model.ExternRef]),
  )
  for policy in [semantic_policy(), strict_policy()] {
    assert_single_change(
      compare_host_abi(baseline, current, policy),
      Breaking,
      @model.MHA_IMPORT_ADDED,
      "imports[host.echo]",
    )
  }
}

///|
test "function parameter and result changes report exact paths" {
  let baseline = empty_abi()
  baseline.exports.push(
    scalar_function(None, "convert", [@model.I32], [@model.I32]),
  )
  let current = empty_abi()
  current.exports.push(
    scalar_function(None, "convert", [@model.I64], [@model.F64]),
  )
  for policy in [semantic_policy(), strict_policy()] {
    let report = compare_host_abi(baseline, current, policy)
    inspect(report.classification == Breaking, content="true")
    inspect(report.changes.length(), content="2")
    inspect(report.changes[0].code, content="MHA_SIGNATURE_CHANGED")
    inspect(report.changes[0].path, content="exports[convert].params[0]")
    inspect(report.changes[1].code, content="MHA_SIGNATURE_CHANGED")
    inspect(report.changes[1].path, content="exports[convert].results[0]")
  }
}

///|
fn ref_abi(
  source_id : String,
  nullable : Bool,
  definition : @model.AbiTypeDef,
) -> @model.HostAbi {
  let abi = empty_abi()
  abi.exports.push(
    scalar_function(None, "consume", [@model.TypedRef(source_id, nullable)], []),
  )
  abi.types.push(definition)
  abi
}

///|
fn empty_struct(id : String) -> @model.AbiTypeDef {
  @model.Struct(@model.AbiStructType::{
    id,
    supertypes: [],
    final_: true,
    fields: [],
  })
}

///|
test "ref nullability and heap type changes are breaking" {
  let nullable = ref_abi("old", true, empty_struct("old"))
  let non_nullable = ref_abi("new", false, empty_struct("new"))
  for policy in [semantic_policy(), strict_policy()] {
    assert_single_change(
      compare_host_abi(nullable, non_nullable, policy),
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      "exports[consume].params[0]",
    )
  }

  let array = @model.Array(@model.AbiArrayType::{
    id: "array",
    supertypes: [],
    final_: true,
    element: { storage: @model.PackedI8, mutable: false, },
  })
  for policy in [semantic_policy(), strict_policy()] {
    assert_single_change(
      compare_host_abi(nullable, ref_abi("array", true, array), policy),
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      "types[type[0]].kind",
    )
  }
}

///|
fn field_abi(storage : @model.AbiStorageType) -> @model.HostAbi {
  let definition = @model.Struct(@model.AbiStructType::{
    id: "node",
    supertypes: [],
    final_: false,
    fields: [{ storage, mutable: false, }],
  })
  ref_abi("node", false, definition)
}

///|
test "reachable GC field changes are always breaking" {
  for policy in [semantic_policy(), strict_policy()] {
    assert_single_change(
      compare_host_abi(
        field_abi(@model.Value(@model.I32)),
        field_abi(@model.Value(@model.I64)),
        policy,
      ),
      Breaking,
      @model.MHA_GC_TYPE_CHANGED,
      "types[type[0]].fields[0].storage",
    )
  }
}

///|
test "unreachable private type changes are compatible in both policies" {
  let baseline = empty_abi()
  baseline.exports.push(scalar_function(None, "value", [], [@model.I32]))
  baseline.types.push(empty_struct("private-old"))
  let current = empty_abi()
  current.exports.push(scalar_function(None, "value", [], [@model.I32]))
  current.types.push(
    @model.Array(@model.AbiArrayType::{
      id: "private-new",
      supertypes: [],
      final_: false,
      element: { storage: @model.PackedI16, mutable: true, },
    }),
  )
  for policy in [semantic_policy(), strict_policy()] {
    let report = compare_host_abi(baseline, current, policy)
    inspect(report.classification == Compatible, content="true")
    inspect(report.changes.length(), content="0")
  }
}

///|
test "unsupported projection diagnostics fail closed as unknown" {
  let diagnostic = @model.Diagnostic::{
    code: @model.MHA_PROJECT_UNSUPPORTED_ITEM,
    severity: @model.Error,
    path: "imports[env.memory]",
    message: "public memory import is not supported",
    byte_offset: None,
  }
  for policy in [semantic_policy(), strict_policy()] {
    assert_single_change(
      compare_host_abi_with_diagnostics(
        empty_abi(),
        empty_abi(),
        [diagnostic],
        policy,
      ),
      Unknown,
      @model.MHA_PROJECT_UNSUPPORTED_ITEM,
      "imports[env.memory]",
    )
  }
}

///|
test "unknown feature and schema versions fail closed" {
  let baseline = empty_abi()
  let feature_current = empty_abi()
  feature_current.features.push("future.host-feature")
  assert_single_change(
    compare_host_abi(baseline, feature_current, semantic_policy()),
    Unknown,
    MHA_FEATURE_UNSUPPORTED,
    "features[future.host-feature]",
  )

  let schema_current = @model.HostAbi::{
    schema_version: 2,
    imports: [],
    exports: [],
    types: [],
    features: [],
  }
  assert_single_change(
    compare_host_abi(baseline, schema_current, strict_policy()),
    Unknown,
    MHA_SCHEMA_UNSUPPORTED,
    "schemaVersion",
  )
}

///|
test "unknown boundary values fail closed without external diagnostics" {
  let current = empty_abi()
  current.exports.push(
    scalar_function(None, "mystery", [@model.Unknown("value_type.anyref")], []),
  )
  let report = compare_host_abi(empty_abi(), current, semantic_policy())
  inspect(report.classification == Unknown, content="true")
  inspect(report.changes.length(), content="2")
  inspect(report.changes[0].code, content="MHA_EXPORT_ADDED")
  inspect(report.changes[0].path, content="exports[mystery]")
  inspect(report.changes[1].code, content="MHA_PROJECT_UNREPRESENTABLE")
  inspect(report.changes[1].path, content="exports[mystery].params[0]")
}

///|
test "function arity changes identify the parameter container" {
  let baseline = empty_abi()
  baseline.exports.push(
    scalar_function(None, "sum", [@model.I32], [@model.I32]),
  )
  let current = empty_abi()
  current.exports.push(
    scalar_function(None, "sum", [@model.I32, @model.I32], [@model.I32]),
  )
  assert_single_change(
    compare_host_abi(baseline, current, semantic_policy()),
    Breaking,
    @model.MHA_SIGNATURE_CHANGED,
    "exports[sum].params",
  )
}

///|
test "artifact provenance does not affect compatibility classification" {
  let abi = empty_abi()
  abi.exports.push(scalar_function(None, "answer", [], [@model.I32]))
  let baseline = @lockfile.create_lockfile(abi, b"artifact-one")
  let current = @lockfile.create_lockfile(abi, b"artifact-two")
  for policy in [semantic_policy(), strict_policy()] {
    let report = compare_lockfiles(baseline, current, policy)
    inspect(report.classification == Compatible, content="true")
    inspect(report.changes.length(), content="0")
  }
}

///|
test "compatible typed export addition cannot reindex an existing surface" {
  let baseline = ref_abi("existing", false, empty_struct("existing"))
  let current = ref_abi(
    "existing-new-index",
    false,
    empty_struct("existing-new-index"),
  )
  current.exports.push(
    scalar_function(None, "aaa_new", [], [@model.TypedRef("added", false)]),
  )
  current.types.push(
    @model.Array(@model.AbiArrayType::{
      id: "added",
      supertypes: [],
      final_: true,
      element: { storage: @model.PackedI8, mutable: false, },
    }),
  )
  assert_single_change(
    compare_host_abi(baseline, current, semantic_policy()),
    Compatible,
    MHA_EXPORT_ADDED,
    "exports[aaa_new]",
  )
}

///|
test "compiled breaking fixtures report the seeded signature path" {
  let baseline_module = @wasm_adapter.parse_artifact(
    @fs.read_file_to_bytes("fixtures/artifacts/breaking_v1.wasm"),
  )
  let current_module = @wasm_adapter.parse_artifact(
    @fs.read_file_to_bytes("fixtures/artifacts/breaking_v2.wasm"),
  )
  let baseline = @projector.analyze_host_abi(
    baseline_module,
    @projector.default_js_capability_policy(),
  )
  let current = @projector.analyze_host_abi(
    current_module,
    @projector.default_js_capability_policy(),
  )
  inspect(baseline.diagnostics.length(), content="0")
  inspect(current.diagnostics.length(), content="0")
  assert_single_change(
    compare_host_abi(baseline.abi, current.abi, semantic_policy()),
    Breaking,
    @model.MHA_SIGNATURE_CHANGED,
    "exports[add].params",
  )
}
