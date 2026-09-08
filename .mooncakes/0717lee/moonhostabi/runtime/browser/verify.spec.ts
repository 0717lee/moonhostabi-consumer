import { expect, test } from "playwright/test";

function capturePageFailures(page: import("playwright").Page) {
  const failures: string[] = [];
  page.on("pageerror", (error) => failures.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") {
      failures.push(`console: ${message.text()}`);
    }
  });
  return failures;
}

test("server exposes only the browser verification assets", async ({ request }) => {
  const html = await request.get("/");
  expect(html.status()).toBe(200);
  expect(html.headers()["content-type"]).toBe("text/html; charset=utf-8");

  const adapter = await request.get("/dist/generated/adapter.js");
  expect(adapter.status()).toBe(200);
  expect(adapter.headers()["content-type"]).toBe(
    "text/javascript; charset=utf-8",
  );

  const wasm = await request.get("/fixtures/artifacts/externref.wasm");
  expect(wasm.status()).toBe(200);
  expect(wasm.headers()["content-type"]).toBe("application/wasm");
  expect(WebAssembly.validate(await wasm.body())).toBe(true);

  expect((await request.get("/package.json")).status()).toBe(404);
  expect((await request.get("/%2e%2e/package.json")).status()).toBe(404);
  const post = await request.post("/");
  expect(post.status()).toBe(405);
  expect(post.headers().allow).toBe("GET, HEAD");
});

test("Chromium executes the real scalar and externref paths", async ({ page }) => {
  const failures = capturePageFailures(page);
  await page.goto("/");

  await expect(page.locator("#result")).toHaveText("42");
  await expect(page.locator("#externref-identity")).toHaveText("true");
  await expect(page.locator("#trace")).toHaveText(
    '{"count":1,"argumentIdentity":true}',
  );
  expect(failures).toEqual([]);
});

const negativeCases = [
  {
    name: "a missing required host import",
    query: "negative",
    message:
      "MHA_ADAPTER_MISMATCH: host import imports[host.echo] must be a function",
  },
  {
    name: "a missing roundtrip export",
    query: "missing-roundtrip",
    message:
      "MHA_ADAPTER_MISMATCH: module export exports[roundtrip] must be a function",
  },
  {
    name: "a renamed add export",
    query: "renamed-add",
    message:
      "MHA_ADAPTER_MISMATCH: module export exports[add] must be a function",
  },
  {
    name: "a non-function add export",
    query: "non-function-add",
    message:
      "MHA_ADAPTER_MISMATCH: module export exports[add] must be a function",
  },
] as const;

for (const scenario of negativeCases) {
  test(`Chromium rejects ${scenario.name}`, async ({ page }) => {
    const failures = capturePageFailures(page);
    await page.goto(`/?case=${scenario.query}`);

    const error = page.locator("#error");
    await expect(error).toHaveAttribute("data-status", "observed");
    await expect(error).toHaveText(scenario.message);
    expect(failures).toEqual([]);
  });
}
