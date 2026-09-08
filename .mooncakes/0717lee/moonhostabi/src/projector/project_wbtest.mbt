///|
test "scalar imports and exports use the Wasm function index space" {
  let wasm_module = @wasm_types.Module::Module()
  wasm_module.types.push(@wasm_types.SubType::func([], [F64]))
  wasm_module.types.push(@wasm_types.SubType::func([I64], [I64]))
  wasm_module.types.push(@wasm_types.SubType::func([I32, I32], [I32]))
  wasm_module.imports.push({
    mod_name: "env",
    name: "now",
    desc: @wasm_types.ImportDesc::Func(0),
  })
  wasm_module.funcs.push(2)
  wasm_module.funcs.push(1)
  wasm_module.exports.push({
    name: "add",
    desc: @wasm_types.ExportDesc::Func(1),
  })

  let abi = project_host_abi(wasm_module)

  inspect(abi.schema_version, content="1")
  inspect(abi.imports.length(), content="1")
  inspect(abi.exports.length(), content="1")
  inspect(abi.types.length(), content="0")
  inspect(abi.features.length(), content="0")
  inspect(abi.imports[0].stable_text(), content="func import env.now()->(f64)")
  inspect(
    abi.exports[0].stable_text(),
    content="func export add(i32,i32)->(i32)",
  )
}

///|
test "value types map without erasing unsupported variants" {
  inspect(map_value_type(I32, [0, 1]).stable_text(), content="i32")
  inspect(map_value_type(I64, [0, 1]).stable_text(), content="i64")
  inspect(map_value_type(F32, [0, 1]).stable_text(), content="f32")
  inspect(map_value_type(F64, [0, 1]).stable_text(), content="f64")
  inspect(map_value_type(V128, [0, 1]).stable_text(), content="v128")
  inspect(map_value_type(ExternRef, [0, 1]).stable_text(), content="externref")
  inspect(map_value_type(RefExtern, [0, 1]).stable_text(), content="externref")
  inspect(map_value_type(FuncRef, [0, 1]).stable_text(), content="funcref")
  inspect(
    map_value_type(RefStruct(1), [0, 7]).stable_text(),
    content="ref type[7]",
  )
  inspect(
    map_value_type(RefNullArray(1), [0, 7]).stable_text(),
    content="ref null type[7]",
  )
  inspect(
    map_value_type(AnyRef, [0, 1]).stable_text(),
    content="unknown(value_type.anyref)",
  )
}

///|
test "function index lookup covers imported defined and invalid indices" {
  let wasm_module = @wasm_types.Module::Module()
  wasm_module.types.push(@wasm_types.SubType::func([], [F64]))
  wasm_module.types.push(@wasm_types.SubType::func([], [I64]))
  wasm_module.types.push(@wasm_types.SubType::func([], [I32]))
  wasm_module.imports.push({
    mod_name: "clock",
    name: "now",
    desc: @wasm_types.ImportDesc::Func(0),
  })
  wasm_module.imports.push({
    mod_name: "clock",
    name: "ticks",
    desc: @wasm_types.ImportDesc::Func(1),
  })
  wasm_module.funcs.push(2)

  guard function_type_at_index(wasm_module, 0) is Some(first_import) else {
    fail("expected first imported function type")
  }
  guard function_type_at_index(wasm_module, 1) is Some(second_import) else {
    fail("expected second imported function type")
  }
  guard function_type_at_index(wasm_module, 2) is Some(defined) else {
    fail("expected defined function type")
  }
  debug_inspect(first_import.results, content="[F64]")
  debug_inspect(second_import.results, content="[I64]")
  debug_inspect(defined.results, content="[I32]")
  assert_true(function_type_at_index(wasm_module, -1) is None)
  assert_true(function_type_at_index(wasm_module, 3) is None)
}

///|
test "an exported imported function keeps its imported signature" {
  let wasm_module = @wasm_types.Module::Module()
  wasm_module.types.push(@wasm_types.SubType::func([], [F64]))
  wasm_module.imports.push({
    mod_name: "clock",
    name: "now",
    desc: @wasm_types.ImportDesc::Func(0),
  })
  wasm_module.exports.push({
    name: "public_now",
    desc: @wasm_types.ExportDesc::Func(0),
  })

  let abi = project_host_abi(wasm_module)
  inspect(
    abi.exports[0].stable_text(),
    content="func export public_now()->(f64)",
  )
}

///|
test "all typed refs preserve canonical identity and nullability" {
  let canonical = [9]
  inspect(
    map_value_type(RefFuncTyped(0), canonical).stable_text(),
    content="ref type[9]",
  )
  inspect(
    map_value_type(RefNullFuncTyped(0), canonical).stable_text(),
    content="ref null type[9]",
  )
  inspect(
    map_value_type(RefStruct(0), canonical).stable_text(),
    content="ref type[9]",
  )
  inspect(
    map_value_type(RefNullStruct(0), canonical).stable_text(),
    content="ref null type[9]",
  )
  inspect(
    map_value_type(RefArray(0), canonical).stable_text(),
    content="ref type[9]",
  )
  inspect(
    map_value_type(RefNullArray(0), canonical).stable_text(),
    content="ref null type[9]",
  )
  inspect(
    map_value_type(RefStruct(-1), canonical).stable_text(),
    content="unknown(types[-1])",
  )
  inspect(
    map_value_type(RefNullArray(1), canonical).stable_text(),
    content="unknown(types[1])",
  )
}

///|
test "MoonBit make_closure import is recorded as a feature" {
  let wasm_module = @wasm_types.Module::Module()
  wasm_module.types.push(
    @wasm_types.SubType::func([FuncRef, ExternRef], [FuncRef]),
  )
  wasm_module.imports.push({
    mod_name: "moonbit:ffi",
    name: "make_closure",
    desc: @wasm_types.ImportDesc::Func(0),
  })

  let abi = project_host_abi(wasm_module)

  debug_inspect(abi.features, content="[\"moonbit.make_closure\"]")
}

///|
test "MoonBit make_closure feature requires a function import" {
  let wasm_module = @wasm_types.Module::Module()
  wasm_module.imports.push({
    mod_name: "moonbit:ffi",
    name: "make_closure",
    desc: @wasm_types.ImportDesc::Global(@wasm_types.GlobalType::{
      value_type: I32,
      mutable: false,
    }),
  })

  let abi = project_host_abi(wasm_module)

  debug_inspect(abi.features, content="[]")
}

///|
test "MoonBit externref remains opaque and uses an explicit symbolic name" {
  let default_policy = default_js_capability_policy()
  let (unnamed, unnamed_diagnostic) = classify_js_value_type(
    @model.ExternRef,
    "imports[host.echo].params[0]",
    default_policy,
  )
  debug_inspect(unnamed, content="Opaque(\"unknown\")")
  assert_true(unnamed_diagnostic is None)

  let named_policy = JsCapabilityPolicy::{
    allow_typed_gc_refs: false,
    allow_v128: false,
    externref_symbol: Some("HostToken"),
  }
  let (named, named_diagnostic) = classify_js_value_type(
    @model.ExternRef,
    "imports[host.echo].params[0]",
    named_policy,
  )
  debug_inspect(named, content="Opaque(\"HostToken\")")
  assert_true(named_diagnostic is None)
}

///|
test "MoonBit typed GC refs and v128 fail JavaScript representation by default" {
  let policy = default_js_capability_policy()
  let (_, typed_ref_diagnostic) = classify_js_value_type(
    @model.TypedRef("type[4]", false),
    "imports[host.consume].params[0]",
    policy,
  )
  let (_, v128_diagnostic) = classify_js_value_type(
    @model.V128,
    "imports[host.consume].params[1]",
    policy,
  )
  guard typed_ref_diagnostic is Some(typed_ref_error) else {
    fail("expected typed GC ref diagnostic")
  }
  guard v128_diagnostic is Some(v128_error) else {
    fail("expected v128 diagnostic")
  }
  inspect(typed_ref_error.code, content="MHA_PROJECT_UNREPRESENTABLE")
  inspect(typed_ref_error.path, content="imports[host.consume].params[0]")
  inspect(v128_error.code, content="MHA_PROJECT_UNREPRESENTABLE")
  inspect(v128_error.path, content="imports[host.consume].params[1]")
}

///|
test "MoonBit analysis diagnoses unrepresentable public boundary values" {
  let wasm_module = @wasm_types.Module::Module()
  wasm_module.types.push(
    @wasm_types.SubType::simple(
      @wasm_types.CompositeType::Struct(@wasm_types.StructType::{ fields: [], }),
    ),
  )
  wasm_module.types.push(@wasm_types.SubType::func([RefStruct(0), V128], []))
  wasm_module.imports.push({
    mod_name: "host",
    name: "consume",
    desc: @wasm_types.ImportDesc::Func(1),
  })

  let analysis = analyze_host_abi(wasm_module, default_js_capability_policy())

  inspect(analysis.abi.imports.length(), content="1")
  inspect(analysis.diagnostics.length(), content="2")
  inspect(
    analysis.diagnostics[0].path,
    content="imports[host.consume].params[0]",
  )
  inspect(
    analysis.diagnostics[1].path,
    content="imports[host.consume].params[1]",
  )
}

///|
test "MoonBit capability policy can explicitly allow typed refs and v128" {
  let policy = JsCapabilityPolicy::{
    allow_typed_gc_refs: true,
    allow_v128: true,
    externref_symbol: None,
  }
  let (typed_ref, typed_ref_diagnostic) = classify_js_value_type(
    @model.TypedRef("type[4]", true),
    "exports.value.results[0]",
    policy,
  )
  let (v128, v128_diagnostic) = classify_js_value_type(
    @model.V128,
    "exports.vector.results[0]",
    policy,
  )
  debug_inspect(typed_ref, content="Opaque(\"type[4]\")")
  debug_inspect(v128, content="Opaque(\"v128\")")
  assert_true(typed_ref_diagnostic is None)
  assert_true(v128_diagnostic is None)
}

///|
test "recursive GC projection preserves fields supertypes and finite edges" {
  let wasm_module = @wasm_types.Module::Module()
  let base_struct = @wasm_types.SubType::simple(
    @wasm_types.CompositeType::Struct(@wasm_types.StructType::{
      fields: [
        {
          storage_type: @wasm_types.StorageType::Packed(
            @wasm_types.PackedType::I8,
          ),
          mutable: false,
        },
      ],
    }),
  )
  let recursive_struct = @wasm_types.SubType::{
    final_: false,
    supertypes: [0],
    composite: @wasm_types.CompositeType::Struct(@wasm_types.StructType::{
      fields: [
        {
          storage_type: @wasm_types.StorageType::Val(RefNullStruct(1)),
          mutable: false,
        },
        {
          storage_type: @wasm_types.StorageType::Packed(
            @wasm_types.PackedType::I16,
          ),
          mutable: true,
        },
      ],
    }),
  }
  let array_type = @wasm_types.SubType::simple(
    @wasm_types.CompositeType::Array(@wasm_types.ArrayType::{
      element: {
        storage_type: @wasm_types.StorageType::Val(RefStruct(1)),
        mutable: false,
      },
    }),
  )
  let private_struct = @wasm_types.SubType::simple(
    @wasm_types.CompositeType::Struct(@wasm_types.StructType::{ fields: [], }),
  )
  let exported_function = @wasm_types.SubType::func([], [RefArray(2)])
  wasm_module.types.push(base_struct)
  wasm_module.types.push(recursive_struct)
  wasm_module.types.push(array_type)
  wasm_module.types.push(private_struct)
  wasm_module.types.push(exported_function)
  for group in [0, 1, 2, 3, 4] {
    wasm_module.type_rec_groups.push(group)
  }
  wasm_module.funcs.push(4)
  wasm_module.exports.push({
    name: "nodes",
    desc: @wasm_types.ExportDesc::Func(0),
  })

  let abi = project_host_abi(wasm_module)

  inspect(abi.types.length(), content="3")
  guard abi.types[0] is @model.Struct(base) else {
    fail("expected reachable base struct")
  }
  guard abi.types[1] is @model.Struct(recursive) else {
    fail("expected reachable recursive struct")
  }
  guard abi.types[2] is @model.Array(array) else {
    fail("expected reachable array")
  }
  inspect(base.id, content="type[0]")
  debug_inspect(base.supertypes, content="[]")
  inspect(base.final_, content="true")
  debug_inspect(base.fields[0].storage, content="PackedI8")
  inspect(base.fields[0].mutable, content="false")
  inspect(recursive.id, content="type[1]")
  debug_inspect(recursive.supertypes, content="[\"type[0]\"]")
  inspect(recursive.final_, content="false")
  inspect(recursive.fields.length(), content="2")
  debug_inspect(
    recursive.fields[0].storage,
    content="Value(TypedRef(\"type[1]\", true))",
  )
  inspect(recursive.fields[0].mutable, content="false")
  debug_inspect(recursive.fields[1].storage, content="PackedI16")
  inspect(recursive.fields[1].mutable, content="true")
  inspect(array.id, content="type[2]")
  debug_inspect(array.supertypes, content="[]")
  debug_inspect(
    array.element.storage,
    content="Value(TypedRef(\"type[1]\", false))",
  )
  inspect(array.element.mutable, content="false")
}

///|
test "non-function public ABI items produce explicit diagnostics" {
  let wasm_module = @wasm_types.Module::Module()
  let limits = @wasm_types.Limits::{ min: 1L, max: None, }
  let table = @wasm_types.TableType::{
    elem_type: ExternRef,
    limits,
    is_table64: false,
  }
  let memory = @wasm_types.MemoryType::{
    limits,
    is_memory64: false,
    page_size_log2: 16,
  }
  let global = @wasm_types.GlobalType::{ value_type: I32, mutable: false, }
  wasm_module.imports.push({
    mod_name: "env",
    name: "table",
    desc: @wasm_types.ImportDesc::Table(table),
  })
  wasm_module.imports.push({
    mod_name: "env",
    name: "memory",
    desc: @wasm_types.ImportDesc::Memory(memory),
  })
  wasm_module.imports.push({
    mod_name: "env",
    name: "global",
    desc: @wasm_types.ImportDesc::Global(global),
  })
  wasm_module.imports.push({
    mod_name: "env",
    name: "tag",
    desc: @wasm_types.ImportDesc::Tag(0),
  })
  wasm_module.exports.push({
    name: "table",
    desc: @wasm_types.ExportDesc::Table(0),
  })
  wasm_module.exports.push({
    name: "memory",
    desc: @wasm_types.ExportDesc::Memory(0),
  })
  wasm_module.exports.push({
    name: "global",
    desc: @wasm_types.ExportDesc::Global(0),
  })
  wasm_module.exports.push({
    name: "tag",
    desc: @wasm_types.ExportDesc::Tag(0),
  })

  let analysis = analyze_host_abi(wasm_module, default_js_capability_policy())

  inspect(analysis.diagnostics.length(), content="8")
  for diagnostic in analysis.diagnostics {
    inspect(diagnostic.code, content="MHA_PROJECT_UNSUPPORTED_ITEM")
  }
  inspect(analysis.diagnostics[0].path, content="imports[env.table]")
  inspect(analysis.diagnostics[3].path, content="imports[env.tag]")
  inspect(analysis.diagnostics[4].path, content="exports[table]")
  inspect(analysis.diagnostics[7].path, content="exports[tag]")
}

///|
test "wasm_core projects the real MoonBit recursive GC artifact" {
  let wasm_module = @wasm_adapter.parse_artifact(
    @fs.read_file_to_bytes("fixtures/artifacts/recursive.wasm"),
  )
  let analysis = analyze_host_abi(wasm_module, JsCapabilityPolicy::{
    allow_typed_gc_refs: true,
    allow_v128: false,
    externref_symbol: None,
  })
  inspect(analysis.diagnostics.length(), content="0")
  inspect(analysis.abi.exports.length(), content="2")
  inspect(
    analysis.abi.exports[0].stable_text(),
    content="func export new_node(i32)->(ref type[0])",
  )
  inspect(
    analysis.abi.exports[1].stable_text(),
    content="func export node_value(ref type[0])->(i32)",
  )
  inspect(analysis.abi.types.length(), content="1")
  guard analysis.abi.types[0] is @model.Struct(node) else {
    fail("expected the recursive Node struct")
  }
  inspect(node.id, content="type[0]")
  inspect(node.fields.length(), content="2")
  debug_inspect(node.fields[0].storage, content="Value(I32)")
  inspect(node.fields[0].mutable, content="false")
  debug_inspect(
    node.fields[1].storage,
    content="Value(TypedRef(\"type[0]\", true))",
  )
  inspect(node.fields[1].mutable, content="true")
}
