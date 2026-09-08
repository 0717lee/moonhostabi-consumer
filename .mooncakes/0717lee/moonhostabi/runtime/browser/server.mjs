import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const browserDirectory = dirname(fileURLToPath(import.meta.url));
const runtimeDirectory = resolve(browserDirectory, "..");
const repositoryDirectory = resolve(runtimeDirectory, "..");
const port = 4173;

const assets = new Map([
  [
    "/",
    {
      path: resolve(browserDirectory, "index.html"),
      contentType: "text/html; charset=utf-8",
    },
  ],
  [
    "/index.html",
    {
      path: resolve(browserDirectory, "index.html"),
      contentType: "text/html; charset=utf-8",
    },
  ],
  [
    "/dist/generated/adapter.js",
    {
      path: resolve(runtimeDirectory, "dist", "generated", "adapter.js"),
      contentType: "text/javascript; charset=utf-8",
    },
  ],
  [
    "/fixtures/artifacts/externref.wasm",
    {
      path: resolve(
        repositoryDirectory,
        "fixtures",
        "artifacts",
        "externref.wasm",
      ),
      contentType: "application/wasm",
    },
  ],
]);

function sendText(response, status, message, extraHeaders = {}) {
  const body = Buffer.from(message, "utf8");
  response.writeHead(status, {
    "Content-Type": "text/plain; charset=utf-8",
    "Content-Length": String(body.byteLength),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...extraHeaders,
  });
  response.end(body);
}

const server = createServer(async (request, response) => {
  try {
    if (request.method !== "GET" && request.method !== "HEAD") {
      sendText(response, 405, "Method not allowed", { Allow: "GET, HEAD" });
      return;
    }
    const requestUrl = new URL(request.url ?? "/", "http://127.0.0.1");
    const asset = assets.get(requestUrl.pathname);
    if (asset === undefined) {
      sendText(response, 404, "Not found");
      return;
    }
    const body = await readFile(asset.path);
    response.writeHead(200, {
      "Content-Type": asset.contentType,
      "Content-Length": String(body.byteLength),
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    });
    response.end(request.method === "HEAD" ? undefined : body);
  } catch {
    sendText(response, 500, "Asset unavailable");
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`MoonHostABI browser verifier listening on http://127.0.0.1:${port}`);
});

function shutdown() {
  server.close(() => process.exit(0));
}

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
