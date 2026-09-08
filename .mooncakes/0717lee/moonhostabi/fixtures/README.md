# MoonHostABI fixture corpus

This corpus is authored specifically for MoonHostABI. It does not reuse source or binaries from PixelForge or another submission.

| Fixture | Purpose | Expected public surface |
|---|---|---|
| `scalar` | Scalar code generation and runtime smoke test | `add(i32,i32)->i32`, `answer()->i64` |
| `externref` | Opaque host-object import plus one-artifact runtime demo | import `host.echo(externref)->externref`; exports `roundtrip` and `add` |
| `recursive` | Real MoonBit compiler Wasm-GC output | exports `new_node` and `node_value` over a recursive `Node` |
| `breaking_v1` | Compatibility baseline | `add(i32,i32)->i32` |
| `breaking_v2` | Seeded breaking candidate | `add(i32)->i32` |
| `rec-a` / `rec-reindexed` | Independent WAT type-index invariance pair | equivalent `node-null` recursive ABI |

Rebuild every artifact and Oracle printout from the repository root:

```powershell
pwsh -NoProfile -File scripts/build-fixtures.ps1
```

The script requires `moon 0.1.20260827` / `moonc 0.10.11+6ff76a5f9` and the
pinned `wasm-tools 1.258.0`; it refuses other versions. On Windows it discovers
the checksum-verified executable under `.tools/wasm-tools`; CI may provide the
same version on `PATH`. Outputs are staged and structurally validated before
the committed artifacts and Oracle files are replaced. Per-run build data is
removed unless `-KeepBuild` is supplied for diagnosis.
