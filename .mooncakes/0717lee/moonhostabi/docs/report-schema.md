# Verification report schema v1

`moonhostabi verify` emits one canonical JSON document describing the complete
Host ABI release decision:

```text
moonhostabi verify <artifact.wasm> --against <lock.json> [--contract <contract.json>] --format json
```

For readable inputs, the document is written to stdout and stderr stays empty.
CLI usage errors and unreadable paths are stderr-only failures and are not
verification reports.

## Canonical encoding

Schema v1 is UTF-8 JSON with no insignificant whitespace. Object fields use the
order documented below; arrays retain the canonical order produced by the
projector, compatibility engine, and generator. The CLI terminates stdout with
the platform newline. A reproduction bundle stores the same JSON line with one
LF byte.

Consumers must inspect `schemaVersion` before reading any other field. Unknown
versions must fail closed; v1 has no negotiation or implicit migration.

## Top-level fields

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | Exactly `1`. |
| `outcome` | string | Aggregate result: `compatible`, `breaking`, `unknown`, `invalid`, or `adapterMismatch`. |
| `artifact` | object | Parse/projection result for the exact current artifact bytes. |
| `baseline` | object | Lockfile decoding result and its stored fingerprints. |
| `provenance` | object | Exact artifact and canonical ABI fingerprint comparisons. |
| `compatibility` | object | Semantic Host ABI comparison and ordered changes. |
| `contract` | object | Optional host contract validation result. |
| `generator` | object | TypeScript adapter representability result. |

When multiple failures coexist, the aggregate precedence is:

1. invalid artifact/baseline;
2. unknown compatibility;
3. invalid contract or unrepresentable generator boundary;
4. breaking compatibility;
5. compatible.

This precedence chooses one process exit code without discarding details from
the other sections.

## `artifact`

| Field | Type | Meaning |
| --- | --- | --- |
| `status` | string | `valid`, `unsupported`, or `invalid`. |
| `sha256` | string | Lowercase SHA-256 of the exact artifact bytes, even when parsing fails. |
| `abiSha256` | string or `null` | SHA-256 of canonical Host ABI JSON; `null` when the artifact cannot be parsed. |
| `diagnostics` | diagnostic array | Projection or parse diagnostics in deterministic order. |

`valid` means parsing and the configured JavaScript projection completed with
no diagnostics. `unsupported` means parsing succeeded but one or more public
items or value types cross an unsupported boundary. `invalid` means no Host ABI
could be projected.

## `baseline`

| Field | Type | Meaning |
| --- | --- | --- |
| `status` | string | `valid` or `invalid`. |
| `artifactSha256` | string or `null` | Exact artifact provenance stored by a valid lockfile. |
| `abiSha256` | string or `null` | Canonical ABI fingerprint stored by a valid lockfile. |
| `diagnostic` | diagnostic or `null` | One lockfile error when invalid; otherwise `null`. |

An invalid baseline cannot participate in compatibility or provenance
comparison. It does not prevent independently reporting artifact, contract, and
generator evidence when artifact analysis succeeded.

## `provenance`

| Field | Type | Meaning |
| --- | --- | --- |
| `artifactMatchesBaseline` | boolean or `null` | Exact current artifact SHA-256 equals the lockfile artifact fingerprint. |
| `abiMatchesBaseline` | boolean or `null` | Current canonical ABI SHA-256 equals the lockfile ABI fingerprint. |

Both values are `null` when artifact analysis or baseline decoding prevents the
comparison. Different artifact bytes can yield `false`/`true`: artifact
provenance changed while semantic ABI identity did not. Provenance mismatch by
itself is evidence, not a breaking classification.

## `compatibility`

| Field | Type | Meaning |
| --- | --- | --- |
| `status` | string | `evaluated` or `notEvaluated`. |
| `classification` | string or `null` | `compatible`, `breaking`, or `unknown`; `null` when not evaluated. |
| `changes` | change array | Deterministically ordered ABI changes; empty when none or not evaluated. |

Schema v1 uses the semantic compatibility policy. `compatible` means an
existing host remains usable, not that artifact bytes are identical. `breaking`
means an existing host contract is no longer sufficient. `unknown` is a
fail-closed result for unsupported schema, features, items, or values.

A change object has fields in this order:

| Field | Type | Meaning |
| --- | --- | --- |
| `classification` | string | `compatible`, `breaking`, or `unknown` for this change. |
| `code` | string | Stable machine-readable `MHA_*` code. |
| `path` | string | Stable diagnostic location described below. |
| `message` | string | Human-readable explanation; do not branch on it. |

## `contract`

| Status | `diagnostic` | Meaning |
| --- | --- | --- |
| `notProvided` | `null` | No contract argument was supplied. Generator representability is still checked with a deterministic draft contract. |
| `valid` | `null` | The supplied canonical contract matches the current ABI. |
| `invalid` | diagnostic | The supplied bytes, schema, canonical form, aliases, or ABI fingerprint are invalid. |
| `notEvaluated` | `null` | Artifact failure prevented contract evaluation. |

## `generator`

| Status | `diagnostics` | Meaning |
| --- | --- | --- |
| `representable` | empty array | The ABI and effective contract can produce the supported TypeScript adapter. |
| `unrepresentable` | non-empty array | Adapter generation found an unsupported or mismatched boundary. |
| `notEvaluated` | empty array | Earlier artifact or contract failure prevented evaluation. |

The verifier calls the generator's validation path but does not publish files,
instantiate Wasm, or execute generated host behavior.

## Diagnostics and paths

A diagnostic object has fields in this order:

| Field | Type | Meaning |
| --- | --- | --- |
| `code` | string | Stable `MHA_*` identifier. |
| `severity` | string | `info`, `warning`, or `error`. |
| `path` | string | Location in the artifact/ABI/contract model. |
| `message` | string | Human-readable context. |
| `byteOffset` | integer or `null` | Artifact byte offset when one is available; otherwise `null`. |

Schema v1 emits these path families:

```text
artifact | baseline | contract | schemaVersion
features[<feature>]
imports[<module>.<name>]
imports[<module>.<name>].params
imports[<module>.<name>].params[<index>]
imports[<module>.<name>].results
imports[<module>.<name>].results[<index>]
imports[<module>.<name>].type[<index>]
exports[<name>]
exports[<name>].params
exports[<name>].params[<index>]
exports[<name>].results
exports[<name>].results[<index>]
exports[<name>].functions[<index>]
types[type[<index>]]
types[type[<index>]].kind
types[type[<index>]].final
types[type[<index>]].supertypes
types[type[<index>]].supertypes[<index>]
types[type[<index>]].fields
types[type[<index>]].fields[<index>]
types[type[<index>]].fields[<index>].storage
types[type[<index>]].fields[<index>].mutable
types[type[<index>]].element
types[type[<index>]].element.storage
types[type[<index>]].element.mutable
```

Angle-bracket values are descriptive placeholders, not an escaping grammar.
Module, function, and feature names may contain punctuation, so consumers should
compare complete paths or treat them as opaque display locations rather than
splitting them on `.` or brackets.

## Exit codes

| Exit | Report outcome / boundary |
| --- | --- |
| `0` | `compatible` |
| `1` | CLI usage error; no report is guaranteed |
| `2` | `breaking` |
| `3` | `unknown` or `invalid`; also unreadable input errors on stderr |
| `4` | `adapterMismatch` |
| `5` | Unexpected CLI/runtime failure; no report is guaranteed |

Automation should use both the exit code and `outcome`. It must not infer
success from parseable JSON alone.

## Verified example

The reproduction-bundle gate compares this exact line with a fresh public CLI
`verify` run over the committed `externref.wasm` fixture and contract.

<!-- BEGIN VERIFIED REPORT EXAMPLE -->
```json
{"schemaVersion":1,"outcome":"compatible","artifact":{"status":"valid","sha256":"a748ac44370fd11670fc00d3a1a540809823b2370bc734518cbfc849a88da057","abiSha256":"ecc9ee29e442515286ed65d66f0b3765c3beb015e086e9022fe641d9e0ccc6d7","diagnostics":[]},"baseline":{"status":"valid","artifactSha256":"a748ac44370fd11670fc00d3a1a540809823b2370bc734518cbfc849a88da057","abiSha256":"ecc9ee29e442515286ed65d66f0b3765c3beb015e086e9022fe641d9e0ccc6d7","diagnostic":null},"provenance":{"artifactMatchesBaseline":true,"abiMatchesBaseline":true},"compatibility":{"status":"evaluated","classification":"compatible","changes":[]},"contract":{"status":"valid","diagnostic":null},"generator":{"status":"representable","diagnostics":[]}}
```
<!-- END VERIFIED REPORT EXAMPLE -->

## Evolution policy

Field order, enum strings, null placement, diagnostic/change shape, and outcome
precedence are part of schema v1's canonical contract. An incompatible change
requires a new integer `schemaVersion`, new exact golden tests, and explicit
consumer opt-in. MoonHostABI currently implements no report migration. New
diagnostic codes and paths may appear within v1 when they use the existing
diagnostic shape; consumers should branch on known codes and fail closed on an
unsupported aggregate outcome.
