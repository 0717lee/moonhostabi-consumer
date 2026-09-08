///|
test "CLI failure categories reserve stable exit codes" {
  let cases : Array[(FailureKind, Int)] = [
    (Usage, 1),
    (BreakingAbi, 2),
    (InvalidArtifact, 3),
    (AdapterMismatch, 4),
    (RuntimeFailure, 5),
  ]
  for case in cases {
    let (failure, expected) = case
    inspect(exit_code_for_failure(failure) == expected, content="true")
  }
}

///|
test "missing command returns a usage error" {
  let result = dispatch([])
  inspect(result.exit_code, content="1")
  inspect(result.stderr.contains("usage:"), content="true")
}

///|
test "argument parsing is pure and order-sensitive" {
  guard parse_command(["--help"]) is Some(Help) else {
    fail("expected help command")
  }
  guard parse_command(["--version"]) is Some(Version) else {
    fail("expected version command")
  }
  guard parse_command(["inspect", "module.wasm", "--format", "json"])
    is Some(Inspect(path)) else {
    fail("expected inspect command")
  }
  inspect(path, content="module.wasm")
  assert_true(
    parse_command(["inspect", "module.wasm", "json", "--format"]) is None,
  )
  guard parse_command([
      "generate", "module.wasm", "--contract", "contract.json", "--out", "generated",
    ])
    is Some(Generate(artifact, Some(contract), output, Fresh)) else {
    fail("expected generate command")
  }
  inspect(artifact, content="module.wasm")
  inspect(contract, content="contract.json")
  inspect(output, content="generated")
  guard parse_command([
      "generate", "module.wasm", "--out", "generated", "--update",
    ])
    is Some(Generate(_, None, _, Update)) else {
    fail("expected update command")
  }
  guard parse_command([
      "generate", "module.wasm", "--out", "generated", "--dry-run",
    ])
    is Some(Generate(_, None, _, DryRun)) else {
    fail("expected dry-run command")
  }
  guard parse_command([
      "verify", "module.wasm", "--against", "baseline.json", "--format", "json",
    ])
    is Some(Verify(verify_artifact, verify_baseline, None)) else {
    fail("expected verify command")
  }
  inspect(verify_artifact, content="module.wasm")
  inspect(verify_baseline, content="baseline.json")
  guard parse_command([
      "verify", "module.wasm", "--against", "baseline.json", "--contract", "contract.json",
      "--format", "json",
    ])
    is Some(Verify(_, _, Some(verify_contract))) else {
    fail("expected verify command with contract")
  }
  inspect(verify_contract, content="contract.json")
  assert_true(
    parse_command(["generate", "module.wasm", "--update", "--out", "generated"])
    is None,
  )
  assert_true(
    parse_command(["generate", "module.wasm", "--out", "generated", "--force"])
    is None,
  )
  assert_true(
    parse_command([
      "generate", "module.wasm", "--contract", "contract.json", "--out", "generated",
      "--update",
    ])
    is None,
  )
  assert_true(
    parse_command([
      "generate", "module.wasm", "--out", "generated", "--update", "--dry-run",
    ])
    is None,
  )
  assert_true(parse_command(["generate", "module.wasm"]) is None)
  for
    invalid in [
      ["--help", "extra"],
      ["--version", "extra"],
      ["-h"],
      ["verify", "module.wasm", "--against", "baseline.json"],
      [
        "verify", "module.wasm", "--against", "baseline.json", "--format", "text",
      ],
      [
        "verify", "module.wasm", "--contract", "contract.json", "--against", "baseline.json",
        "--format", "json",
      ],
      [
        "verify", "module.wasm", "--against", "baseline.json", "--format", "json",
        "--contract", "contract.json",
      ],
      [
        "verify", "module.wasm", "--against", "baseline.json", "--against", "other.json",
        "--format", "json",
      ],
    ] {
    assert_true(parse_command(invalid) is None)
  }
}

///|
test "help and version have exact stdout-only contracts" {
  let expected_help = "usage:\n  moonhostabi inspect <artifact.wasm> --format json\n  moonhostabi lock <artifact.wasm> --out <lock.json>\n  moonhostabi check <artifact.wasm> --against <lock.json>\n  moonhostabi verify <artifact.wasm> --against <lock.json> [--contract <contract.json>] --format json\n  moonhostabi generate <artifact.wasm> --out <directory> [--update | --dry-run]\n  moonhostabi generate <artifact.wasm> --contract <contract.json> --out <directory>\n  moonhostabi --help\n  moonhostabi --version"
  let help = dispatch(["--help"])
  inspect(help.exit_code, content="0")
  inspect(help.stdout, content=expected_help)
  inspect(help.stderr, content="")
  let version = dispatch(["--version"])
  inspect(version.exit_code, content="0")
  inspect(
    version.stdout,
    content="moonhostabi \{@generator.MOONHOSTABI_VERSION}",
  )
  inspect(version.stderr, content="")
}

///|
test "verify dispatch reports success and readable invalid inputs on stdout" {
  let lock_path = "_build/task5-verify.lock.json"
  let invalid_lock_path = "_build/task5-invalid.lock.json"
  let malformed_path = "_build/task5-malformed.wasm"
  for path in [lock_path, invalid_lock_path, malformed_path] {
    if @fs.path_exists(path) {
      @fs.remove_file(path)
    }
  }
  let locked = dispatch([
    "lock", "fixtures/artifacts/scalar.wasm", "--out", lock_path,
  ])
  inspect(locked.exit_code, content="0")

  let compatible = dispatch([
    "verify", "fixtures/artifacts/scalar.wasm", "--against", lock_path, "--format",
    "json",
  ])
  inspect(compatible.exit_code, content="0")
  inspect(compatible.stderr, content="")
  guard @json.parse(compatible.stdout)
    is Object(
      {
        "schemaVersion": Number(schema_version, ..),
        "outcome": String(outcome),
        "artifact": Object(_),
        "baseline": Object(_),
        "provenance": Object(_),
        "compatibility": Object(_),
        "contract": Object(_),
        "generator": Object(_),
        ..
      }
    ) else {
    fail("expected canonical verification report")
  }
  inspect(schema_version, content="1")
  inspect(outcome, content="compatible")

  @fs.write_string_to_file(invalid_lock_path, "{")
  let invalid_lock = dispatch([
    "verify", "fixtures/artifacts/scalar.wasm", "--against", invalid_lock_path, "--format",
    "json",
  ])
  inspect(invalid_lock.exit_code, content="3")
  inspect(invalid_lock.stderr, content="")
  inspect(
    invalid_lock.stdout.contains("\"baseline\":{\"status\":\"invalid\""),
    content="true",
  )
  inspect(invalid_lock.stdout.contains("MHA_LOCKFILE_INVALID"), content="true")

  @fs.write_bytes_to_file(malformed_path, b"\x00asm")
  let malformed = dispatch([
    "verify", malformed_path, "--against", lock_path, "--format", "json",
  ])
  inspect(malformed.exit_code, content="3")
  inspect(malformed.stderr, content="")
  inspect(malformed.stdout.contains("MHA_PARSE_MALFORMED"), content="true")

  for path in [lock_path, invalid_lock_path, malformed_path] {
    @fs.remove_file(path)
  }
}

///|
test "inspect emits machine-assertable scalar ABI JSON" {
  let result = dispatch([
    "inspect", "fixtures/artifacts/scalar.wasm", "--format", "json",
  ])
  inspect(result.exit_code, content="0")
  guard @json.parse(result.stdout)
    is Object(
      {
        "schemaVersion": Number(schema, ..),
        "imports": Array(imports),
        "exports": Array(exports),
        "types": Array(types),
        "features": Array(features),
        ..
      }
    ) else {
    fail("expected canonical ABI JSON object")
  }
  inspect(schema, content="1")
  inspect(imports.length(), content="0")
  inspect(exports.length(), content="2")
  inspect(types.length(), content="0")
  inspect(features.length(), content="0")
  guard exports[0]
    is Object(
      {
        "name": String(first_name),
        "params": Array(first_params),
        "results": Array(first_results),
        ..
      }
    ) else {
    fail("expected first exported function")
  }
  inspect(first_name, content="add")
  debug_inspect(first_params, content="[String(\"i32\"), String(\"i32\")]")
  debug_inspect(first_results, content="[String(\"i32\")]")
  guard exports[1]
    is Object(
      {
        "name": String(second_name),
        "params": Array(second_params),
        "results": Array(second_results),
        ..
      }
    ) else {
    fail("expected second exported function")
  }
  inspect(second_name, content="answer")
  debug_inspect(second_params, content="[]")
  debug_inspect(second_results, content="[String(\"i64\")]")
}

///|
test "lock and check preserve the baseline and classify breaking ABI" {
  let lock_path = "_build/task10-breaking.lock.json"
  if @fs.path_exists(lock_path) {
    @fs.remove_file(lock_path)
  }
  let locked = dispatch([
    "lock", "fixtures/artifacts/breaking_v1.wasm", "--out", lock_path,
  ])
  inspect(locked.exit_code, content="0")
  inspect(@fs.is_file(lock_path), content="true")
  let before = @fs.read_file_to_bytes(lock_path)
  inspect(@json.valid(@utf8.decode(before[:])), content="true")
  let overwrite = dispatch([
    "lock", "fixtures/artifacts/breaking_v2.wasm", "--out", lock_path,
  ])
  inspect(overwrite.exit_code, content="3")
  inspect(@fs.read_file_to_bytes(lock_path) == before, content="true")

  let compatible = dispatch([
    "check", "fixtures/artifacts/breaking_v1.wasm", "--against", lock_path,
  ])
  inspect(compatible.exit_code, content="0")

  let breaking = dispatch([
    "check", "fixtures/artifacts/breaking_v2.wasm", "--against", lock_path,
  ])
  inspect(breaking.exit_code, content="2")
  inspect(breaking.stdout.contains("MHA_SIGNATURE_CHANGED"), content="true")
  inspect(breaking.stdout.contains("exports[add].params"), content="true")
  inspect(@fs.read_file_to_bytes(lock_path) == before, content="true")
  @fs.remove_file(lock_path)
}

///|
test "malformed and unsupported artifacts exit three" {
  let malformed_path = "_build/task10-malformed.wasm"
  @fs.write_bytes_to_file(malformed_path, b"\x00asm")
  let malformed = dispatch(["inspect", malformed_path, "--format", "json"])
  inspect(malformed.exit_code, content="3")
  inspect(malformed.stderr.contains("MHA_PARSE_MALFORMED"), content="true")
  @fs.remove_file(malformed_path)

  let unsupported = dispatch([
    "inspect", "fixtures/artifacts/recursive.wasm", "--format", "json",
  ])
  inspect(unsupported.exit_code, content="3")
  inspect(
    unsupported.stderr.contains("MHA_PROJECT_UNREPRESENTABLE"),
    content="true",
  )
}

///|
test "I/O errors are not mislabeled as malformed Wasm" {
  let missing = dispatch([
    "inspect", "_build/definitely-missing-task10.wasm", "--format", "json",
  ])
  inspect(missing.exit_code, content="3")
  inspect(missing.stderr.contains("MHA_INPUT_IO"), content="true")
  inspect(missing.stderr.contains("MHA_PARSE_MALFORMED"), content="false")
}

///|
test "artifact provenance is evidence rather than compatibility identity" {
  let path = "_build/task10-provenance.lock.json"
  if @fs.path_exists(path) {
    @fs.remove_file(path)
  }
  let wasm_module = @wasm_adapter.parse_artifact(
    @fs.read_file_to_bytes("fixtures/artifacts/breaking_v1.wasm"),
  )
  let analysis = @projector.analyze_host_abi(
    wasm_module,
    @projector.default_js_capability_policy(),
  )
  let different_provenance = @lockfile.create_lockfile(
    analysis.abi,
    b"not-the-current-artifact",
  )
  @fs.write_bytes_to_file(
    path,
    @utf8.encode(@lockfile.encode_lockfile(different_provenance)),
  )
  let result = dispatch([
    "check", "fixtures/artifacts/breaking_v1.wasm", "--against", path,
  ])
  inspect(result.exit_code, content="0")
  inspect(
    result.stdout.contains("\"classification\":\"compatible\""),
    content="true",
  )
  @fs.remove_file(path)
}

///|
fn cleanup_generation_test_directory(path : String) -> Unit {
  for
    name in [
      "adapter.ts", "moonhostabi.contract.json", "moonhostabi.manifest.json",
    ] {
    let file = "\{path}/\{name}"
    if @fs.path_exists(file) {
      @fs.remove_file(file) catch {
        _ => ()
      }
    }
  }
  if @fs.path_exists(path) {
    @fs.remove_dir(path) catch {
      _ => ()
    }
  }
}

///|
test "generate writes typed adapter and normalized explicit contract" {
  let output = "_build/task11-generated-contract"
  cleanup_generation_test_directory(output)
  let result = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--contract", "fixtures/contracts/externref.contract.json",
    "--out", output,
  ])
  inspect(result.exit_code, content="0")
  inspect(@fs.is_file("\{output}/adapter.ts"), content="true")
  inspect(@fs.is_file("\{output}/moonhostabi.contract.json"), content="true")
  inspect(@fs.is_file("\{output}/moonhostabi.manifest.json"), content="true")
  let manifest = @generator.decode_generation_manifest(
    @fs.read_file_to_string("\{output}/moonhostabi.manifest.json"),
  )
  inspect(
    manifest.abi_fingerprint(),
    content="ecc9ee29e442515286ed65d66f0b3765c3beb015e086e9022fe641d9e0ccc6d7",
  )
  inspect(
    result.stdout.contains("\"moonhostabi.manifest.json\""),
    content="true",
  )
  let source = @fs.read_file_to_string("\{output}/adapter.ts")
  inspect(source.contains("HostImports<HostToken = unknown>"), content="true")
  inspect(
    source.contains("\"add\": (arg0: number, arg1: number) => number"),
    content="true",
  )
  inspect(
    source.contains("\"roundtrip\": (arg0: HostToken) => HostToken"),
    content="true",
  )
  inspect(source.contains("any"), content="false")
  let normalized_contract = @fs.read_file_to_string(
    "\{output}/moonhostabi.contract.json",
  )
  inspect(normalized_contract.contains("\"schemaVersion\":2"), content="true")
  inspect(
    normalized_contract.contains(
      "\"exports[roundtrip].results[0]\":\"HostToken\"",
    ),
    content="true",
  )
  inspect(
    normalized_contract.contains(
      "ecc9ee29e442515286ed65d66f0b3765c3beb015e086e9022fe641d9e0ccc6d7",
    ),
    content="true",
  )
  cleanup_generation_test_directory(output)
}

///|
test "generate draft is conservative and refuses invalid output boundaries" {
  let draft_output = "_build/task11-generated-draft"
  cleanup_generation_test_directory(draft_output)
  let draft = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", draft_output,
  ])
  inspect(draft.exit_code, content="0")
  let draft_source = @fs.read_file_to_string("\{draft_output}/adapter.ts")
  let draft_contract = @fs.read_file_to_string(
    "\{draft_output}/moonhostabi.contract.json",
  )
  inspect(
    draft_source.contains("HostImports<TExtern0 = unknown, TExtern1 = unknown>"),
    content="true",
  )
  inspect(
    draft_source.contains(
      "ModuleExports<TExtern2 = unknown, TExtern3 = unknown>",
    ),
    content="true",
  )
  inspect(
    draft_contract.contains("\"imports[host.echo].params[0]\":\"TExtern0\""),
    content="true",
  )
  inspect(
    draft_contract.contains("\"exports[roundtrip].results[0]\":\"TExtern3\""),
    content="true",
  )
  let repeated = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", draft_output,
  ])
  inspect(repeated.exit_code, content="3")
  inspect(repeated.stderr.contains("MHA_OUTPUT_EXISTS"), content="true")
  cleanup_generation_test_directory(draft_output)

  let invalid_contract = "_build/task11-invalid-contract.json"
  let invalid_output = "_build/task11-invalid-output"
  @fs.write_bytes_to_file(invalid_contract, b"not json")
  cleanup_generation_test_directory(invalid_output)
  let malformed = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--contract", invalid_contract,
    "--out", invalid_output,
  ])
  inspect(malformed.exit_code, content="3")
  inspect(malformed.stderr.contains("MHA_CONTRACT_INVALID"), content="true")
  inspect(@fs.path_exists(invalid_output), content="false")
  @fs.remove_file(invalid_contract)

  let unsupported_output = "_build/task11-unsupported-output"
  cleanup_generation_test_directory(unsupported_output)
  let unsupported = dispatch([
    "generate", "fixtures/artifacts/recursive.wasm", "--out", unsupported_output,
  ])
  inspect(unsupported.exit_code, content="3")
  inspect(@fs.path_exists(unsupported_output), content="false")
}

///|
fn generated_snapshot(path : String) -> Array[Bytes] raise {
  [
    @fs.read_file_to_bytes("\{path}/adapter.ts"),
    @fs.read_file_to_bytes("\{path}/moonhostabi.contract.json"),
    @fs.read_file_to_bytes("\{path}/moonhostabi.manifest.json"),
  ]
}

///|
fn transaction_fixture() -> @generator.GenerationResult raise {
  let analysis = analyze_artifact(
    @fs.read_file_to_bytes("fixtures/artifacts/externref.wasm"),
  )
  generate_adapter(
    analysis.abi,
    Some(@fs.read_file_to_string("fixtures/contracts/externref.contract.json")),
  )
}

///|
fn publish_error(
  output : String,
  generated : @generator.GenerationResult,
  mode : GenerateMode,
  fault : GenerationFault?,
) -> String {
  try {
    let expected_snapshot = match mode {
      Update =>
        Some(validate_owned_generation_directory(output, generated.abi_sha256))
      Fresh | DryRun => None
    }
    publish_generated_directory(
      output, generated, mode, fault, expected_snapshot,
    )
  } catch {
    CliExecutionError(code, message) => "\{code}:\{message}"
  } noraise {
    _ => "accepted"
  }
}

///|
fn transaction_siblings(output_leaf : String) -> Array[String] raise {
  @fs.read_dir("_build").filter(fn(name) {
    name.has_prefix("\{output_leaf}.moonhostabi-")
  })
}

///|
test "generate dry-run performs no filesystem writes" {
  let output = "_build/task12-dry-run"
  cleanup_generation_test_directory(output)
  let result = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", output, "--dry-run",
  ])
  inspect(result.exit_code, content="0")
  inspect(
    result.stdout.contains("\"moonhostabi.manifest.json\""),
    content="true",
  )
  inspect(@fs.path_exists(output), content="false")
  inspect(transaction_siblings("task12-dry-run").is_empty(), content="true")
}

///|
test "fresh generate refuses an existing unrelated directory" {
  let output = "_build/task12-unrelated"
  let user_file = "\{output}/user.txt"
  cleanup_generation_test_directory(output)
  if @fs.path_exists(user_file) {
    @fs.remove_file(user_file)
  }
  if @fs.path_exists(output) {
    @fs.remove_dir(output)
  }
  @fs.create_dir(output)
  @fs.write_string_to_file(user_file, "user-owned")
  let result = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", output,
  ])
  inspect(result.exit_code, content="3")
  inspect(result.stderr.contains("MHA_OUTPUT_EXISTS"), content="true")
  inspect(@fs.read_file_to_string(user_file), content="user-owned")
  @fs.remove_file(user_file)
  @fs.remove_dir(output)
}

///|
test "native directory publication never replaces an existing target" {
  let source = "_build/task12-noreplace-source"
  let target = "_build/task12-noreplace-target"
  let source_file = "\{source}/source.txt"
  let target_file = "\{target}/target.txt"
  for file in [source_file, target_file] {
    if @fs.path_exists(file) {
      @fs.remove_file(file)
    }
  }
  for directory in [source, target] {
    if @fs.path_exists(directory) {
      @fs.remove_dir(directory)
    }
    @fs.create_dir(directory)
  }
  @fs.write_string_to_file(source_file, "source")
  @fs.write_string_to_file(target_file, "target")
  inspect(rename_directory_noreplace(source, target), content="1")
  inspect(@fs.read_file_to_string(source_file), content="source")
  inspect(@fs.read_file_to_string(target_file), content="target")
  @fs.remove_file(source_file)
  @fs.remove_file(target_file)
  @fs.remove_dir(source)
  @fs.remove_dir(target)
}

///|
test "native directory kind distinguishes real directories without following paths" {
  let directory = "_build/task12-directory-kind"
  let file = "_build/task12-directory-kind-file"
  cleanup_generation_test_directory(directory)
  if @fs.path_exists(file) {
    @fs.remove_file(file)
  }
  @fs.create_dir(directory)
  @fs.write_string_to_file(file, "not a directory")
  inspect(directory_kind(directory), content="0")
  inspect(directory_kind("_build/task12-directory-kind-missing"), content="1")
  inspect(directory_kind(file), content="2")
  @fs.remove_file(file)
  @fs.remove_dir(directory)
}

///|
test "update requires an exact owned directory and preserves rejected bytes" {
  let output = "_build/task12-update"
  cleanup_generation_test_directory(output)
  let created = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--contract", "fixtures/contracts/externref.contract.json",
    "--out", output,
  ])
  inspect(created.exit_code, content="0")
  let before = generated_snapshot(output)
  let updated = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", output, "--update",
  ])
  inspect(updated.exit_code, content="0")
  inspect(generated_snapshot(output) == before, content="true")

  @fs.write_string_to_file("\{output}/adapter.ts", "user edit")
  let edited = @fs.read_file_to_bytes("\{output}/adapter.ts")
  let rejected_edit = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", output, "--update",
  ])
  inspect(rejected_edit.exit_code, content="3")
  inspect(rejected_edit.stderr.contains("MHA_OUTPUT_UNOWNED"), content="true")
  inspect(
    @fs.read_file_to_bytes("\{output}/adapter.ts") == edited,
    content="true",
  )
  cleanup_generation_test_directory(output)

  let recreated = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--contract", "fixtures/contracts/externref.contract.json",
    "--out", output,
  ])
  inspect(recreated.exit_code, content="0")
  let complete_before_manifest_removal = generated_snapshot(output)
  @fs.remove_file("\{output}/moonhostabi.manifest.json")
  let without_manifest = complete_before_manifest_removal[:2].to_owned()
  let rejected_missing = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", output, "--update",
  ])
  inspect(rejected_missing.exit_code, content="3")
  inspect(
    rejected_missing.stderr.contains("MHA_OUTPUT_UNOWNED"),
    content="true",
  )
  inspect(
    [
      @fs.read_file_to_bytes("\{output}/adapter.ts"),
      @fs.read_file_to_bytes("\{output}/moonhostabi.contract.json"),
    ] ==
    without_manifest,
    content="true",
  )
  cleanup_generation_test_directory(output)

  let recreated_again = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--contract", "fixtures/contracts/externref.contract.json",
    "--out", output,
  ])
  inspect(recreated_again.exit_code, content="0")
  let unknown = "\{output}/notes.txt"
  @fs.write_string_to_file(unknown, "keep me")
  let rejected_unknown = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", output, "--update",
  ])
  inspect(rejected_unknown.exit_code, content="3")
  inspect(
    rejected_unknown.stderr.contains("MHA_OUTPUT_UNOWNED"),
    content="true",
  )
  inspect(@fs.read_file_to_string(unknown), content="keep me")
  @fs.remove_file(unknown)
  cleanup_generation_test_directory(output)

  let recreated_for_manifest = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--contract", "fixtures/contracts/externref.contract.json",
    "--out", output,
  ])
  inspect(recreated_for_manifest.exit_code, content="0")
  let manifest_path = "\{output}/moonhostabi.manifest.json"
  let wrong_abi_manifest = @fs.read_file_to_string(manifest_path).replace(
    old="ecc9ee29e442515286ed65d66f0b3765c3beb015e086e9022fe641d9e0ccc6d7",
    new="0000000000000000000000000000000000000000000000000000000000000000",
  )
  @fs.write_string_to_file(manifest_path, wrong_abi_manifest)
  let rejected_manifest = dispatch([
    "generate", "fixtures/artifacts/externref.wasm", "--out", output, "--update",
  ])
  inspect(rejected_manifest.exit_code, content="3")
  inspect(
    rejected_manifest.stderr.contains("MHA_OUTPUT_UNOWNED"),
    content="true",
  )
  inspect(@fs.read_file_to_string(manifest_path), content=wrong_abi_manifest)
  cleanup_generation_test_directory(output)
}

///|
test "update recovers from second-write and post-backup failures" {
  let output = "_build/task12-recovery"
  cleanup_generation_test_directory(output)
  let generated = transaction_fixture()
  publish_generated_directory(output, generated, Fresh, None, None)
  let before = generated_snapshot(output)
  let second_write = publish_error(
    output,
    generated,
    Update,
    Some(FailSecondWrite),
  )
  inspect(second_write.contains("MHA_OUTPUT_IO"), content="true")
  inspect(generated_snapshot(output) == before, content="true")
  inspect(transaction_siblings("task12-recovery").is_empty(), content="true")
  let after_backup = publish_error(
    output,
    generated,
    Update,
    Some(FailAfterBackup),
  )
  inspect(after_backup.contains("MHA_OUTPUT_IO"), content="true")
  inspect(generated_snapshot(output) == before, content="true")
  inspect(transaction_siblings("task12-recovery").is_empty(), content="true")
  cleanup_generation_test_directory(output)
}

///|
test "update rejects a valid concurrent replacement after validation" {
  let output = "_build/task12-snapshot-race"
  cleanup_generation_test_directory(output)
  let generated = transaction_fixture()
  publish_generated_directory(output, generated, Fresh, None, None)
  let before = generated_snapshot(output)
  let replaced = publish_error(
    output,
    generated,
    Update,
    Some(ReplaceBeforeClaim),
  )
  inspect(replaced.contains("MHA_OUTPUT_UNOWNED"), content="true")
  let claimed_replacement = generated_snapshot(output)
  inspect(claimed_replacement[0] != before[0], content="true")
  inspect(claimed_replacement[1] == before[1], content="true")
  inspect(claimed_replacement[2] != before[2], content="true")
  let replacement_snapshot = validate_owned_generation_directory(
    output,
    generated.abi_sha256,
  )
  inspect(
    transaction_siblings("task12-snapshot-race").is_empty(),
    content="true",
  )
  publish_generated_directory(
    output,
    generated,
    Update,
    None,
    Some(replacement_snapshot),
  )
  inspect(generated_snapshot(output) == before, content="true")
  cleanup_generation_test_directory(output)
}

///|
test "cleanup never deletes files outside the owned output set" {
  let output = "_build/task12-cleanup-safety"
  let unknown = "\{output}/notes.txt"
  cleanup_generation_test_directory(output)
  if @fs.path_exists(unknown) {
    @fs.remove_file(unknown)
  }
  if @fs.path_exists(output) {
    @fs.remove_dir(output)
  }
  @fs.create_dir(output)
  @fs.write_string_to_file("\{output}/adapter.ts", "owned")
  @fs.write_string_to_file(unknown, "user-owned")
  let cleaned = cleanup_owned_generation_directory(
    OwnedGenerationDirectory(output),
  )
  inspect(cleaned, content="false")
  inspect(@fs.read_file_to_string("\{output}/adapter.ts"), content="owned")
  inspect(@fs.read_file_to_string(unknown), content="user-owned")
  @fs.remove_file("\{output}/adapter.ts")
  @fs.remove_file(unknown)
  @fs.remove_dir(output)
}

///|
test "cleanup errors only report transaction paths that remain present" {
  let missing = "_build/task12-missing-staging"
  cleanup_generation_test_directory(missing)
  let message = transaction_path_failure_detail(
    "injected failure", "staging", missing,
  )
  inspect(message.contains("retained staging path"), content="false")
  inspect(message.contains("staging path disappeared"), content="true")
}
