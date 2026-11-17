import type { ArtifactStore } from "../application/complete-export.ts";

export class InMemoryArtifactStore implements ArtifactStore {
  readonly #files = new Map<string, string>();

  save(jobId: string, content: string): Promise<string> {
    const key = `exports/${jobId}.csv`;
    this.#files.set(key, content);
    return Promise.resolve(key);
  }

  read(key: string): string | undefined {
    return this.#files.get(key);
  }
}
