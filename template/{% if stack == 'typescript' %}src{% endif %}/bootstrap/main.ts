import { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";
import { completeExportUseCase } from "../application/complete-export.ts";
import { startExport } from "../domain/export-job.ts";

const store = new InMemoryArtifactStore();
const job = startExport({ kind: "queued", id: "demo" });
const ready = await completeExportUseCase(store, job, "id,name\n1,demo\n");
console.log(`${ready.id} -> ${ready.artifactKey}`);
