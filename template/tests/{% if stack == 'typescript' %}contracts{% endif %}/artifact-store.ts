// Contract every ArtifactStore adapter must satisfy (Liskov: adapters are interchangeable behind the port).
// The in-memory adapter runs it in the unit suite; datastore adapters run it against real containers.
import { describe, expect, it } from "vitest";
import type { ArtifactStore } from "../../src/application/complete-export.ts";

export interface ArtifactStoreUnderTest {
  readonly store: ArtifactStore;
  readonly read: (key: string) => Promise<string | undefined>;
}

export function describeArtifactStoreContract(name: string, subject: () => ArtifactStoreUnderTest): void {
  describe(`${name} satisfies the ArtifactStore contract`, () => {
    it("returns a key that reads back the saved content", async () => {
      const { store, read } = subject();
      const key = await store.save("contract-1", "id\n1\n");
      expect(await read(key)).toBe("id\n1\n");
    });

    it("is idempotent per job: saving again keeps the key and stores the latest content", async () => {
      const { store, read } = subject();
      const first = await store.save("contract-2", "old");
      const second = await store.save("contract-2", "new");
      expect(second).toBe(first);
      expect(await read(second)).toBe("new");
    });

    it("keeps different jobs apart", async () => {
      const { store, read } = subject();
      const a = await store.save("contract-3a", "a");
      const b = await store.save("contract-3b", "b");
      expect(a).not.toBe(b);
      expect(await read(a)).toBe("a");
      expect(await read(b)).toBe("b");
    });
  });
}
