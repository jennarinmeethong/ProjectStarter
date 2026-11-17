import { completeExport, type ReadyExport, type RunningExport } from "../domain/export-job.ts";

/** Port: defined here, implemented in adapters, wired in bootstrap. */
export interface ArtifactStore {
  save(jobId: string, content: string): Promise<string>;
}

export async function completeExportUseCase(
  store: ArtifactStore,
  job: RunningExport,
  content: string,
): Promise<ReadyExport> {
  const key = await store.save(job.id, content);
  return completeExport(job, key);
}
