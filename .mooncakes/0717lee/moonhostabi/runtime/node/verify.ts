import { readFile } from "node:fs/promises";

import {
  createHostImports,
  instantiate,
} from "../generated/adapter.js";

type HostToken = {
  readonly marker: "moonhostabi-node-token";
};

function invariant(condition: boolean, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

const artifactUrl = new URL(
  "../../../fixtures/artifacts/externref.wasm",
  import.meta.url,
);
const fileBytes = await readFile(artifactUrl);
const bytes = Uint8Array.from(fileBytes);
const token: HostToken = Object.freeze({ marker: "moonhostabi-node-token" });
const trace: HostToken[] = [];
const imports = createHostImports<HostToken>();
imports.host.echo = (argument) => {
  trace.push(argument);
  return argument;
};

const exports = await instantiate(bytes, imports);
const sum = exports.add(20, 22);
invariant(sum === 42, `expected add(20, 22) to equal 42, received ${sum}`);

const returned = exports.roundtrip(token);
invariant(returned === token, "externref round-trip did not preserve identity");
invariant(trace.length === 1, `expected one host.echo call, received ${trace.length}`);
invariant(trace[0] === token, "host.echo received a different externref object");

console.log(
  JSON.stringify({
    result: sum,
    externrefIdentity: returned === token,
    traceCount: trace.length,
    traceArgumentIdentity: trace[0] === token,
  }),
);
