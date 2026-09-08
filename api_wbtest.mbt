test "published MoonHostABI library API roundtrips a lockfile" {
  let abi = @model.HostAbi::{
    schema_version: 1,
    imports: [],
    exports: [],
    types: [],
    features: [],
  }
  let lock = @lockfile.create_lockfile(abi, b"")
  let encoded = @lockfile.encode_lockfile(lock)
  let decoded : Result[@lockfile.AbiLockfile, String] = Ok(
    @lockfile.decode_lockfile(encoded),
  ) catch {
    error => Err(error.to_string())
  }
  inspect(decoded == Ok(lock), content="true")
  inspect(@lockfile.host_abi_sha256(abi).length(), content="64")
}

test "published API parses a real recursive Wasm-GC artifact" {
  let bytes = @fs.read_file_to_bytes("fixtures/rec-a.wasm")
  let analysis : Result[@projector.ProjectionAnalysis, String] = Ok(
    @projector.analyze_host_abi(
      @wasm_adapter.parse_artifact(bytes),
      @projector.default_js_capability_policy(),
    ),
  ) catch {
    error => Err(error.to_string())
  }
  match analysis {
    Ok(value) => {
      inspect(value.abi.exports.length(), content="1")
      inspect(value.abi.types.length(), content="2")
    }
    Err(message) => fail("recursive artifact parse failed: " + message)
  }
}
