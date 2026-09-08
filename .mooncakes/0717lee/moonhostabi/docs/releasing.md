# Release dry-run guide

MoonHostABI's release workflow builds and aggregates immutable artifacts but
does not publish a tag or GitHub Release. Publication remains disabled until a
human authorizes the exact commit after both remote matrix jobs pass.

## Release outputs

For version `X.Y.Z`, each platform job creates one archive with a same-named
root directory:

```text
moonhostabi-vX.Y.Z-windows-x86_64.zip
moonhostabi-vX.Y.Z-linux-x86_64.tar.gz
```

Each root contains exactly these payload files (the tar also carries the
required root, `bin`, `docs`, and `examples` directory entries):

```text
LICENSE
README.md
bin/moonhostabi[.exe]
docs/report-schema.md
docs/validation.md
examples/artifact.wasm
examples/host-abi.lock.json
examples/moonhostabi.contract.json
```

The self-contained example lets the packaged executable run a real `verify`
smoke after extraction. The smoke must use the unpacked binary and bundled
artifact, lock, and contract; the checkout binary is not accepted as evidence.

The aggregate job accepts exactly both archives and their platform evidence,
then emits exactly:

```text
moonhostabi-vX.Y.Z-linux-x86_64.tar.gz
moonhostabi-vX.Y.Z-windows-x86_64.zip
SHA256SUMS
provenance.json
```

`SHA256SUMS` uses lowercase SHA-256, two spaces, ordinal filename order, UTF-8
without BOM, and LF. `provenance.json` records schema/release version, the full
source commit and clean-tree boolean, both platform/architecture/tool records,
and archive name/hash/size. It has no current timestamp, local path, username,
credential, workflow log, or self-hash.

## Local dry run

Prerequisites are PowerShell 7+, Python 3.11, the pinned MoonBit toolchain, and
the repository setup described in the main README. The remote workflow selects
MoonBit installer snapshot `0.10.11+6ff76a5f9` and verifies the reported `moon`,
`moonc`, and `moonrun` identities separately. Workflow validation uses
PyYAML 6.0.3; CI installs it from
`scripts/requirements-workflow-validation.txt` with platform wheel hashes.

Create a fresh output directory and package the current platform:

```powershell
$packageOutput = Join-Path ([IO.Path]::GetTempPath()) 'moonhostabi-package-new'
$evidenceOutput = Join-Path ([IO.Path]::GetTempPath()) 'windows.evidence.json'
[IO.Directory]::CreateDirectory($packageOutput) | Out-Null
pwsh -NoProfile -File scripts/package-release.ps1 `
  -Version 0.1.1 `
  -Output $packageOutput `
  -EvidenceOut $evidenceOutput
```

`-Version` must be strict `MAJOR.MINOR.PATCH` and equal `moon.mod`, CLI
`--version`, and the committed generator manifest version. Packaging requires
an x86_64 Windows or Linux host, a real empty output directory, and non-linked
path ancestry. Existing targets are never overwritten.

Run the full local packaging contract:

```powershell
pwsh -NoProfile -File scripts/verify-release-packaging.ps1
```

On Windows this builds two independent Windows ZIPs, compares exact bytes,
validates layout/metadata, and runs unpacked CLI smoke tests. It statically
checks the GNU tar/gzip contract and uses an explicitly simulated Linux archive
only to test aggregate success and failure paths. The simulation is marked in
evidence, cannot claim smoke success, and is rejected by production aggregation
unless the test-only switch is explicit. The workflow is configured to perform
the real Linux package path on Ubuntu. The Verification matrix and the
dispatch-only Release dry run are green for the current commit; repeat both gates
for every release candidate before publication.

## Deterministic archive rules

- Windows ZIP: ordinal entry order, `/` paths, stored/no compression, timestamp
  `1980-01-01 00:00:00`, and zero external attributes.
- Linux tar.gz: GNU tar name sorting, epoch mtime, root uid/gid and names,
  normalized `0755` directory/CLI mode and `0644` data mode,
  GNU format, `LC_ALL=C`, `TZ=UTC`, and a single `gzip -n -9` member with no
  trailing data.
- Validators reject absolute, drive-qualified, traversal, backslash-ambiguous,
  duplicate/case-fold-colliding paths and tar symlink, hardlink, device, FIFO,
  socket, or other non-regular entries.

Same input and recorded platform toolchain must reproduce identical bytes.
Windows and Linux archives are different products and are not expected to have
the same hash.

## Workflow dry run

`.github/workflows/release.yml` has only `workflow_dispatch`, top-level
`contents: read`, no secrets, and no GitHub Release API. With explicit
authorization to run remote CI, it preflights the fixed Linux/Windows MoonBit
binary archives, installs the pinned snapshot, resolves dependencies with
`moon check` before applying the guarded parser patch, and rejects a
moon/moonc/moonrun version mismatch before building. This workflow
has not yet been run remotely; the following steps are its acceptance procedure:

1. Open **Actions → Release dry run → Run workflow**.
2. Enter the exact version from `moon.mod`.
3. Confirm the Linux and Windows package jobs run on the same source commit.
4. Confirm each job uploads one versioned archive plus its canonical evidence.
5. Confirm the Ubuntu aggregate job downloads both immutable handoffs, rejects
   any missing/extra/tampered input, and uploads one
   `moonhostabi-release-dry-run` artifact.
6. Download that artifact, run `sha256sum -c SHA256SUMS`, inspect
   `provenance.json`, and independently run both unpacked smoke paths on their
   target OS.

The workflow does not create a tag or release even when all jobs are green.

## Pinned workflow actions

All action references use immutable 40-character commit SHAs. Tags are comments
for human traceability:

| Action | Release | Pinned commit |
| --- | --- | --- |
| [`actions/checkout`](https://github.com/actions/checkout/releases/tag/v7.0.1) | `v7.0.1` | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| [`actions/setup-node`](https://github.com/actions/setup-node/releases/tag/v7.0.0) | `v7.0.0` | `820762786026740c76f36085b0efc47a31fe5020` |
| [`actions/setup-python`](https://github.com/actions/setup-python/releases/tag/v7.0.0) | `v7.0.0` | `5fda3b95a4ea91299a34e894583c3862153e4b97` |
| [`actions/upload-artifact`](https://github.com/actions/upload-artifact/releases/tag/v7.0.1) | `v7.0.1` | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` |
| [`actions/download-artifact`](https://github.com/actions/download-artifact/releases/tag/v8.0.1) | `v8.0.1` | `3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c` |

## Publication checklist

Before any future publication, a human must confirm:

- the release commit and working tree are exact and clean;
- module, CLI, generator manifest, input, archive, and provenance versions agree;
- local full gate and package-layout negatives pass;
- remote Windows and Linux jobs are green for the same commit, with immutable
  run URLs recorded in `docs/validation.md`;
- both platform archives pass unpacked smoke on their target OS;
- `SHA256SUMS` and `provenance.json` independently match downloaded bytes;
- no archive contains caches, `.git`, `.codex`, node_modules, local paths,
  credentials, logs, symlinks, hardlinks, or special files;
- publication authorization names the exact version, tag, commit, and artifacts.

## Rollback and withdrawal

The current workflow is dry-run only, so rollback means canceling the run or
deleting its temporary Actions artifact according to retention policy; source,
tags, and releases are unchanged. If a future separately authorized publication
is found invalid, stop distribution, preserve the evidence, mark the release as
withdrawn, and issue a new version after fixing the cause. Never replace an
already published archive under the same version or force-move its tag.
