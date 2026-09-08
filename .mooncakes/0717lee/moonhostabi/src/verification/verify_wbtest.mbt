///|
fn verification_test_analysis(
  bytes : Bytes,
) -> @projector.ProjectionAnalysis raise {
  @projector.analyze_host_abi(
    @wasm_adapter.parse_artifact(bytes),
    @projector.default_js_capability_policy(),
  )
}

///|
fn verification_test_baseline(bytes : Bytes) -> VerificationBaselineInput raise {
  let analysis = verification_test_analysis(bytes)
  ValidBaseline(@lockfile.create_lockfile(analysis.abi, bytes))
}

///|
fn assert_verification_golden(
  report : VerificationReport,
  expected : String,
  exit_code : Int,
) -> Unit raise {
  inspect(encode_verification_report(report), content=expected)
  inspect(report.recommended_exit_code() == exit_code, content="true")
}

///|
fn unsupported_export_artifact() -> Bytes {
  b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x6f\x01\x6f\x03\x02\x01\x00\x06\x06\x01\x7f\x00\x41\x00\x0b\x07\x13\x02\x03\x61\x64\x64\x03\x00\x09\x72\x6f\x75\x6e\x64\x74\x72\x69\x70\x00\x00\x0a\x06\x01\x04\x00\x20\x00\x0b"
}

///|
fn adapter_mismatch_artifact() -> Bytes {
  b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x02\x1c\x01\x0b\x6d\x6f\x6f\x6e\x62\x69\x74\x3a\x66\x66\x69\x0c\x6d\x61\x6b\x65\x5f\x63\x6c\x6f\x73\x75\x72\x65\x00\x00"
}

///|
test "verification report golden: compatible with a valid contract" {
  let artifact = @fs.read_file_to_bytes("fixtures/artifacts/externref.wasm")
  let analysis = verification_test_analysis(artifact)
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
  let contract = @fs.read_file_to_string(
    "fixtures/contracts/externref.contract.json",
  )
  let report = verify_artifact(
    artifact,
    verification_test_baseline(artifact),
    ContractText(contract),
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"compatible\",\"artifact\":{\"status\":\"valid\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostics\":[]},\"baseline\":{\"status\":\"valid\",\"artifactSha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostic\":null},\"provenance\":{\"artifactMatchesBaseline\":true,\"abiMatchesBaseline\":true},\"compatibility\":{\"status\":\"evaluated\",\"classification\":\"compatible\",\"changes\":[]},\"contract\":{\"status\":\"valid\",\"diagnostic\":null},\"generator\":{\"status\":\"representable\",\"diagnostics\":[]}}"
  assert_verification_golden(report, expected, 0)
}

///|
test "verification report golden: breaking ABI" {
  let baseline_artifact = @fs.read_file_to_bytes(
    "fixtures/artifacts/breaking_v1.wasm",
  )
  let artifact = @fs.read_file_to_bytes("fixtures/artifacts/breaking_v2.wasm")
  let baseline_analysis = verification_test_analysis(baseline_artifact)
  let analysis = verification_test_analysis(artifact)
  let baseline_artifact_sha256 = @lockfile.sha256_hex(baseline_artifact)
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let baseline_abi_sha256 = @lockfile.host_abi_sha256(baseline_analysis.abi)
  let abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
  let report = verify_artifact(
    artifact,
    verification_test_baseline(baseline_artifact),
    ContractNotProvided,
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"breaking\",\"artifact\":{\"status\":\"valid\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostics\":[]},\"baseline\":{\"status\":\"valid\",\"artifactSha256\":\"" +
    baseline_artifact_sha256 +
    "\",\"abiSha256\":\"" +
    baseline_abi_sha256 +
    "\",\"diagnostic\":null},\"provenance\":{\"artifactMatchesBaseline\":false,\"abiMatchesBaseline\":false},\"compatibility\":{\"status\":\"evaluated\",\"classification\":\"breaking\",\"changes\":[{\"classification\":\"breaking\",\"code\":\"MHA_SIGNATURE_CHANGED\",\"path\":\"exports[add].params\",\"message\":\"function value count changed\"}]},\"contract\":{\"status\":\"notProvided\",\"diagnostic\":null},\"generator\":{\"status\":\"representable\",\"diagnostics\":[]}}"
  assert_verification_golden(report, expected, 2)
}

///|
test "verification report golden: unsupported artifact is unknown" {
  let artifact = unsupported_export_artifact()
  let analysis = verification_test_analysis(artifact)
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
  let diagnostic = "{\"code\":\"MHA_PROJECT_UNSUPPORTED_ITEM\",\"severity\":\"error\",\"path\":\"exports[add]\",\"message\":\"public global export is not supported by the Spike adapter\",\"byteOffset\":null}"
  let change = "{\"classification\":\"unknown\",\"code\":\"MHA_PROJECT_UNSUPPORTED_ITEM\",\"path\":\"exports[add]\",\"message\":\"public global export is not supported by the Spike adapter\"}"
  let report = verify_artifact(
    artifact,
    verification_test_baseline(artifact),
    ContractNotProvided,
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"unknown\",\"artifact\":{\"status\":\"unsupported\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostics\":[" +
    diagnostic +
    "]},\"baseline\":{\"status\":\"valid\",\"artifactSha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostic\":null},\"provenance\":{\"artifactMatchesBaseline\":true,\"abiMatchesBaseline\":true},\"compatibility\":{\"status\":\"evaluated\",\"classification\":\"unknown\",\"changes\":[" +
    change +
    "]},\"contract\":{\"status\":\"notProvided\",\"diagnostic\":null},\"generator\":{\"status\":\"representable\",\"diagnostics\":[]}}"
  assert_verification_golden(report, expected, 3)
}

///|
test "verification report golden: invalid lockfile" {
  let artifact = @fs.read_file_to_bytes("fixtures/artifacts/scalar.wasm")
  let analysis = verification_test_analysis(artifact)
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
  let report = verify_artifact(
    artifact,
    decode_verification_baseline("{"),
    ContractNotProvided,
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"invalid\",\"artifact\":{\"status\":\"valid\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostics\":[]},\"baseline\":{\"status\":\"invalid\",\"artifactSha256\":null,\"abiSha256\":null,\"diagnostic\":{\"code\":\"MHA_LOCKFILE_INVALID\",\"severity\":\"error\",\"path\":\"baseline\",\"message\":\"lockfile: invalid JSON\",\"byteOffset\":null}},\"provenance\":{\"artifactMatchesBaseline\":null,\"abiMatchesBaseline\":null},\"compatibility\":{\"status\":\"notEvaluated\",\"classification\":null,\"changes\":[]},\"contract\":{\"status\":\"notProvided\",\"diagnostic\":null},\"generator\":{\"status\":\"representable\",\"diagnostics\":[]}}"
  assert_verification_golden(report, expected, 3)
}

///|
test "verification report golden: stale contract" {
  let artifact = @fs.read_file_to_bytes("fixtures/artifacts/externref.wasm")
  let analysis = verification_test_analysis(artifact)
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
  let stale_contract = @fs.read_file_to_string(
    "fixtures/contracts/externref.contract.json",
  ).replace(
    old=abi_sha256,
    new="0000000000000000000000000000000000000000000000000000000000000000",
  )
  let report = verify_artifact(
    artifact,
    verification_test_baseline(artifact),
    ContractText(stale_contract),
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"adapterMismatch\",\"artifact\":{\"status\":\"valid\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostics\":[]},\"baseline\":{\"status\":\"valid\",\"artifactSha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostic\":null},\"provenance\":{\"artifactMatchesBaseline\":true,\"abiMatchesBaseline\":true},\"compatibility\":{\"status\":\"evaluated\",\"classification\":\"compatible\",\"changes\":[]},\"contract\":{\"status\":\"invalid\",\"diagnostic\":{\"code\":\"MHA_CONTRACT_INVALID\",\"severity\":\"error\",\"path\":\"contract\",\"message\":\"contract.abiSha256: contract does not match artifact ABI\",\"byteOffset\":null}},\"generator\":{\"status\":\"notEvaluated\",\"diagnostics\":[]}}"
  assert_verification_golden(report, expected, 4)
}

///|
test "verification report golden: invalid contract JSON" {
  let artifact = @fs.read_file_to_bytes("fixtures/artifacts/externref.wasm")
  let analysis = verification_test_analysis(artifact)
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
  let report = verify_artifact(
    artifact,
    verification_test_baseline(artifact),
    ContractText("{"),
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"adapterMismatch\",\"artifact\":{\"status\":\"valid\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostics\":[]},\"baseline\":{\"status\":\"valid\",\"artifactSha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostic\":null},\"provenance\":{\"artifactMatchesBaseline\":true,\"abiMatchesBaseline\":true},\"compatibility\":{\"status\":\"evaluated\",\"classification\":\"compatible\",\"changes\":[]},\"contract\":{\"status\":\"invalid\",\"diagnostic\":{\"code\":\"MHA_CONTRACT_INVALID\",\"severity\":\"error\",\"path\":\"contract\",\"message\":\"contract: invalid JSON\",\"byteOffset\":null}},\"generator\":{\"status\":\"notEvaluated\",\"diagnostics\":[]}}"
  assert_verification_golden(report, expected, 4)
}

///|
test "verification report golden: generator adapter mismatch" {
  let artifact = adapter_mismatch_artifact()
  let analysis = verification_test_analysis(artifact)
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
  let report = verify_artifact(
    artifact,
    verification_test_baseline(artifact),
    ContractNotProvided,
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"adapterMismatch\",\"artifact\":{\"status\":\"valid\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostics\":[]},\"baseline\":{\"status\":\"valid\",\"artifactSha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostic\":null},\"provenance\":{\"artifactMatchesBaseline\":true,\"abiMatchesBaseline\":true},\"compatibility\":{\"status\":\"evaluated\",\"classification\":\"compatible\",\"changes\":[]},\"contract\":{\"status\":\"notProvided\",\"diagnostic\":null},\"generator\":{\"status\":\"unrepresentable\",\"diagnostics\":[{\"code\":\"MHA_ADAPTER_MISMATCH\",\"severity\":\"error\",\"path\":\"imports[moonbit:ffi.make_closure]\",\"message\":\"moonbit:ffi.make_closure has an unsupported signature\",\"byteOffset\":null}]}}"
  assert_verification_golden(report, expected, 4)
}

///|
test "verification report golden: same ABI with different provenance" {
  let artifact = @fs.read_file_to_bytes("fixtures/artifacts/scalar.wasm")
  let analysis = verification_test_analysis(artifact)
  let baseline_artifact = b"same ABI from different artifact bytes"
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let baseline_artifact_sha256 = @lockfile.sha256_hex(baseline_artifact)
  let abi_sha256 = @lockfile.host_abi_sha256(analysis.abi)
  let baseline = @lockfile.create_lockfile(analysis.abi, baseline_artifact)
  let report = verify_artifact(
    artifact,
    ValidBaseline(baseline),
    ContractNotProvided,
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"compatible\",\"artifact\":{\"status\":\"valid\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostics\":[]},\"baseline\":{\"status\":\"valid\",\"artifactSha256\":\"" +
    baseline_artifact_sha256 +
    "\",\"abiSha256\":\"" +
    abi_sha256 +
    "\",\"diagnostic\":null},\"provenance\":{\"artifactMatchesBaseline\":false,\"abiMatchesBaseline\":true},\"compatibility\":{\"status\":\"evaluated\",\"classification\":\"compatible\",\"changes\":[]},\"contract\":{\"status\":\"notProvided\",\"diagnostic\":null},\"generator\":{\"status\":\"representable\",\"diagnostics\":[]}}"
  assert_verification_golden(report, expected, 0)
}

///|
test "verification report golden: malformed artifact" {
  let artifact = b"\x00asm"
  let baseline_artifact = @fs.read_file_to_bytes(
    "fixtures/artifacts/scalar.wasm",
  )
  let baseline_analysis = verification_test_analysis(baseline_artifact)
  let artifact_sha256 = @lockfile.sha256_hex(artifact)
  let baseline_artifact_sha256 = @lockfile.sha256_hex(baseline_artifact)
  let baseline_abi_sha256 = @lockfile.host_abi_sha256(baseline_analysis.abi)
  let parse_message = try {
    ignore(@wasm_adapter.parse_artifact(artifact))
    "unexpected parse success"
  } catch {
    error => error.to_string()
  }
  let report = verify_artifact(
    artifact,
    verification_test_baseline(baseline_artifact),
    ContractNotProvided,
  )
  let expected = "{\"schemaVersion\":1,\"outcome\":\"invalid\",\"artifact\":{\"status\":\"invalid\",\"sha256\":\"" +
    artifact_sha256 +
    "\",\"abiSha256\":null,\"diagnostics\":[{\"code\":\"MHA_PARSE_MALFORMED\",\"severity\":\"error\",\"path\":\"artifact\",\"message\":" +
    Json::string(parse_message).stringify() +
    ",\"byteOffset\":null}]},\"baseline\":{\"status\":\"valid\",\"artifactSha256\":\"" +
    baseline_artifact_sha256 +
    "\",\"abiSha256\":\"" +
    baseline_abi_sha256 +
    "\",\"diagnostic\":null},\"provenance\":{\"artifactMatchesBaseline\":null,\"abiMatchesBaseline\":null},\"compatibility\":{\"status\":\"notEvaluated\",\"classification\":null,\"changes\":[]},\"contract\":{\"status\":\"notProvided\",\"diagnostic\":null},\"generator\":{\"status\":\"notEvaluated\",\"diagnostics\":[]}}"
  assert_verification_golden(report, expected, 3)
}

///|
test "verification outcome precedence is stable for combined failures" {
  let unsupported = unsupported_export_artifact()
  let unknown_and_contract = verify_artifact(
    unsupported,
    verification_test_baseline(unsupported),
    ContractText("{"),
  )
  inspect(unknown_and_contract.outcome == VerificationUnknown, content="true")
  inspect(unknown_and_contract.recommended_exit_code(), content="3")

  let breaking_baseline = @fs.read_file_to_bytes(
    "fixtures/artifacts/breaking_v1.wasm",
  )
  let breaking_current = @fs.read_file_to_bytes(
    "fixtures/artifacts/breaking_v2.wasm",
  )
  let breaking_and_contract = verify_artifact(
    breaking_current,
    verification_test_baseline(breaking_baseline),
    ContractText("{"),
  )
  inspect(
    breaking_and_contract.outcome == VerificationAdapterMismatch,
    content="true",
  )
  inspect(breaking_and_contract.recommended_exit_code(), content="4")

  let invalid_baseline_and_contract = verify_artifact(
    breaking_current,
    InvalidBaseline("lockfile: invalid JSON"),
    ContractText("{"),
  )
  inspect(
    invalid_baseline_and_contract.outcome == VerificationInvalid,
    content="true",
  )
  inspect(invalid_baseline_and_contract.recommended_exit_code(), content="3")
}
