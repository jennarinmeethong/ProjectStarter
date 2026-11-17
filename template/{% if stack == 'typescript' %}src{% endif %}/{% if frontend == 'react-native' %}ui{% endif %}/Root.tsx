// Composition root for web and native: the only UI file that picks adapters (ADR 0001, ADR 0005).
// The web build stores artifacts in Web Storage; native builds fall back to memory until a native storage
// adapter (for example on top of expo-sqlite) is added behind the same port.
import { useState, type JSX } from "react";
import { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";
import { LocalStorageArtifactStore } from "../adapters/local-storage-artifact-store.ts";
import type { ArtifactStore } from "../application/complete-export.ts";
import { App } from "./App.tsx";

function deviceStore(): ArtifactStore {
  return typeof window !== "undefined" && "localStorage" in window
    ? new LocalStorageArtifactStore(window.localStorage)
    : new InMemoryArtifactStore();
}

export function Root(): JSX.Element {
  const [store] = useState(deviceStore);
  return <App store={store} />;
}
