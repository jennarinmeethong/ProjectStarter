// Browser composition root: the only UI file that picks adapters (ADR 0001, ADR 0005).
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { LocalStorageArtifactStore } from "../adapters/local-storage-artifact-store.ts";
import { App } from "./App.tsx";

const root = document.getElementById("root");
if (root === null) {
  throw new Error("index.html must contain an element with id 'root'");
}
createRoot(root).render(
  <StrictMode>
    <App store={new LocalStorageArtifactStore(window.localStorage)} />
  </StrictMode>,
);
