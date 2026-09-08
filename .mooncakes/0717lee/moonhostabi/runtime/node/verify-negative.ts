import { Buffer } from "node:buffer";
import { readFile } from "node:fs/promises";

import {
  createHostImports,
  instantiate,
  type HostImports,
} from "../generated/adapter.js";

type HostToken = {
  readonly marker: "moonhostabi-negative-token";
};

const negativeModules = {
  missingRoundtrip:
    "AGFzbQEAAAABBwFgAn9/AX8DAgEABwcBA2FkZAAACgkBBwAgACABags=",
  renamedAdd:
    "AGFzbQEAAAABDAJgAn9/AX9gAW8BbwMDAgABBxsCC3JlbmFtZWQtYWRkAAAJcm91bmR0cmlwAAEKDgIHACAAIAFqCwQAIAAL",
  nonFunctionAdd:
    "AGFzbQEAAAABBgFgAW8BbwMCAQAGBgF/AEEACwcTAgNhZGQDAAlyb3VuZHRyaXAAAAoGAQQAIAAL",
} as const;

function invariant(condition: boolean, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

function decodeModule(encoded: string): Uint8Array<ArrayBuffer> {
  const decoded = Buffer.from(encoded, "base64");
  const bytes = new Uint8Array(decoded.byteLength);
  bytes.set(decoded);
  return bytes;
}

async function expectAdapterMismatch(
  description: string,
  bytes: BufferSource,
  imports: HostImports<HostToken>,
  expectedMessage: string,
): Promise<void> {
  let observed: unknown;
  try {
    await instantiate(bytes, imports);
  } catch (error) {
    observed = error;
  }

  invariant(observed instanceof Error, `${description}: expected an Error`);
  invariant(
    observed.message === expectedMessage,
    `${description}: expected ${JSON.stringify(expectedMessage)}, received ${JSON.stringify(observed.message)}`,
  );
}

const artifactUrl = new URL(
  "../../../fixtures/artifacts/externref.wasm",
  import.meta.url,
);
const fileBytes = await readFile(artifactUrl);
const validBytes = Uint8Array.from(fileBytes);
const missingEcho = { host: {} } as unknown as HostImports<HostToken>;
const validImports = createHostImports<HostToken>();
validImports.host.echo = (value) => value;

await expectAdapterMismatch(
  "missing host import",
  validBytes,
  missingEcho,
  "MHA_ADAPTER_MISMATCH: host import imports[host.echo] must be a function",
);
await expectAdapterMismatch(
  "missing roundtrip export",
  decodeModule(negativeModules.missingRoundtrip),
  validImports,
  "MHA_ADAPTER_MISMATCH: module export exports[roundtrip] must be a function",
);
await expectAdapterMismatch(
  "renamed add export",
  decodeModule(negativeModules.renamedAdd),
  validImports,
  "MHA_ADAPTER_MISMATCH: module export exports[add] must be a function",
);
await expectAdapterMismatch(
  "non-function add export",
  decodeModule(negativeModules.nonFunctionAdd),
  validImports,
  "MHA_ADAPTER_MISMATCH: module export exports[add] must be a function",
);

console.log(
  JSON.stringify({
    code: "MHA_ADAPTER_MISMATCH",
    paths: [
      "imports[host.echo]",
      "exports[roundtrip]",
      "exports[add]",
      "exports[add]",
    ],
    observed: true,
  }),
);
