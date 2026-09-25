import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import crypto from 'node:crypto';

// Actual native captures remain untouched; HTML/CSS supplies the surrounding
// editable headline/layout. No synthetic app screens or personal library media.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node promo/app-store/render-screenshots.mjs CAPTURES OUTPUT
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const input = path.resolve(process.argv[2] ?? '');
const output = path.resolve(process.argv[3] ?? '');
if (!process.argv[2] || !process.argv[3] || input === output) throw new Error('Use separate CAPTURES and OUTPUT directories');
const config = JSON.parse(await fs.readFile(path.join(root, 'promo/app-store/screenshots.json'), 'utf8'));
if(process.argv[4]) config.screens=config.screens.filter(s=>process.argv[4].split(',').includes(s.id));
const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const { chromium } = await import(moduleName.startsWith('/') ? pathToFileURL(moduleName).href : moduleName);
const escape = value => value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const data = async file => `data:image/png;base64,${(await fs.readFile(file)).toString('base64')}`;
const logo = await data(path.join(root, 'ios/CodecMobile/App/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png'));
const css = `
*{box-sizing:border-box}html,body{margin:0;background:#101312;color:#eef2ed;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
.poster{position:relative;width:1320px;height:2868px;overflow:hidden;background:#101312}
.brand{position:absolute;top:60px;left:90px;display:flex;gap:16px;align-items:center;font-size:32px;letter-spacing:-.6px;font-weight:650}.brand img{width:50px;height:50px;border-radius:13px;outline:1px solid #ffffff24}
h1{position:absolute;top:155px;left:90px;right:90px;margin:0;font-size:90px;line-height:1.1;letter-spacing:-3px;font-weight:720}h1 span{display:block}
p{position:absolute;left:94px;right:90px;top:280px;margin:0;font-size:32px;line-height:1.4;letter-spacing:-.3px;color:#c7cfca}
.device{position:absolute;width:1100px;left:110px;top:364px;padding:9px;border-radius:127px;background:#202624;box-shadow:0 0 0 2px #abb4ae3d,0 20px 60px #0006}
.device img{display:block;width:100%;height:auto;border-radius:118px;outline:1px solid #ffffff12}
.ipad{width:2064px;height:2752px}.ipad .brand{top:64px;left:112px;font-size:36px}.ipad .brand img{width:60px;height:60px}
.ipad h1{top:169px;left:110px;right:110px;font-size:108px;letter-spacing:-3px}.ipad p{top:318px;left:116px;right:110px;font-size:38px}
.ipad .device{width:1680px;left:192px;top:432px;padding:15px;border-radius:63px}.ipad .device img{border-radius:48px}
`;
const browser = await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_BROWSER_PATH?{executablePath:process.env.PLAYWRIGHT_BROWSER_PATH}:{})});
const results=[];
await fs.mkdir(output,{recursive:true});
try {
 for(const [family,width,height] of [['iphone-6.9',1320,2868],['ipad-13',2064,2752]]){
  const page=await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
  const folder=path.join(output,family);await fs.mkdir(folder,{recursive:true});
  for(const screen of config.screens){
   const file=path.join(input,family,screen.source);
   const bytes=await fs.readFile(file);
   const html=`<!doctype html><html lang="en"><meta charset="utf-8"><title>Codec — ${escape(screen.label)}</title><style>${css}</style><main class="poster ${family==='ipad-13'?'ipad':''}"><div class="brand"><img src="${logo}" alt="">Codec</div><h1>${screen.headline.map(s=>`<span>${escape(s)}</span>`).join('')}</h1><p>${escape(screen.caption)}</p><div class="device"><img src="${await data(file)}" alt="Actual Codec ${escape(screen.label)} screen"></div></main></html>`;
   await page.setContent(html);await page.evaluate(()=>Promise.all([...document.images].map(i=>i.decode())));await page.evaluate(()=>document.fonts.ready);
   const errors=await page.evaluate(()=>{
    const box=s=>document.querySelector(s).getBoundingClientRect();const brand=box('.brand'),heading=box('h1'),caption=box('p'),device=box('.device');
    const textOverflow=['h1','p'].some(s=>{const e=document.querySelector(s);return e.scrollWidth>e.clientWidth});
    return {brandOverlapsHeading:brand.bottom>heading.top,headingOverlapsCaption:heading.bottom>caption.top,captionOverlapsDevice:caption.bottom>device.top,textOverflow,deviceClipped:device.bottom>innerHeight-80||device.left<0||device.right>innerWidth,imageWidth:document.querySelector('.device img').naturalWidth,imageHeight:document.querySelector('.device img').naturalHeight,headingLines:document.querySelectorAll('h1 span').length,deviceBottom:device.bottom,deviceTop:device.top};
   });
   if(errors.brandOverlapsHeading||errors.headingOverlapsCaption||errors.captionOverlapsDevice||errors.textOverflow||errors.deviceClipped) throw new Error(`Poster layout failed ${family}/${screen.id}: ${JSON.stringify(errors)}`);
   if(errors.imageWidth!==width||errors.imageHeight!==height)throw new Error(`Unexpected native capture size ${file}`);
   const png=path.join(folder,screen.id+'.png');
   await page.screenshot({path:png,omitBackground:false});
   await fs.writeFile(path.join(folder,screen.id+'.html'),html);
   results.push({family,id:screen.id,width,height,headline:screen.headline.join(' '),caption:screen.caption,source:file,source_sha256:crypto.createHash('sha256').update(bytes).digest('hex'),output:png,output_sha256:crypto.createHash('sha256').update(await fs.readFile(png)).digest('hex'),layout_checks:errors,copy_draft:true});
  }
  await page.close();
 }
 const gallery=`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Codec — App Store screenshots</title><style>body{margin:0;padding:40px;background:#101312;color:#eef2ed;font:16px/1.5 -apple-system,sans-serif}h1{font-size:32px;margin:0}h2{font-size:22px;margin:30px 0 16px}p{color:#aab5ae;max-width:70ch}section{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:18px}img{display:block;width:100%;height:auto;border:1px solid #ffffff20;border-radius:12px}a{color:inherit}figure{margin:0}figcaption{padding-top:12px;font-size:14px}@media(max-width:1000px){section{grid-template-columns:repeat(3,1fr)}}@media(max-width:560px){body{padding:20px}section{grid-template-columns:repeat(2,1fr);gap:12px}}</style><h1>Codec · App Store screenshots</h1><p>Actual native captures in Graphite. Select a screenshot for the full export.</p>${[['iphone-6.9','iPhone · 1320 × 2868'],['ipad-13','iPad · 2064 × 2752']].map(([family,label])=>`<h2>${label}</h2><section>${results.filter(r=>r.family===family).map((r,i)=>`<figure><a href="${family}/${r.id}.png"><img src="${family}/${r.id}.png" alt="${escape(r.headline)}"></a><figcaption>${i+1}. ${escape(r.headline)}</figcaption></figure>`).join('')}</section>`).join('')}</html>`;
 await fs.writeFile(path.join(output,'index.html'),gallery);
 const page=await browser.newPage({viewport:{width:1800,height:1000},deviceScaleFactor:1});
 await page.goto(pathToFileURL(path.join(output,'index.html')).href);await page.evaluate(()=>Promise.all([...document.images].map(i=>i.decode())));
 await page.screenshot({path:path.join(output,'contact-sheet.png'),fullPage:true});
 await page.close();
 await fs.writeFile(path.join(output,'screenshots-receipt.json'),JSON.stringify({locale:config.locale,rendering:'Unaltered native app capture inside a plain factual HTML/CSS caption layout',results},null,2)+'\n');
 console.log(`Rendered ${results.length} native screenshot layouts in ${output}`);
}finally{await browser.close()}
