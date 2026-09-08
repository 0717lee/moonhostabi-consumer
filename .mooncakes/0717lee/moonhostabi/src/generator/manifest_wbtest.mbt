///|
fn manifest_error(text : String) -> String {
  try decode_generation_manifest(text) catch {
    error => Show::to_string(error)
  } noraise {
    _ => "accepted"
  }
}

///|
test "generation manifest has one exact canonical encoding" {
  let abi_sha256 = String::make(64, 'a')
  let contract = "canonical contract\n"
  let typescript = "generated adapter\n"
  let contract_sha256 = @lockfile.sha256_hex(
    @encoding.encode(@encoding.UTF8, contract),
  )
  let typescript_sha256 = @lockfile.sha256_hex(
    @encoding.encode(@encoding.UTF8, typescript),
  )
  let manifest = create_generation_manifest(abi_sha256, contract, typescript)
  let expected = "{\"schemaVersion\":1,\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"generatorVersion\":\"" +
    MOONHOSTABI_VERSION +
    "\",\"contractSha256\":\"" +
    contract_sha256 +
    "\",\"files\":{\"adapter.ts\":\"" +
    typescript_sha256 +
    "\",\"moonhostabi.contract.json\":\"" +
    contract_sha256 +
    "\"}}\n"
  inspect(encode_generation_manifest(manifest), content=expected)
  let decoded = decode_generation_manifest(expected)
  inspect(encode_generation_manifest(decoded), content=expected)
  inspect(
    decoded.owned_file_names() == ["adapter.ts", "moonhostabi.contract.json"],
    content="true",
  )
  inspect(
    decoded.file_sha256("adapter.ts") == Some(typescript_sha256),
    content="true",
  )
  inspect(decoded.abi_fingerprint(), content=abi_sha256)
}

///|
test "generation manifest rejects schema, hash, and canonical drift" {
  let abi_sha256 = String::make(64, 'a')
  let encoded = encode_generation_manifest(
    create_generation_manifest(abi_sha256, "contract\n", "adapter\n"),
  )
  inspect(
    manifest_error(
      encoded.replace(old="\"schemaVersion\":1", new="\"schemaVersion\":2"),
    ),
    content="manifest.schemaVersion: expected version 1",
  )
  inspect(
    manifest_error(encoded.replace(old=abi_sha256, new="not-a-fingerprint")),
    content="manifest.abiSha256: expected lowercase SHA-256",
  )
  inspect(
    manifest_error(
      encoded.replace(old="\"files\":{", new="\"unexpected\":true,\"files\":{"),
    ),
    content="manifest: unexpected or missing fields",
  )
  let reordered = encoded.replace(
    old="{\"schemaVersion\":1,\"abiSha256\":\"" + abi_sha256 + "\"",
    new="{\"abiSha256\":\"" + abi_sha256 + "\",\"schemaVersion\":1",
  )
  inspect(
    manifest_error(reordered),
    content="manifest: expected canonical byte representation",
  )
  let contract_hash = decode_generation_manifest(encoded)
    .file_sha256("moonhostabi.contract.json")
    .unwrap()
  let mismatched = encoded.replace(
    old="\"contractSha256\":\"" + contract_hash + "\"",
    new="\"contractSha256\":\"" + String::make(64, 'b') + "\"",
  )
  inspect(
    manifest_error(mismatched),
    content="manifest.contractSha256: must match moonhostabi.contract.json",
  )
}
