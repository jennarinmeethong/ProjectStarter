// UI adapter (driving side): turns user input into a use case call. Domain and application never import
// Angular (ADR 0005); the store comes from the ARTIFACT_STORE token provided in main.ts.
import { ChangeDetectionStrategy, Component, inject, signal } from "@angular/core";
import { completeExportUseCase } from "../application/complete-export.ts";
import { startExport } from "../domain/export-job.ts";
import { ARTIFACT_STORE } from "./artifact-store.token.ts";

const JOB_ID = /^[A-Za-z0-9_-]{1,64}$/;

@Component({
  selector: "app-root",
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <main>
      <h1>Complete an export</h1>
      <form novalidate (submit)="submit($event)">
        <label for="job-id">Job id</label>
        <input id="job-id" name="jobId" autocomplete="off" [value]="jobId()" (input)="jobId.set(value($event))" />
        <label for="content">Content</label>
        <textarea id="content" name="content" rows="4" [value]="content()" (input)="content.set(value($event))"></textarea>
        <button type="submit" [disabled]="saving()">Complete export</button>
      </form>
      <p role="status">{{ status() }}</p>
    </main>
  `,
})
export class AppComponent {
  readonly #store = inject(ARTIFACT_STORE);
  protected readonly jobId = signal("");
  protected readonly content = signal("");
  protected readonly status = signal("");
  protected readonly saving = signal(false);

  protected value(event: Event): string {
    return (event.target as HTMLInputElement | HTMLTextAreaElement).value;
  }

  protected async submit(event: Event): Promise<void> {
    event.preventDefault();
    if (!JOB_ID.test(this.jobId()) || this.content().length === 0) {
      this.status.set("Enter a job id (letters, digits, - or _) and some content.");
      return;
    }
    this.saving.set(true);
    this.status.set("Saving…");
    try {
      const ready = await completeExportUseCase(this.#store, startExport({ kind: "queued", id: this.jobId() }), this.content());
      this.status.set(`Saved as ${ready.artifactKey}`);
    } catch {
      this.status.set("The export could not be saved.");
    } finally {
      this.saving.set(false);
    }
  }
}
