# Reproduction bundle

MoonHostABI can package one compiled artifact, its canonical Host ABI evidence,
and a generated adapter into a deterministic ZIP without executing the Wasm.
No ZIP is committed here; bundles are generated from the repository-owned
fixtures when needed.

From the repository root:

```powershell
$ErrorActionPreference = 'Stop'
$archivePath = Join-Path ([IO.Path]::GetTempPath()) (
  'moonhostabi-reproduction-' + [Guid]::NewGuid().ToString('N') + '.zip'
)
try {
  & pwsh -NoProfile -File scripts/create-reproduction-bundle.ps1 `
    -Artifact fixtures/artifacts/externref.wasm `
    -Contract fixtures/contracts/externref.contract.json `
    -Out $archivePath
  if ($LASTEXITCODE -ne 0) { throw "Bundle creation failed: $LASTEXITCODE" }
}
finally {
  if ([IO.File]::Exists($archivePath)) { [IO.File]::Delete($archivePath) }
}
```

`-Contract` is optional. When omitted, the public `generate` command creates a
deterministic draft contract. The output parent must already be a real,
non-linked directory, and the output ZIP must not exist.

## Contents

Every archive has exactly these entries in this order:

```text
moonhostabi-reproduction/manifest.json
moonhostabi-reproduction/validation.json
moonhostabi-reproduction/host-abi.lock.json
moonhostabi-reproduction/moonhostabi.contract.json
moonhostabi-reproduction/adapter.ts
moonhostabi-reproduction/artifact.wasm
moonhostabi-reproduction/commands.txt
```

`manifest.json` records schema version 1, the MoonHostABI/tool versions, and the
SHA-256 plus byte size of each of the other six payloads. It intentionally does
not claim a hash for itself or the final ZIP: either would be a recursive
self-hash. The creation command and verification gate report the final archive
SHA-256 externally.

`validation.json` is stdout from the public `verify` command, normalized only to
UTF-8 without BOM and a final LF. The build chain also uses the public `lock`
and `generate` commands. It never instantiates `artifact.wasm` or invokes host
behavior.

After extracting the archive, enter `moonhostabi-reproduction` and run the
lines in `commands.txt` with a compatible `moonhostabi` executable. All paths
are bundle-relative; no repository, temporary, user, or machine path is stored.

## Integrity and determinism gate

Run the repository's focused verifier:

```powershell
pwsh -NoProfile -File scripts/verify-reproduction-bundle.ps1
```

It creates two bundles from independent input copies and staging runs, compares
the final ZIP hashes and every unpacked byte, validates the fixed entry set,
timestamp, manifest hashes/sizes, UTF-8/LF rules, and scans for local paths or
high-confidence credential markers. It also rejects traversal, absolute,
drive-qualified, duplicate, and unknown ZIP entries before extraction.

The negative gate covers artifact paths through a symlink/junction/reparse
point, existing output refusal, a failure immediately before publication, and
temporary/staging cleanup. Publication uses a same-directory staging file and a
no-overwrite move, so no command silently replaces an archive. Atomic rename is
expected on ordinary local filesystems; no atomicity claim is made for network
or nonstandard filesystems with weaker move semantics.

The mutation case appends one valid, deterministic empty custom section to the
Wasm. `artifact.wasm`, `host-abi.lock.json`, `validation.json`, and
`manifest.json` must change; `adapter.ts`, `moonhostabi.contract.json`, and
`commands.txt` must remain byte-identical because the canonical ABI is
unchanged.

## Platform boundary

The ZIP uses explicit entry order, `/` separators, no compression, zero external
attributes, and the legal DOS timestamp `1980-01-01 00:00:00`. Identical inputs
under the same recorded tool/runtime versions must produce identical bytes.
The local evidence currently comes from Windows; Linux behavior is configured
in CI but is not claimed as remotely observed until a green run exists.
