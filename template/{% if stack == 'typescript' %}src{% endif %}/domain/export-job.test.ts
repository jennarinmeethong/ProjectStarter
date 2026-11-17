import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { completeExport, startExport } from "./export-job.ts";

describe("export job", () => {
  it("completes a running job with its artifact key", () => {
    const running = startExport({ kind: "queued", id: "job-1" });
    expect(completeExport(running, "exports/job-1.csv")).toEqual({
      kind: "ready",
      id: "job-1",
      artifactKey: "exports/job-1.csv",
    });
  });

  it("rejects a blank artifact key", () => {
    expect(() => completeExport({ kind: "running", id: "job-1" }, "  ")).toThrow();
  });

  it("keeps the job id and key for any non-blank key (property)", () => {
    fc.assert(
      fc.property(
        fc.string(),
        fc.string().filter((k) => k.trim().length > 0),
        (id, key) => {
          const ready = completeExport({ kind: "running", id }, key);
          expect(ready.id).toBe(id);
          expect(ready.artifactKey).toBe(key);
        },
      ),
    );
  });
});
