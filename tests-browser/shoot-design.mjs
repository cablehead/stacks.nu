#!/usr/bin/env node
// Screenshot http://<base>/design (full page, all 11 mode tiles rendered)
// and POST the PNG as a clip into the currently-selected stack.
//
//   node scripts/shoot-design.mjs                  # uses BASE=http://127.0.0.1:4777
//   BASE=http://other:port node scripts/shoot-design.mjs
//
// Requires: tests-browser/node_modules/playwright-core (npm install once),
// /usr/bin/chromium, a running http-nu server.

import { chromium } from "playwright-core";

const BASE = process.env.BASE || "http://127.0.0.1:4777";
const PNG = "/tmp/stacks-design.png";

const browser = await chromium.launch({
  executablePath: "/usr/bin/chromium",
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
// Tall viewport so all iframes are in-viewport at load (no lazy loading).
const ctx = await browser.newContext({ viewport: { width: 1280, height: 5500 } });
const page = await ctx.newPage();
await page.goto(`${BASE}/design`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(1000);

// Wait until each iframe's body actually has content.
const titles = await page.$$eval("iframe", (els) => els.map((e) => e.title));
for (const t of titles) {
  for (let i = 0; i < 30; i++) {
    const ok = await page.evaluate((tt) => {
      const el = document.querySelector(`iframe[title="${tt}"]`);
      return el?.contentDocument?.body?.firstElementChild != null;
    }, t);
    if (ok) break;
    await page.waitForTimeout(100);
  }
}
await page.waitForTimeout(500);
await page.screenshot({ path: PNG, fullPage: true });
await browser.close();
console.log(`shot: ${PNG} (${titles.length} tiles)`);

// Find the live store's currently-selected stack via /api/state.
const stateResp = await fetch(`${BASE}/api/state`);
if (!stateResp.ok) throw new Error(`/api/state -> ${stateResp.status}`);
const state = await stateResp.json();
const stackId = state.selectedStackId || state.stackIds?.[0];
if (!stackId) throw new Error("no stack to post into; create one first");
console.log(`stack: ${stackId}`);

// POST the PNG as a clip body.
const png = await import("node:fs").then((fs) => fs.readFileSync(PNG));
const post = await fetch(`${BASE}/stacks/${stackId}/clips?mime_type=image/png`, {
  method: "POST",
  headers: { "content-type": "image/png" },
  body: png,
});
const json = await post.json();
console.log(`clip: ${json.id} (${json.hash})`);
