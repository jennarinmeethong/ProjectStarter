// Playwright runs black-box API tests against the real server (`npm --prefix e2e test`). No browser is
// needed until there is a UI; add browser projects here when one exists.
import { defineConfig } from "@playwright/test";

const port = 8787;

export default defineConfig({
  testDir: ".",
  testMatch: "*.spec.ts",
  forbidOnly: true,
  retries: 0,
  reporter: [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]],
  use: { baseURL: `http://127.0.0.1:${String(port)}`, trace: "retain-on-failure" },
  webServer: {
    command: "cargo run -q -p bootstrap",
    cwd: "..",
    url: `http://127.0.0.1:${String(port)}/healthz`,
    env: { PORT: String(port), HOST: "127.0.0.1" },
    reuseExistingServer: false,
    timeout: 300_000,
  },
});
