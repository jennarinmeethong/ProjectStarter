// @vitest-environment jsdom
import { flushPromises, mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";
import App from "./App.vue";

describe("App", () => {
  it("completes an export and shows its artifact key", async () => {
    const wrapper = mount(App, { props: { store: new InMemoryArtifactStore() } });

    await wrapper.get('input[name="jobId"]').setValue("ui-1");
    await wrapper.get('textarea[name="content"]').setValue("id,name");
    await wrapper.get("form").trigger("submit");
    await flushPromises();

    expect(wrapper.get('[role="status"]').text()).toBe("Saved as exports/ui-1.csv");
  });

  it("rejects an invalid job id without calling the store", async () => {
    const wrapper = mount(App, { props: { store: new InMemoryArtifactStore() } });

    await wrapper.get('input[name="jobId"]').setValue("not valid");
    await wrapper.get('textarea[name="content"]').setValue("x");
    await wrapper.get("form").trigger("submit");
    await flushPromises();

    expect(wrapper.get('[role="status"]').text()).toContain("Enter a job id");
  });
});
