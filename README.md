# MoonHostABI consumer smoke test

This is a minimal independent MoonBit project that resolves the published
`0717lee/moonhostabi@0.1.1` package from Mooncakes. It exists to verify that a
clean downstream project can resolve and build against the published module.

Run from this directory:

```powershell
moon check
```

The consumer intentionally keeps its application logic small. MoonHostABI is a
native CLI/toolchain package; the repository under test remains the place for
artifact analysis and adapter generation. The dependency is resolved and built
by `moon check` even though the consumer does not import the CLI entrypoint.
