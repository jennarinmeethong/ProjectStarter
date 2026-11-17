// Black-box API tests: the server's real HTTP behaviour, including validation and security headers.
import { expect, test } from "@playwright/test";

test("health check answers ok", async ({ request }) => {
  const response = await request.get("/healthz");
  expect(response.status()).toBe(200);
  expect(await response.json()).toEqual({ status: "ok" });
});

test("completes an export and returns its artifact key", async ({ request }) => {
  const response = await request.post("/exports/e2e-1/complete", { data: { content: "id\n1\n" } });
  expect(response.status()).toBe(201);
  expect(await response.json()).toEqual({ id: "e2e-1", artifactKey: "exports/e2e-1.csv" });
});

test("rejects an invalid job id with problem details", async ({ request }) => {
  const response = await request.post("/exports/not%20valid/complete", { data: { content: "x" } });
  expect(response.status()).toBe(400);
  expect(response.headers()["content-type"]).toContain("application/problem+json");
});

test("rejects a body without content", async ({ request }) => {
  const response = await request.post("/exports/e2e-2/complete", { data: { other: "x" } });
  expect(response.status()).toBe(400);
});

test("answers unknown routes with 404 problem details", async ({ request }) => {
  const response = await request.get("/does-not-exist");
  expect(response.status()).toBe(404);
  expect(response.headers()["content-type"]).toContain("application/problem+json");
});

test("sends the security headers on every response", async ({ request }) => {
  for (const path of ["/healthz", "/does-not-exist"]) {
    const headers = (await request.get(path)).headers();
    expect(headers["x-content-type-options"]).toBe("nosniff");
    expect(headers["x-frame-options"]).toBe("DENY");
    expect(headers["content-security-policy"]).toContain("default-src 'none'");
    expect(headers["cache-control"]).toBe("no-store");
    expect(headers["x-powered-by"]).toBeUndefined();
  }
});
