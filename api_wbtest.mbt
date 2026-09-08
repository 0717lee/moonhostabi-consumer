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
