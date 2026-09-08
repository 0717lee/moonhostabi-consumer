///|
fn sample_scalar_abi(
  imports : Array[@model.AbiFunction],
  exports : Array[@model.AbiFunction],
) -> @model.HostAbi {
  @model.HostAbi::{
    schema_version: 1,
    imports,
    exports,
    types: [],
    features: ["moonbit.make_closure"],
  }
}

///|
fn imported_clock() -> @model.AbiFunction {
  @model.AbiFunction::{
    module_name: Some("clock"),
    name: "now",
    params: [],
    results: [@model.F64],
  }
}

///|
fn imported_echo() -> @model.AbiFunction {
  @model.AbiFunction::{
    module_name: Some("host"),
    name: "echo",
    params: [@model.ExternRef],
    results: [@model.ExternRef],
  }
}

///|
fn exported_add() -> @model.AbiFunction {
  @model.AbiFunction::{
    module_name: None,
    name: "add",
    params: [@model.I32, @model.I32],
    results: [@model.I32],
  }
}

///|
fn reindexed_recursive_abi(
  struct_id : String,
  array_id : String,
  declarations_reversed : Bool,
) -> @model.HostAbi {
  let recursive = @model.Struct(@model.AbiStructType::{
    id: struct_id,
    supertypes: [],
    final_: false,
    fields: [
      {
        storage: @model.Value(@model.TypedRef(struct_id, true)),
        mutable: false,
      },
      {
        storage: @model.Value(@model.TypedRef(array_id, false)),
        mutable: true,
      },
    ],
  })
  let array = @model.Array(@model.AbiArrayType::{
    id: array_id,
    supertypes: [struct_id],
    final_: true,
    element: {
      storage: @model.Value(@model.TypedRef(struct_id, false)),
      mutable: false,
    },
  })
  let types = if declarations_reversed {
    [array, recursive]
  } else {
    [recursive, array]
  }
  @model.HostAbi::{
    schema_version: 1,
    imports: [],
    exports: [
      @model.AbiFunction::{
        module_name: None,
        name: "root",
        params: [],
        results: [@model.TypedRef(array_id, false)],
      },
    ],
    types,
    features: [],
  }
}

///|
test "crypto dependency hashes bytes as lowercase hexadecimal" {
  inspect(
    sha256_hex(b"abc"),
    content="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "the same Host ABI encodes to byte-identical JSON" {
  let abi = sample_scalar_abi([imported_clock()], [exported_add()])
  inspect(
    encode_canonical_abi(abi) == encode_canonical_abi(abi),
    content="true",
  )
}

///|
test "import and export insertion order does not change canonical JSON" {
  let first = sample_scalar_abi([imported_echo(), imported_clock()], [
    @model.AbiFunction::{
      module_name: None,
      name: "zeta",
      params: [],
      results: [],
    },
    exported_add(),
  ])
  let second = sample_scalar_abi([imported_clock(), imported_echo()], [
    exported_add(),
    @model.AbiFunction::{
      module_name: None,
      name: "zeta",
      params: [],
      results: [],
    },
  ])
  inspect(
    encode_canonical_abi(first) == encode_canonical_abi(second),
    content="true",
  )
}

///|
test "private unreachable type changes do not change canonical ABI" {
  let baseline = reindexed_recursive_abi("raw-struct", "raw-array", false)
  let with_private_change = reindexed_recursive_abi(
    "raw-struct", "raw-array", false,
  )
  with_private_change.types.push(
    @model.Struct(@model.AbiStructType::{
      id: "private-type",
      supertypes: [],
      final_: true,
      fields: [{ storage: @model.PackedI8, mutable: true, }],
    }),
  )
  inspect(
    encode_canonical_abi(baseline) == encode_canonical_abi(with_private_change),
    content="true",
  )
}

///|
test "type declaration order and raw IDs do not change canonical ABI" {
  let first = reindexed_recursive_abi("type[0]", "type[1]", false)
  let reindexed = reindexed_recursive_abi("type[91]", "type[7]", true)
  inspect(
    canonicalize_host_abi(first) == canonicalize_host_abi(reindexed),
    content="true",
  )
  inspect(
    encode_canonical_abi(first) == encode_canonical_abi(reindexed),
    content="true",
  )
}

///|
test "artifact provenance does not change semantic ABI identity" {
  let abi = sample_scalar_abi([imported_clock()], [exported_add()])
  let first = create_lockfile(abi, b"artifact-one")
  let second = create_lockfile(abi, b"artifact-two")
  inspect(first.abi_sha256 == second.abi_sha256, content="true")
  inspect(first.artifact_sha256 == second.artifact_sha256, content="false")
}

///|
test "lockfile JSON escapes names and stays byte-identical" {
  let abi = sample_scalar_abi([], [
    @model.AbiFunction::{
      module_name: None,
      name: "quote\"slash\\line\n",
      params: [],
      results: [],
    },
  ])
  let lockfile = create_lockfile(abi, b"artifact")
  let first = encode_lockfile(lockfile)
  let second = encode_lockfile(lockfile)
  inspect(first == second, content="true")
  inspect(@json.valid(first), content="true")
  inspect(first.contains("quote\\\"slash\\\\line\\n"), content="true")
}

///|
test "reindexed recursive Wasm artifacts have one canonical Host ABI" {
  let first_module = @wasm_adapter.parse_artifact(
    @fs.read_file_to_bytes("fixtures/artifacts/rec-a.wasm"),
  )
  let reindexed_module = @wasm_adapter.parse_artifact(
    @fs.read_file_to_bytes("fixtures/artifacts/rec-reindexed.wasm"),
  )
  let gc_policy = @projector.JsCapabilityPolicy::{
    allow_typed_gc_refs: true,
    allow_v128: false,
    externref_symbol: None,
  }
  let first = @projector.analyze_host_abi(first_module, gc_policy)
  let reindexed = @projector.analyze_host_abi(reindexed_module, gc_policy)
  inspect(first.diagnostics.length(), content="0")
  inspect(reindexed.diagnostics.length(), content="0")
  inspect(first.abi == reindexed.abi, content="false")
  inspect(
    encode_canonical_abi(first.abi) == encode_canonical_abi(reindexed.abi),
    content="true",
  )
}

///|
test "lockfile JSON round-trips and verifies its semantic hash" {
  let abi = sample_scalar_abi([imported_clock()], [exported_add()])
  let encoded = encode_lockfile(create_lockfile(abi, b"artifact"))
  let decoded = decode_lockfile(encoded)
  inspect(decoded.canonical_abi() == canonicalize_host_abi(abi), content="true")
  inspect(encode_lockfile(decoded), content=encoded)
}

///|
test "lockfile decoder rejects malformed schema and hash tampering" {
  let abi = sample_scalar_abi([], [exported_add()])
  let encoded = encode_lockfile(create_lockfile(abi, b"artifact"))
  let bad_version = encoded.replace(
    old="\"lockfileVersion\":1",
    new="\"lockfileVersion\":2",
  )
  let bad_hash = encoded.replace(
    old="\"abiSha256\":\"",
    new="\"abiSha256\":\"0",
  )
  let duplicate_key = encoded.replace(
    old="\"lockfileVersion\":1",
    new="\"lockfileVersion\":1,\"lockfileVersion\":1",
  )
  for invalid in ["not json", bad_version, bad_hash, duplicate_key] {
    let rejected = try decode_lockfile(invalid) catch {
      _ => true
    } noraise {
      _ => false
    }
    inspect(rejected, content="true")
  }
}
