import { InjectionToken } from "@angular/core";
import type { ArtifactStore } from "../application/complete-export.ts";

/** The port the UI uses; the composition root (main.ts) provides the adapter. */
export const ARTIFACT_STORE = new InjectionToken<ArtifactStore>("ArtifactStore");
