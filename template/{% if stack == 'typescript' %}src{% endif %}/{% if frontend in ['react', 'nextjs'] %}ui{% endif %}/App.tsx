// UI adapter (driving side): turns user input into a use case call. Domain and application never import
// React (ADR 0005); the store is injected by the composition root in main.tsx.
import { useId, useState, type JSX, type SyntheticEvent } from "react";
import { completeExportUseCase, type ArtifactStore } from "../application/complete-export.ts";
import { startExport } from "../domain/export-job.ts";

const JOB_ID = /^[A-Za-z0-9_-]{1,64}$/;

type Status =
  | { readonly kind: "idle" }
  | { readonly kind: "saving" }
  | { readonly kind: "done"; readonly artifactKey: string }
  | { readonly kind: "error"; readonly message: string };

function statusText(status: Status): string {
  switch (status.kind) {
    case "idle":
      return "";
    case "saving":
      return "Saving…";
    case "done":
      return `Saved as ${status.artifactKey}`;
    case "error":
      return status.message;
  }
}

export function App({ store }: { readonly store: ArtifactStore }): JSX.Element {
  const [jobId, setJobId] = useState("");
  const [content, setContent] = useState("");
  const [status, setStatus] = useState<Status>({ kind: "idle" });
  const jobInputId = useId();
  const contentInputId = useId();

  async function submit(event: SyntheticEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    if (!JOB_ID.test(jobId) || content.length === 0) {
      setStatus({ kind: "error", message: "Enter a job id (letters, digits, - or _) and some content." });
      return;
    }
    setStatus({ kind: "saving" });
    try {
      const ready = await completeExportUseCase(store, startExport({ kind: "queued", id: jobId }), content);
      setStatus({ kind: "done", artifactKey: ready.artifactKey });
    } catch {
      setStatus({ kind: "error", message: "The export could not be saved." });
    }
  }

  return (
    <main>
      <h1>Complete an export</h1>
      <form onSubmit={(event) => void submit(event)} noValidate>
        <label htmlFor={jobInputId}>Job id</label>
        <input id={jobInputId} name="jobId" value={jobId} onChange={(e) => {
            setJobId(e.target.value);
          }} autoComplete="off" />
        <label htmlFor={contentInputId}>Content</label>
        <textarea id={contentInputId} name="content" value={content} onChange={(e) => {
            setContent(e.target.value);
          }} rows={4} />
        <button type="submit" disabled={status.kind === "saving"}>
          Complete export
        </button>
      </form>
      <p role="status">{statusText(status)}</p>
    </main>
  );
}
