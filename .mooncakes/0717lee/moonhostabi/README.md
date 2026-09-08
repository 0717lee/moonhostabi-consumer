# MoonHostABI

Artifact-first MoonBit Wasm-GC Host ABI lock, adapter, and validation toolchain.

MoonHostABI projects a runtime-facing ABI from compiled MoonBit Wasm-GC,
canonicalizes recursive types independently of raw indices, detects breaking
host-contract drift, and emits a strict TypeScript/ESM adapter. The proof-grade
Spike is **GO** locally and on the public Linux/Windows CI matrix; see [the
validation evidence](docs/validation.md) for hashes, the compatibility matrix,
runtime observations, and limits.

## Judge quickstart

MoonHostABI makes a compiled MoonBit Wasm-GC artifact's host-facing ABI
reviewable before host code is shipped: one lock, one canonical report, and
one deterministic reproduction bundle provide the evidence trail. From a clean
repository root, run the three focused checks below and look for their exact
`GO` markers. The full walkthrough is [the judge quickstart](docs/quickstart.md).

| Check | Command | Expected marker |
| --- | --- | --- |
| CLI evidence | `pwsh -NoProfile -File scripts/verify-command.ps1` | `MOONHOSTABI_VERIFY_STATUS=GO` |
| Reproduction bundle | `pwsh -NoProfile -File scripts/verify-reproduction-bundle.ps1` | `MOONHOSTABI_BUNDLE_STATUS=GO` |
| Platform package | `pwsh -NoProfile -File scripts/verify-release-packaging.ps1` | `MOONHOSTABI_PACKAGE_STATUS=GO` |

The package check is locally observed on Windows, while the public Verification
matrix exercises the native CLI path on both Linux and Windows. Release archive
aggregation remains a separate dispatch-only dry run documented below.

## Reproduce the Spike

Prerequisites are PowerShell 7, a MoonBit toolchain reporting `moon
0.1.20260827` / `moonc v0.10.11+6ff76a5f9` / `moonrun 0.1.20260827`, Node.js
`24.12.0` with npm `11.6.2`, and `wasm-tools 1.258.0`. CI obtains that
toolchain from the official installer snapshot `0.10.11+6ff76a5f9`; the
snapshot selector is distinct from the reported `moon` version. The command
below installs locked npm dependencies and the pinned Playwright Chromium
build as part of the gate:

```powershell
pwsh -NoProfile -File scripts/verify-spike.ps1
```

Success ends with `MOONHOSTABI_SPIKE_STATUS=GO`.

## CLI surface

Run the native CLI from source:

```powershell
moon run cmd/moonhostabi --target native inspect <artifact.wasm> --format json
moon run cmd/moonhostabi --target native lock <artifact.wasm> --out <lock.json>
moon run cmd/moonhostabi --target native check <artifact.wasm> --against <lock.json>
moon run cmd/moonhostabi --target native verify <artifact.wasm> --against <lock.json> --format json
moon run cmd/moonhostabi --target native verify <artifact.wasm> --against <lock.json> --contract <contract.json> --format json
moon run cmd/moonhostabi --target native generate <artifact.wasm> --out <new-directory>
moon run cmd/moonhostabi --target native generate <artifact.wasm> --out <owned-directory> --update
moon run cmd/moonhostabi --target native generate <artifact.wasm> --out <new-directory> --dry-run
moon run cmd/moonhostabi --target native -- --help
moon run cmd/moonhostabi --target native -- --version
```

`verify` is the machine-facing release gate. It emits one canonical JSON report
on stdout with `artifact`, `baseline`, `provenance`, `compatibility`, `contract`,
and `generator` sections. It parses and analyzes Wasm bytes but never
instantiates them or runs host behavior. `--contract` is optional and its
absence is reported explicitly as `notProvided`; generator representability is
still checked against a deterministic draft contract.

The stable verification exit codes are:

| Exit | Meaning |
| --- | --- |
| `0` | compatible and representable |
| `1` | invalid CLI usage |
| `2` | breaking ABI |
| `3` | invalid artifact/baseline or unsupported/unknown compatibility |
| `4` | invalid contract or adapter/generator mismatch |
| `5` | unexpected runtime failure |

For combined findings, an invalid artifact/baseline or unknown compatibility
takes precedence, followed by a contract or generator mismatch, then a
breaking ABI.

Readable but invalid lockfiles, contracts, and artifacts are represented in the
canonical report. Missing or unreadable paths remain I/O errors on stderr.
Option order is intentionally strict; use `--help` as the authoritative grammar.
The real-process verification suite, including paths containing Chinese
characters and spaces, can be run independently:

```powershell
pwsh -NoProfile -File scripts/verify-command.ps1
```

`generate` also accepts `--contract <contract.json>` before `--out`. Generated
defaults throw for user-owned imports; they never invent host business logic.
Unsupported JavaScript boundaries fail closed with structured diagnostics. A
successful fresh generation publishes `adapter.ts`,
`moonhostabi.contract.json`, and canonical `moonhostabi.manifest.json`
together from a unique sibling staging directory without replacing an existing
path.

`--dry-run` performs parsing, contract validation, and generation without
creating filesystem output. `--update` reuses the existing contract and only
replaces a real, non-link directory whose manifest, exact file set, and SHA-256
values prove MoonHostABI ownership. The directory is atomically claimed and its
exact byte snapshot is revalidated before publication. Edited, missing,
unknown, concurrently replaced, symbolic-link, and reparse-point outputs are
refused. There is no `--force` mode.

## Development setup

MoonHostABI currently carries a minimal, version-checked patch for a
`Milky2018/wasm_core@0.14.0` parser defect exposed by recursive Wasm-GC output
from MoonBit 0.10.11. Apply it after dependency resolution:

```powershell
moon update
moon check
pwsh -NoProfile -File scripts/apply-wasm-core-patch.ps1
```

On a clean checkout, `moon update` refreshes dependency metadata while `moon check`
materializes the source under `.mooncakes`; the guarded patch runs after that
resolution step.

The patch only teaches the upstream parser to resolve self-references in an
implicit singleton recursive type. It is kept separate from MoonHostABI's own
ABI logic so it can be removed when an upstream release contains the fix.
