///|
fn contract_fixture_abi() -> @model.HostAbi {
  @model.HostAbi::{
    schema_version: 1,
    imports: [
      @model.AbiFunction::{
        module_name: Some("host"),
        name: "echo",
        params: [@model.ExternRef],
        results: [@model.ExternRef],
      },
    ],
    exports: [
      @model.AbiFunction::{
        module_name: None,
        name: "add",
        params: [@model.I32, @model.I32],
        results: [@model.I32],
      },
      @model.AbiFunction::{
        module_name: None,
        name: "roundtrip",
        params: [@model.ExternRef],
        results: [@model.ExternRef],
      },
    ],
    types: [],
    features: [],
  }
}

///|
fn v2_contract(hash : String, alias_name : String) -> String {
  "{\"schemaVersion\":2,\"abiSha256\":\"" +
  hash +
  "\",\"externrefs\":{\"imports[host.echo].params[0]\":\"" +
  alias_name +
  "\",\"imports[host.echo].results[0]\":\"" +
  alias_name +
  "\",\"exports[roundtrip].params[0]\":\"" +
  alias_name +
  "\",\"exports[roundtrip].results[0]\":\"" +
  alias_name +
  "\"},\"imports\":[]}\n"
}

///|
fn decode_error(abi : @model.HostAbi, text : String) -> String {
  try decode_contract(abi, text) catch {
    error => Show::to_string(error)
  } noraise {
    _ => "accepted"
  }
}

///|
test "v2 codec is byte-stable and preserves intentional alias sharing" {
  let abi = contract_fixture_abi()
  let text = v2_contract(@lockfile.host_abi_sha256(abi), "HostToken")
  let contract = decode_contract(abi, text)
  inspect(encode_contract(contract), content=text)
  inspect(contract.semantic_aliases() == ["HostToken"], content="true")
  inspect(
    contract.externref_alias("exports[roundtrip].results[0]") ==
    Some("HostToken"),
    content="true",
  )
}

///|
test "decoder rejects structural, duplicate-key, version, and ordering drift" {
  let abi = contract_fixture_abi()
  let hash = @lockfile.host_abi_sha256(abi)
  inspect(
    decode_error(
      abi,
      "{\"schemaVersion\":2,\"abiSha256\":\"" + hash + "\",\"externrefs\":{}}\n",
    ),
    content="contract: unexpected or missing fields",
  )
  let duplicate = v2_contract(hash, "HostToken").replace(
    old="\"imports\":[]",
    new="\"imports\":[],\"imports\":[]",
  )
  inspect(
    decode_error(abi, duplicate),
    content="contract: expected canonical byte representation",
  )
  inspect(
    decode_error(
      abi,
      v2_contract(hash, "HostToken").replace(
        old="\"schemaVersion\":2",
        new="\"schemaVersion\":3",
      ),
    ),
    content="contract.schemaVersion: expected version 1 or 2",
  )
  let reordered = "{\"abiSha256\":\"" +
    hash +
    "\",\"schemaVersion\":2,\"externrefs\":{\"imports[host.echo].params[0]\":\"HostToken\",\"imports[host.echo].results[0]\":\"HostToken\",\"exports[roundtrip].params[0]\":\"HostToken\",\"exports[roundtrip].results[0]\":\"HostToken\"},\"imports\":[]}\n"
  inspect(
    decode_error(abi, reordered),
    content="contract: expected canonical byte representation",
  )
}

///|
test "decoder enforces the one MiB limit on UTF-8 bytes" {
  let chunks : Array[String] = []
  for _ in 0..<65537 {
    chunks.push("0123456789abcdef")
  }
  inspect(
    decode_error(contract_fixture_abi(), chunks.join("")),
    content="contract: input exceeds 1 MiB limit",
  )
  inspect(
    decode_error(contract_fixture_abi(), String::make(600000, 'é')),
    content="contract: input exceeds 1 MiB limit",
  )
  inspect(
    decode_error(
      contract_fixture_abi(),
      String::make(MAX_CONTRACT_LENGTH / 2, 'é'),
    ),
    content="contract: invalid JSON",
  )
}

///|
test "decoder validates ABI fingerprints and exact externref paths" {
  let abi = contract_fixture_abi()
  let hash = @lockfile.host_abi_sha256(abi)
  inspect(
    decode_error(
      abi,
      v2_contract(hash, "HostToken").replace(old=hash, new="wrong"),
    ),
    content="contract.abiSha256: expected lowercase SHA-256",
  )
  inspect(
    decode_error(
      abi,
      v2_contract(hash, "HostToken").replace(
        old=hash,
        new="0000000000000000000000000000000000000000000000000000000000000000",
      ),
    ),
    content="contract.abiSha256: contract does not match artifact ABI",
  )
  inspect(
    decode_error(
      abi,
      v2_contract(hash, "HostToken").replace(
        old="\"exports[roundtrip].results[0]\":\"HostToken\"",
        new="\"exports[other].results[0]\":\"HostToken\"",
      ),
    ),
    content="contract.externrefs[exports[roundtrip].results[0]]: required path is missing",
  )
  inspect(
    decode_error(
      abi,
      v2_contract(hash, "HostToken").replace(
        old="\"HostToken\"},\"imports\":[]",
        new="\"HostToken\",\"exports[other].results[0]\":\"HostToken\"},\"imports\":[]",
      ),
    ),
    content="contract.externrefs[exports[other].results[0]]: unexpected path",
  )
}

///|
test "decoder rejects unsafe and generator-conflicting aliases" {
  let abi = contract_fixture_abi()
  let hash = @lockfile.host_abi_sha256(abi)
  inspect(
    decode_error(abi, v2_contract(hash, "bad-name")),
    content="contract.externrefs[imports[host.echo].params[0]]: expected a safe TypeScript identifier",
  )
  inspect(
    decode_error(abi, v2_contract(hash, "Record")),
    content="contract.externrefs[imports[host.echo].params[0]]: alias conflicts with generated TypeScript identifiers",
  )
}

///|
test "draft assigns independent aliases to unrelated externref positions" {
  let contract = create_contract_draft(contract_fixture_abi())
  inspect(
    contract.semantic_aliases() ==
    ["TExtern0", "TExtern1", "TExtern2", "TExtern3"],
    content="true",
  )
}

///|
test "v1 migration validates imports and emits one exact v2 byte sequence" {
  let abi = contract_fixture_abi()
  let legacy = @fs.read_file_to_string(
    "fixtures/contracts/externref-v1.contract.json",
  )
  let migrated = migrate_v1_contract(abi, legacy)
  inspect(
    encode_contract(migrated),
    content=v2_contract(@lockfile.host_abi_sha256(abi), "HostToken"),
  )
  let stale = legacy.replace(
    old="(externref)->(externref)",
    new="(externref)->()",
  )
  inspect(
    decode_error(abi, stale),
    content="contract.imports[0]: import contract does not match ABI",
  )
}

///|
test "ambiguous canonical paths fail closed" {
  let abi = @model.HostAbi::{
    schema_version: 1,
    imports: [
      @model.AbiFunction::{
        module_name: Some("a.b"),
        name: "c",
        params: [@model.ExternRef],
        results: [],
      },
      @model.AbiFunction::{
        module_name: Some("a"),
        name: "b.c",
        params: [@model.ExternRef],
        results: [],
      },
    ],
    exports: [],
    types: [],
    features: [],
  }
  let rejected = try create_contract_draft(abi) catch {
    error => Show::to_string(error)
  } noraise {
    _ => "accepted"
  }
  inspect(
    rejected,
    content="contract ABI has ambiguous externref path imports[a.b.c].params[0]",
  )
}
