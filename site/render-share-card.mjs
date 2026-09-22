// Build-time image export only. The public site does not load this script or template.
import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto(new URL('./share-card.html', import.meta.url).href);
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all([...document.images].map(image => image.decode()));
  });
  const card = fileURLToPath(new URL('./assets/codec-share.jpg', import.meta.url));
  await page.screenshot({ path: card, type: 'jpeg', quality: 90 });
  const icon = await readFile(new URL('../ios/CodecMobile/App/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png', import.meta.url));
  await page.setViewportSize({ width: 180, height: 180 });
  await page.setContent(`<style>body{margin:0;background:#101312}img{display:block;width:180px;height:180px}</style><img src="data:image/png;base64,${icon.toString('base64')}" alt="">`);
  await page.locator('img').evaluate(image => image.decode());
  await page.screenshot({ path: fileURLToPath(new URL('./assets/apple-touch-icon.png', import.meta.url)), type: 'png' });
  console.log(JSON.stringify({ card: 'assets/codec-share.jpg', width: 1200, height: 630, bytes: (await stat(card)).size, icon: 'assets/apple-touch-icon.png' }));
} finally {
  await browser.close();
}
