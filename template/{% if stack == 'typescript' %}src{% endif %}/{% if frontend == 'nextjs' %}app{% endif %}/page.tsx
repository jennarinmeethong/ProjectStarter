"use client";
// Browser composition root: the only UI file that picks adapters (ADR 0001, ADR 0005). The store is created on
// the client, so server rendering never touches Web Storage.
import { useState, type JSX } from "react";
import { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";
import { LocalStorageArtifactStore } from "../adapters/local-storage-artifact-store.ts";
import type { ArtifactStore } from "../application/complete-export.ts";
import { App } from "../ui/App.tsx";

function browserStore(): ArtifactStore {
  return typeof window === "undefined" ? new InMemoryArtifactStore() : new LocalStorageArtifactStore(window.localStorage);
}

export default function Page(): JSX.Element {
  const [store] = useState(browserStore);
  return <App store={store} />;
}
