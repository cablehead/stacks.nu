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
// Wide enough for the design grid (minmax(40rem, 1fr)) to lay tiles 2-up.
// Tall enough that all iframes are in-viewport at load (no lazy loading).
const W = parseInt(process.env.W || "1500", 10);
const H = parseInt(process.env.H || "3500", 10);
const ctx = await browser.newContext({ viewport: { width: W, height: H } });
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
console.log(`shot: ${PNG} (${titles.length} tiles, ${W}x${H} viewport)`);

// Optional resize: TARGET_W shrinks the image to that width before posting.
// Useful for getting a 2-up render at a comfortable in-app preview size --
// shoot wide (so the grid lays out 2-up), resize down for storage.
const targetW = parseInt(process.env.TARGET_W || "0", 10);
let outPath = PNG;
if (targetW > 0 && targetW < W) {
  const sharp = (await import("sharp")).default;
  outPath = "/tmp/stacks-design-resized.png";
  await sharp(PNG).resize({ width: targetW }).toFile(outPath);
  console.log(`resized: ${outPath} (width ${targetW})`);
}

// Find the live store's currently-selected stack via /api/state.
const stateResp = await fetch(`${BASE}/api/state`);
if (!stateResp.ok) throw new Error(`/api/state -> ${stateResp.status}`);
const state = await stateResp.json();
const stackId = state.selectedStackId || state.stackIds?.[0];
if (!stackId) throw new Error("no stack to post into; create one first");
console.log(`stack: ${stackId}`);

// POST the (possibly resized) PNG as a clip body.
const png = await import("node:fs").then((fs) => fs.readFileSync(outPath));
const post = await fetch(`${BASE}/stacks/${stackId}/clips?mime_type=image/png`, {
  method: "POST",
  headers: { "content-type": "image/png" },
  body: png,
});
const json = await post.json();
console.log(`clip: ${json.id} (${json.hash})`);
