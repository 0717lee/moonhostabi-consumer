///|
test "published resource API projects Wasm and roundtrips v4 locks and v5 contracts" {
  // (module (memory (export "mem") 1 4))
  let artifact = b"\x00asm\x01\x00\x00\x00\x05\x04\x01\x01\x01\x04\x07\x07\x01\x03mem\x02\x00"
  let surface = @resource.project_resource_artifact(artifact)
  assert_eq(surface.schema_version, 4)
  assert_eq(surface.memories.length(), 1)
  assert_eq(surface.memories[0].path, "exports[\"mem\"]")
  assert_eq(surface.memories[0].minimum_pages, 1L)
  assert_eq(surface.memories[0].maximum_pages, Some(4L))
  assert_false(surface.memories[0].shared)
  assert_true(surface.unsupported.is_empty())
  let lockfile = @resource.create_resource_lockfile_v4(surface, artifact)
  let decoded_lock = @resource.decode_resource_lockfile_v4(
    @resource.encode_resource_lockfile_v4(lockfile),
  )
  assert_eq(lockfile.lockfile_version, 4)
  assert_eq(decoded_lock, lockfile)
  let contract = @resource.create_resource_contract_v5(surface)
  let decoded_contract = @resource.decode_resource_contract_v5(
    @resource.encode_resource_contract_v5(contract),
  )
  assert_eq(contract.schema_version, 5)
  assert_eq(decoded_contract, contract)
  assert_true(
    @resource.validate_resource_contract_v5(decoded_lock.abi, decoded_contract),
  )
  let compatible = @resource.compare_resource_surfaces(
    surface,
    decoded_lock.abi,
  )
  assert_eq(compatible.classification, "compatible")
  assert_eq(compatible.exit_code, 0)
  assert_true(compatible.compatible)
  assert_true(compatible.changes.is_empty())
  // The same module with shared memory changes the public resource contract.
  let shared = @resource.project_resource_artifact(
    b"\x00asm\x01\x00\x00\x00\x05\x04\x01\x03\x01\x04\x07\x07\x01\x03mem\x02\x00",
  )
  assert_true(shared.memories[0].shared)
  let breaking = @resource.compare_resource_surfaces(surface, shared)
  assert_eq(breaking.classification, "breaking")
  assert_eq(breaking.exit_code, 2)
  assert_false(breaking.compatible)
  assert_eq(breaking.changes.length(), 1)
  assert_eq(
    breaking.changes[0].path,
    "memories[\"exports[\\\"mem\\\"]\"].shared",
  )
  assert_false(
    @resource.validate_resource_contract_v5(shared, decoded_contract),
  )
}
