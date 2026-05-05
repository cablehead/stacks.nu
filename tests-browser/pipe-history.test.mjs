// End-to-end browser test for the pipe-history flow.
//
// Drives a real chromium instance against an isolated http-nu instance with
// a fresh store. Run from the repo root:
//
//   node tests-browser/pipe-history.test.mjs
//
// Asserts the regression that the original bug report flagged: when the
// popup is open with a non-newest row highlighted, Mod+Enter should run
// AND populate the input with that row's source -- not the most-recent
// history entry.

import { chromium } from "playwright-core";
import { spawn } from "node:child_process";
import { rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PORT = 4811;
const BASE = `http://127.0.0.1:${PORT}`;
const storeDir = mkdtempSync(join(tmpdir(), "stacks-test-"));
const srv = spawn(
  "http-nu",
  ["--datastar", "--store", storeDir, `:${PORT}`, "./www/serve.nu"],
  { stdio: "ignore" },
);
const cleanup = () => {
  try { srv.kill("SIGTERM"); } catch {}
  try { rmSync(storeDir, { recursive: true, force: true }); } catch {}
};
process.on("exit", cleanup);
process.on("SIGINT", () => { cleanup(); process.exit(130); });

async function waitReady() {
  for (let i = 0; i < 40; i++) {
    try { if ((await fetch(`${BASE}/`)).ok) return; } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("server didn't come up");
}
await waitReady();

const failures = [];
function check(label, ok, detail) {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label}${ok || !detail ? "" : ` -- ${detail}`}`);
  if (!ok) failures.push(label);
}

const browser = await chromium.launch({
  executablePath: "/usr/bin/chromium",
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
const ctx = await browser.newContext();
const page = await ctx.newPage();
page.on("pageerror", (err) => console.log(`  [pageerror] ${err.message}`));

await page.goto(BASE);
await page.waitForSelector("footer[aria-label='Status']", { timeout: 5000 });

// Seed: a stack with one clip
await fetch(`${BASE}/stacks`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ name: "T", sort: "auto" }),
});
await page.goto(BASE);
await page.waitForSelector("aside[aria-label='Stacks'] button", { timeout: 5000 });
const stackId = await page.evaluate(() => {
  const km = JSON.parse(document.querySelector("main")?.dataset?.actions || "{}");
  return (km["stack.delete"] || "").match(/\/stacks\/([a-z0-9]+)/i)?.[1] ?? null;
});
await fetch(`${BASE}/stacks/${stackId}/clips?mime_type=text/plain`, {
  method: "POST",
  body: "hello world",
});
await page.waitForTimeout(300);

const clipId = await page.evaluate(() => {
  const km = JSON.parse(document.querySelector("main")?.dataset?.actions || "{}");
  return (km["clip.delete"] || "").match(/\/clips\/([a-z0-9]+)/i)?.[1] ?? null;
});
check("stack + clip seeded", !!stackId && !!clipId);

// Open pipe mode
await fetch(`${BASE}/_impulse`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ topic: "pipe.open", meta: { clip_id: clipId } }),
});
await page.waitForSelector("#pipe-text", { timeout: 2000 });

const MOD = process.platform === "darwin" ? "Meta" : "Control";

async function runFromInput(text) {
  await page.focus("#pipe-text");
  await page.keyboard.press(`${MOD}+a`);
  await page.keyboard.press("Backspace");
  await page.waitForTimeout(50);
  await page.keyboard.type(text);
  await page.waitForTimeout(200); // past debounce
  await page.keyboard.press(`${MOD}+Enter`);
  await page.waitForTimeout(400); // server processes + render
}

// Run two distinct pipelines to populate history newest-first
await runFromInput("str upcase");
await runFromInput("str upcase | lines | to json -r");

// Clear input so popup shows full history without filtering it down
await page.focus("#pipe-text");
await page.keyboard.press(`${MOD}+a`);
await page.keyboard.press("Backspace");
await page.waitForTimeout(200);

// Open popup; clear-input has already auto-opened it via pipe.text frame.
// Press ArrowUp to navigate from cursor=0 (newest) to cursor=1 (older).
await page.keyboard.press("ArrowUp");
await page.waitForSelector(".pipe-history-row", { timeout: 3000 });
await page.waitForTimeout(250);
await page.keyboard.press("ArrowUp");
await page.waitForTimeout(250);

const highlighted = await page.evaluate(() =>
  document.querySelector(".pipe-history-row.is-current")?.dataset?.historySource ?? null
);
check(
  "highlighted row is the older entry",
  highlighted === "str upcase",
  `got ${JSON.stringify(highlighted)}`,
);

// Mod+Enter should accept-and-run the highlighted row
await page.keyboard.press(`${MOD}+Enter`);
await page.waitForTimeout(500);

const inputAfter = await page.inputValue("#pipe-text");
check(
  "input populates with the highlighted source (regression: not the most-recent)",
  inputAfter === "str upcase",
  `got ${JSON.stringify(inputAfter)}`,
);

await browser.close();
cleanup();
console.log(`\n${failures.length === 0 ? "PASS" : `FAIL (${failures.length})`}`);
process.exit(failures.length === 0 ? 0 : 1);
