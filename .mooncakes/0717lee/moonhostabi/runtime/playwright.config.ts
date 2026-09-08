import { fileURLToPath } from "node:url";

import { defineConfig } from "playwright/test";

const runtimeDirectory = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  testDir: "./browser",
  testMatch: "verify.spec.ts",
  fullyParallel: false,
  workers: 1,
  reporter: process.env.CI
    ? [["list"], ["html", { open: "never" }]]
    : "list",
  timeout: 30_000,
  expect: { timeout: 5_000 },
  use: {
    baseURL: "http://127.0.0.1:4173",
    browserName: "chromium",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "node browser/server.mjs",
    cwd: runtimeDirectory,
    url: "http://127.0.0.1:4173/",
    reuseExistingServer: false,
    timeout: 30_000,
  },
});
