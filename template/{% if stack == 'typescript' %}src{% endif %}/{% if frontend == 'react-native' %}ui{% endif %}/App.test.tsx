// @vitest-environment jsdom
// Runs the React Native screen through react-native-web (vitest.config.ts aliases react-native).
import { cleanup, render, screen } from "@testing-library/react";
import { userEvent } from "@testing-library/user-event";
import { afterEach, describe, expect, it } from "vitest";
import { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";
import { App } from "./App.tsx";

afterEach(cleanup);

describe("App", () => {
  it("completes an export and shows its artifact key", async () => {
    const user = userEvent.setup();
    render(<App store={new InMemoryArtifactStore()} />);

    await user.type(screen.getByLabelText("Job id"), "ui-1");
    await user.type(screen.getByLabelText("Content"), "id,name");
    await user.click(screen.getByRole("button", { name: "Complete export" }));

    expect(await screen.findByText("Saved as exports/ui-1.csv")).toBeDefined();
  });

  it("rejects an invalid job id without calling the store", async () => {
    const user = userEvent.setup();
    render(<App store={new InMemoryArtifactStore()} />);

    await user.type(screen.getByLabelText("Job id"), "not valid");
    await user.type(screen.getByLabelText("Content"), "x");
    await user.click(screen.getByRole("button", { name: "Complete export" }));

    expect(screen.getByRole("status").textContent).toContain("Enter a job id");
  });
});
