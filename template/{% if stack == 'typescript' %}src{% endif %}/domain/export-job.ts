// Illegal states are unrepresentable: only a running job can complete, and `ready` always has an artifact key.
export type ExportJob =
  | { readonly kind: "queued"; readonly id: string }
  | { readonly kind: "running"; readonly id: string }
  | { readonly kind: "ready"; readonly id: string; readonly artifactKey: string }
  | { readonly kind: "failed"; readonly id: string; readonly reason: string };

export type QueuedExport = Extract<ExportJob, { kind: "queued" }>;
export type RunningExport = Extract<ExportJob, { kind: "running" }>;
export type ReadyExport = Extract<ExportJob, { kind: "ready" }>;

export function startExport(job: QueuedExport): RunningExport {
  return { kind: "running", id: job.id };
}

export function completeExport(job: RunningExport, artifactKey: string): ReadyExport {
  if (artifactKey.trim().length === 0) {
    throw new Error("Export completion requires an artifact key");
  }
  return { kind: "ready", id: job.id, artifactKey };
}
