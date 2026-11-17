import { describeArtifactStoreContract } from "../../tests/contracts/artifact-store.ts";
import { InMemoryArtifactStore } from "./in-memory-artifact-store.ts";

const store = new InMemoryArtifactStore();

describeArtifactStoreContract("InMemoryArtifactStore", () => ({
  store,
  read: (key) => Promise.resolve(store.read(key)),
}));
