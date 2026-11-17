// Browser composition root: the only UI file that picks adapters (ADR 0001, ADR 0005).
import { createApp } from "vue";
import { LocalStorageArtifactStore } from "../adapters/local-storage-artifact-store.ts";
import App from "./App.vue";

createApp(App, { store: new LocalStorageArtifactStore(window.localStorage) }).mount("#root");
