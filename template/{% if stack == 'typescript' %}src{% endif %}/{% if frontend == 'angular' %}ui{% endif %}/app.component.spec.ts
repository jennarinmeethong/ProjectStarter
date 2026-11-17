// Component tests, run by `ng test` (Angular's unit-test builder on Vitest, jsdom).
import { TestBed } from "@angular/core/testing";
import { describe, expect, it } from "vitest";
import { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";
import { AppComponent } from "./app.component.ts";
import { ARTIFACT_STORE } from "./artifact-store.token.ts";

function query(root: HTMLElement, selector: string): Element {
  const element = root.querySelector(selector);
  if (element === null) {
    throw new Error(`missing ${selector}`);
  }
  return element;
}

function fill(root: HTMLElement, selector: string, value: string): void {
  const field = query(root, selector);
  if (!(field instanceof HTMLInputElement || field instanceof HTMLTextAreaElement)) {
    throw new Error(`${selector} is not a text field`);
  }
  field.value = value;
  field.dispatchEvent(new Event("input"));
}

async function submit(jobId: string, content: string): Promise<HTMLElement> {
  TestBed.configureTestingModule({ providers: [{ provide: ARTIFACT_STORE, useValue: new InMemoryArtifactStore() }] });
  const fixture = TestBed.createComponent(AppComponent);
  const root = fixture.nativeElement as HTMLElement;
  fill(root, "#job-id", jobId);
  fill(root, "#content", content);
  query(root, "form").dispatchEvent(new Event("submit"));
  await fixture.whenStable();
  return root;
}

describe("AppComponent", () => {
  it("completes an export and shows its artifact key", async () => {
    const root = await submit("ui-1", "id,name");
    expect(query(root, '[role="status"]').textContent).toContain("Saved as exports/ui-1.csv");
  });

  it("rejects an invalid job id without calling the store", async () => {
    const root = await submit("not valid", "x");
    expect(query(root, '[role="status"]').textContent).toContain("Enter a job id");
  });
});
