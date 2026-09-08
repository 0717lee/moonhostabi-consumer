# MoonHostABI consumer smoke test

This is a minimal independent MoonBit project that resolves the published
`0717lee/moonhostabi@0.1.1` package from Mooncakes. Its test imports the public
model and lockfile packages, creates a lockfile, roundtrips it, and checks the
canonical ABI fingerprint. It verifies that a clean downstream project can
resolve, compile, and call the published library API. A second test parses the
committed recursive Wasm-GC fixture (`rec-a.wasm`) through the published parser
and projector. The fixture intentionally exercises typed GC analysis while the
default JavaScript capability policy reports it as unrepresentable.

Run from this directory:

```powershell
moon check
moon test --target native
```

The consumer intentionally keeps its application logic small. MoonHostABI is a
native CLI/toolchain package; the repository under test remains the place for
artifact analysis and adapter generation. The dependency is resolved and built
by `moon check` even though the consumer does not import the CLI entrypoint.
