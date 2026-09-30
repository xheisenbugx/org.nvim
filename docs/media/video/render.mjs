// Renders composition.html frame by frame with headless Chrome.
//   node render.mjs                 every frame -> build/render/00001.jpg…
//   node render.mjs --stills 3,12   a PNG per time (seconds) -> build/stills/
// PAGE=extensions/composition.html renders another video; build/ is then
// next to that page.
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import os from "node:os";

const FPS = 30;
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const page = path.resolve(process.env.PAGE || path.join(path.dirname(fileURLToPath(import.meta.url)), "composition.html"));
process.chdir(path.dirname(page));
const url = pathToFileURL(page).href;
const args = process.argv.slice(2);
const stills = args[0] === "--stills" ? args[1].split(",").map(Number) : null;

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: ["--allow-file-access-from-files", "--force-color-profile=srgb", "--hide-scrollbars", "--font-render-hinting=none"],
});
async function newPage() {
  const page = await browser.newPage();
  await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });
  await page.goto(url + "?t=0", { waitUntil: "load" });
  return page;
}

if (stills) {
  mkdirSync("build/stills", { recursive: true });
  const page = await newPage();
  for (const t of stills) {
    await page.evaluate((t) => window.seek(t), t);
    await page.screenshot({ path: `build/stills/${t.toFixed(2)}.png` });
  }
} else {
  mkdirSync("build/render", { recursive: true });
  const probe = await newPage();
  const total = Math.round((await probe.evaluate(() => window.DURATION)) * FPS);
  await probe.close();
  const workers = Math.max(2, Math.min(8, os.cpus().length - 2));
  let next = 0, done = 0;
  const started = Date.now();
  await Promise.all(Array.from({ length: workers }, async () => {
    const page = await newPage();
    while (next < total) {
      const f = next++;
      await page.evaluate((t) => window.seek(t), f / FPS);
      await page.screenshot({ path: `build/render/${String(f + 1).padStart(5, "0")}.jpg`, type: "jpeg", quality: 95 });
      if (++done % 150 === 0) console.log(`${done}/${total} frames, ${((Date.now() - started) / 1000).toFixed(0)}s`);
    }
  }));
  console.log(`rendered ${total} frames`);
}
await browser.close();
