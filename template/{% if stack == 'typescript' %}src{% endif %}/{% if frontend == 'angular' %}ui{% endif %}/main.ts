// Browser composition root: the only UI file that picks adapters (ADR 0001, ADR 0005).
import { provideZonelessChangeDetection } from "@angular/core";
import { bootstrapApplication } from "@angular/platform-browser";
import { LocalStorageArtifactStore } from "../adapters/local-storage-artifact-store.ts";
import { AppComponent } from "./app.component.ts";
import { ARTIFACT_STORE } from "./artifact-store.token.ts";

bootstrapApplication(AppComponent, {
  providers: [
    provideZonelessChangeDetection(),
    { provide: ARTIFACT_STORE, useFactory: () => new LocalStorageArtifactStore(window.localStorage) },
  ],
}).catch((error: unknown) => {
  throw error;
});
