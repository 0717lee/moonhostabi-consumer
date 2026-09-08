# Dependency patches

## `wasm_core-0.14.0-singleton-rec.patch`

MoonBit 0.10.11 emits a self-recursive struct as an implicit singleton recursive
type. The artifact is valid according to `wasm-tools 1.258.0`, but
`Milky2018/wasm_core@0.14.0` resolves the field's typed self-reference before
inserting the current type into its parser table and raises `invalid heap type`.

The patch applies the placeholder strategy already used by `wasm_core` for an
explicit `rec` group to the implicit singleton branch. It is intentionally kept
as a standalone upstream-shaped diff rather than copied into MoonHostABI's
parser adapter.

The regression is exercised with the compiler-produced
`fixtures/artifacts/recursive.wasm`:

```powershell
pwsh -NoProfile -File scripts/apply-wasm-core-patch.ps1
moon test src/projector --target native
```

The application script is idempotent and refuses versions other than `0.14.0`
or a target source file whose normalized UTF-8/LF SHA-256 is neither the
reviewed baseline nor the reviewed patched result. Newline normalization keeps
the guard cross-platform while all non-newline source drift is rejected. Remove
this patch and the script after upgrading to an upstream release containing the
same fix.
