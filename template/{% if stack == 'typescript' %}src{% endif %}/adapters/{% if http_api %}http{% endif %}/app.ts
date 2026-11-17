// HTTP adapter (driving side): decode and validate requests here, call the use case, map results to HTTP.
// Domain and application never see HTTP types (ADR 0001). Security baseline: docs/security/owasp.md.
import { Hono, type Context } from "hono";
import { secureHeaders } from "hono/secure-headers";
import { completeExportUseCase, type ArtifactStore } from "../../application/complete-export.ts";
import { startExport } from "../../domain/export-job.ts";

const JOB_ID = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_CONTENT_LENGTH = 1_000_000;

/** RFC 9457 problem details. Never includes stack traces or internal messages. */
function problem(c: Context, status: 400 | 404 | 500, title: string): Response {
  return c.body(JSON.stringify({ type: "about:blank", title, status }), status, {
    "Content-Type": "application/problem+json",
  });
}

/** Returns the content when the body is exactly `{"content": "<non-empty string>"}`, otherwise undefined. */
function decodeContent(body: unknown): string | undefined {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return undefined;
  }
  const content: unknown = "content" in body ? body.content : undefined;
  const valid =
    Object.keys(body).length === 1 && typeof content === "string" && content.length > 0 && content.length <= MAX_CONTENT_LENGTH;
  return valid ? content : undefined;
}

export function createHttpApp(store: ArtifactStore): Hono {
  const app = new Hono();

  app.use(
    secureHeaders({
      contentSecurityPolicy: { defaultSrc: ["'none'"], frameAncestors: ["'none'"] },
      xFrameOptions: "DENY",
      referrerPolicy: "no-referrer",
    }),
  );
  app.use(async (c, next) => {
    await next();
    c.header("Cache-Control", "no-store");
  });

  app.get("/healthz", (c) => c.json({ status: "ok" }));

  app.post("/exports/:id/complete", async (c) => {
    const id = c.req.param("id");
    if (!JOB_ID.test(id)) {
      return problem(c, 400, "Invalid job id");
    }
    const body: unknown = await c.req.json().catch(() => undefined);
    const content = decodeContent(body);
    if (content === undefined) {
      return problem(c, 400, 'Body must be {"content": "<non-empty string>"}');
    }
    const ready = await completeExportUseCase(store, startExport({ kind: "queued", id }), content);
    return c.json({ id: ready.id, artifactKey: ready.artifactKey }, 201);
  });

  app.notFound((c) => problem(c, 404, "Not found"));
  app.onError((error, c) => {
    console.error("Unhandled error", error.name);
    return problem(c, 500, "Internal error");
  });

  return app;
}
