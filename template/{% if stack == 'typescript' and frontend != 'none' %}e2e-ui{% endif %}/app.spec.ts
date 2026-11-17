// User flows in a real browser, plus an axe accessibility scan (WCAG 2.1 AA) of every screen.
import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

test("completes an export from the form", async ({ page }) => {
  await page.goto("/");
  await page.getByLabel("Job id").fill("ui-1");
  await page.getByLabel("Content").fill("id,name");
  await page.getByRole("button", { name: "Complete export" }).click();
  await expect(page.getByRole("status")).toHaveText("Saved as exports/ui-1.csv");
});

test("explains an invalid job id", async ({ page }) => {
  await page.goto("/");
  await page.getByLabel("Job id").fill("not valid");
  await page.getByLabel("Content").fill("x");
  await page.getByRole("button", { name: "Complete export" }).click();
  await expect(page.getByRole("status")).toContainText("Enter a job id");
});

test("has no accessibility violations", async ({ page }) => {
  await page.goto("/");
  const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"]).analyze();
  expect(results.violations).toEqual([]);
});
