#!/usr/bin/env node
// Real WebKit motion, modal focus, and pointer/keyboard focus regression.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/mobile-motion-regression.mjs --build-dir build
// No account, existing library, media server, or downloaded fixtures are used.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1]);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.resolve(args.get('output-dir') ?? process.env.CODEC_TEST_OUTPUT ?? path.join(os.tmpdir(), 'codec-mobile-motion-regression'));
const moduleName = args.get('playwright-module') ?? process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const moduleURL = moduleName.startsWith('/') || moduleName.startsWith('.') ? pathToFileURL(path.resolve(moduleName)).href : moduleName;
let browserType;
const browserName = args.get('browser') ?? 'webkit';
if (!['chromium','webkit'].includes(browserName)) throw new Error('--browser must be chromium or webkit');
try { browserType = (await import(moduleURL))[browserName]; }
catch { throw new Error('Playwright is required. Set PLAYWRIGHT_MODULE to an installed playwright/index.mjs, or install playwright in your test environment. See scripts/mobile-regression.md.'); }

await fs.mkdir(output, { recursive: true });
let server;
let baseURL = args.get('base-url') ?? process.env.CODEC_TEST_URL;
if (!baseURL) {
  const build = path.resolve(args.get('build-dir') ?? path.join(repo, 'build'));
  await fs.access(path.join(build, 'index.html')).catch(() => { throw new Error('Missing web build. Run bun run build first.'); });
  const types = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.json': 'application/json' };
  server = http.createServer(async (request, response) => {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    const filename = path.resolve(build, `.${pathname === '/' ? '/index.html' : pathname}`);
    if (!filename.startsWith(`${build}${path.sep}`)) { response.writeHead(403).end(); return; }
    try {
      const data = await fs.readFile(filename);
      response.writeHead(200, { 'Content-Type': types[path.extname(filename)] ?? 'application/octet-stream' });
      response.end(data);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseURL = `http://127.0.0.1:${server.address().port}`;
}

const report = { baseURL, browser: browserName, startedAt: new Date().toISOString(), scenarios: [], failures: [] };
const browser = await browserType.launch({ headless: args.get('headed') !== 'true', ...(browserName === 'chromium' ? {executablePath: args.get('browser-path') ?? process.env.PLAYWRIGHT_BROWSER_PATH} : {}) });
const origin = new URL(baseURL).origin;
const tracks = Array.from({length: 4}, (_, index) => ({
  id: `motion-${index}`, path: `loud://track/motion-${index}`, file_name: `motion-${index}.mp3`,
  title: ['Headroom', 'Motor Start', 'Liner Notes', 'Overnight'][index], artist: 'Motion fixture', album: 'Generated art',
  duration_seconds: 214, artwork_url: `${origin}/api/fixture/art/${index}`, playlist_ids: ['motion-playlist'],
  is_liked: false, fingerprint: `motion-${index}`, added_at: 1700000000 + index, size_bytes: 1024,
}));
const playlists = [{id:'motion-playlist', name:'Drive Home', track_ids:tracks.map(t=>t.id), artwork_url:null, is_liked:false}];
const library = {root_path:'loud://fixture', scanned_at:1700000000, tracks, playlists, artists:[], albums:[],
  stats:{trackCount:4, playlistCount:1, likedCount:0, artistCount:1, albumCount:1, durationSeconds:856}};
const ref = track => ({id:track.id, path:track.path, fingerprint:track.fingerprint});
const themes = (args.get('themes') ?? 'graphite,paper').split(',');

async function sampleDialog(page, selector, duration = 550) {
  return page.evaluate(async ({selector,duration}) => {
    const samples = [], start = performance.now();
    do {
      const node = document.querySelector(selector), css = node ? getComputedStyle(node) : null;
      samples.push({at:performance.now()-start, present:!!node, open:node?.open,
        opacity:css ? Number(css.opacity) : null,
        translate:css?.transform === 'none' ? 0 : css ? new DOMMatrixReadOnly(css.transform).m42 : null});
      await new Promise(requestAnimationFrame);
    } while (performance.now()-start < duration);
    return samples;
  }, {selector,duration});
}
function entered(samples) {
  assert(samples.some(s=>s.present && s.opacity<.95), 'Entrance includes visible intermediate frames');
  assert(samples.at(-1).open && samples.at(-1).opacity>.99, 'Entrance reaches a fully visible open dialog');
}
function exited(samples) {
  assert(samples.some(s=>s.present && s.open && s.opacity>0 && s.opacity<.95), 'Dialog remains in the top layer while fading out');
  assert(!samples.at(-1).present, 'Dialog is removed after the outro finishes');
}
// Playwright exposes taps, but no cross-browser touchscreen swipe API. These
// native TouchEvents exercise WebKit's real non-passive handlers and rendered
// frames; OS gesture arbitration still needs a physical installed-PWA check.
async function touchDrag(page, selector, {dx=0,dy=25,cancel=false,hold=0,click=false,firstMove=0}={}) {
  return page.evaluate(async ({selector,dx,dy,cancel,hold,click,firstMove})=>{
    const target=document.querySelector(selector), rect=target.getBoundingClientRect();
    const x=rect.left+rect.width/2, y=rect.top+Math.min(30,rect.height/2), prevented=[];
    const send=(type,px,py)=>{
      const touch=document.createTouch?document.createTouch(window,target,91,px,py,px,py):new Touch({identifier:91,target,clientX:px,clientY:py,pageX:px,pageY:py,screenX:px,screenY:py});
      const list=(items)=>document.createTouchList?document.createTouchList(...items):items;
      const active=type!=='touchend'&&type!=='touchcancel';
      const event=new TouchEvent(type,{bubbles:true,cancelable:true,touches:list(active?[touch]:[]),targetTouches:list(active?[touch]:[]),changedTouches:list([touch])});
      target.dispatchEvent(event);return event.defaultPrevented;
    };
    send('touchstart',x,y);
    for(let i=1;i<=4;i++){await new Promise(resolve=>setTimeout(resolve,18));prevented.push(send('touchmove',x+dx*i/4,y+(i===1&&firstMove?firstMove:dy*i/4)));}
    await new Promise(requestAnimationFrame);
    const sheet=target.closest('dialog'), before=getComputedStyle(sheet).transform;
    if(hold)await new Promise(resolve=>setTimeout(resolve,hold));
    send(cancel?'touchcancel':'touchend',x+dx,y+dy);
    if(click)target.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1}));
    return {prevented,offset:before==='none'?0:new DOMMatrixReadOnly(before).m42};
  }, {selector,dx,dy,cancel,hold,click,firstMove});
}
async function focusStyle(locator) {
  return locator.evaluate(node => ({width:getComputedStyle(node).outlineWidth, style:getComputedStyle(node).outlineStyle,
    focused:node===document.activeElement, modality:document.documentElement.dataset.inputModality}));
}
function noRing(value) { assert(value.style==='none' || value.width==='0px', `Tap must not leave a focus ring: ${JSON.stringify(value)}`); }

try {
  for (const theme of themes) {
    const installed = theme === themes[0];
    const scenario = {theme, installedViewportFixture:installed, checks:[], errors:[]}; report.scenarios.push(scenario);
    const context = await browser.newContext({viewport:{width:402,height:874}, deviceScaleFactor:2, isMobile:true, hasTouch:true, serviceWorkers:'block'});
    await context.addInitScript(({theme,installed}) => {
      if(installed)Object.defineProperty(navigator,"standalone",{get:()=>true});
      localStorage.setItem('codec.theme',theme); localStorage.setItem('codec.syncServer',location.origin);
      localStorage.setItem('codec.deviceId','motion-browser'); localStorage.setItem('codec.deviceName','This browser');
    }, {theme,installed});
    let state = {schema:'loud.playback.v2', revision:1, active_device_id:'fixture-native', state:'playing', track:ref(tracks[0]),
      context:{playback_source:tracks.map(ref), playback_index:0, queued_tracks:tracks.slice(1).map(ref), play_history:[], shuffle:false, repeat:'off'},
      clock:{position_seconds:92, started_at_ms:Date.now(), updated_at_ms:Date.now()}, volume:.6, server_time_ms:Date.now()};
    const page = await context.newPage(); page.setDefaultTimeout(6000);
    page.on('pageerror', error=>scenario.errors.push(error.message));
    await page.route('**/*', async route => {
      const request=route.request(), url=new URL(request.url()), pathname=url.pathname;
      if(url.origin!==origin) return route.abort();
      if(pathname==='/health') return route.fulfill({json:{ok:true,schema:'loud.sync.v1',playback_schema:'loud.playback.v2',server_id:'motion-fixture'}});
      if(!pathname.startsWith('/api/')) return route.continue();
      if(pathname.startsWith('/api/fixture/art/')) return route.fulfill({contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><rect width="256" height="256" fill="#233866"/><path d="M0 0h150v256H0z" fill="#d08559"/><circle cx="90" cy="88" r="70" fill="#b62f42"/></svg>'});
      if(pathname==='/api/v1/library') return route.fulfill({json:library});
      if(pathname==='/api/v1/auth/stream-token') return route.fulfill({json:{token:'motion_fixture',expires_at:Math.floor(Date.now()/1000)+900}});
      if(pathname.endsWith('/events')) return route.fulfill({contentType:'text/event-stream',body:': fixture\n\n'});
      if(pathname==='/api/v2/playback') return route.fulfill({json:{...state,server_time_ms:Date.now()}});
      if(pathname==='/api/v2/playback/commands') {
        const command=request.postDataJSON();state={...state,revision:state.revision+1,context:command.context??state.context,track:command.track??state.track};
        return route.fulfill({json:{...state,server_time_ms:Date.now()}});
      }
      if(pathname.includes('/devices')) return route.fulfill({json:request.method()==='GET'?[{device_id:'motion-browser',name:'This browser',updated_at:Date.now()},{device_id:'fixture-native',name:'iPhone',updated_at:Date.now(),is_playing:true}]:{}});
      if(pathname==='/api/v1/aux') return route.fulfill({json:[]});
      return route.fulfill({json:{}});
    });
    const tab = name=>page.getByRole('navigation',{name:'Mobile navigation'}).getByRole('button',{name,exact:true});
    const openPlayer = ()=>page.getByRole('button',{name:/^Open Now Playing:/}).tap();
    const dismiss = title=>page.getByRole('dialog',{name:title,exact:true}).getByRole('button',{name:'Done',exact:true}).last().tap();
    try {
      await page.goto(baseURL); await page.getByRole('button',{name:/^Open Now Playing:/}).waitFor();
      await page.evaluate(()=>{
        document.documentElement.style.setProperty('--app-safe-top','62px');
        document.documentElement.style.setProperty('--app-safe-bottom','34px');
      });
      const shellGeometry=await page.evaluate(()=>({bottom:document.querySelector('.app-shell').getBoundingClientRect().bottom,height:innerHeight,standalone:document.documentElement.dataset.standalone,bottomInset:getComputedStyle(document.querySelector('.mobile-bottom-controls')).paddingBottom}));
      assert.equal(shellGeometry.bottom,shellGeometry.height);assert.equal(shellGeometry.standalone,installed?'true':undefined);
      scenario.checks.push({name:'Shell background fills viewport while bottom controls retain one safe inset',...shellGeometry});
      const entrance=sampleDialog(page,'.native-player-sheet'); await openPlayer(); await page.locator('.atmosphere-layers').waitFor();
      const enter=await entrance; entered(enter); scenario.checks.push({name:'Now Playing enters',frames:enter});
      noRing(await focusStyle(page.getByRole('button',{name:'Close Now Playing',exact:true})));
      await page.keyboard.press('Tab');
      const keyboard=await page.evaluate(()=>({tag:document.activeElement.tagName,width:getComputedStyle(document.activeElement).outlineWidth,modality:document.documentElement.dataset.inputModality}));
      assert.equal(keyboard.modality,'keyboard'); assert.equal(keyboard.width,'2px'); scenario.checks.push({name:'Keyboard Tab retains focus ring',...keyboard});
      const device=page.locator('.mobile-now-device select');
      await device.dispatchEvent('pointerdown',{pointerType:'touch'}); await device.focus();
      noRing(await focusStyle(page.locator('.mobile-now-device')));
      await page.keyboard.press('Tab'); await device.focus();
      assert.equal((await focusStyle(page.locator('.mobile-now-device'))).width,'2px');
      scenario.checks.push({name:'Device picker focus respects input method'});
      const atmosphere=await page.evaluate(async()=>{
        const wash=document.querySelector('.atmosphere-wash'), start=performance.now();
        const first=Number(getComputedStyle(wash).opacity), gaps=[];let previous=start;
        while(performance.now()-start<10100){await new Promise(requestAnimationFrame);const now=performance.now();gaps.push(now-previous);previous=now;}
        return {first,final:Number(getComputedStyle(wash).opacity),sameLayer:wash===document.querySelector('.atmosphere-wash'),frames:gaps.length,maxFrameMs:Math.max(...gaps),framesOver34ms:gaps.filter(t=>t>34).length};
      });
      assert(atmosphere.final>atmosphere.first+.1); assert(atmosphere.sameLayer); scenario.checks.push({name:'Artwork atmosphere advances without replacing layers',...atmosphere});
      const queueEntrance=sampleDialog(page,'.native-queue-sheet');await page.getByRole('button',{name:'Queue',exact:true}).tap();
      const queueEnter=await queueEntrance;entered(queueEnter);scenario.checks.push({name:'Nested Queue enters',frames:queueEnter});
      const queueDrag=await touchDrag(page,'.native-queue-sheet .mobile-queue-section h3',{dy:110});assert.equal(queueDrag.offset,0);assert(queueDrag.prevented.every(value=>!value));
      assert(await page.getByRole('dialog',{name:'Now Playing',exact:true}).isVisible());
      const queueLeaving=sampleDialog(page,'.native-queue-sheet',400);await dismiss('Queue');const queueExit=await queueLeaving;exited(queueExit);
      assert(await page.getByRole('dialog',{name:'Now Playing',exact:true}).isVisible());scenario.checks.push({name:'Nested Queue dismisses without closing player',frames:queueExit});
      const sheetGeometry=await page.evaluate(()=>{
        const sheet=document.querySelector('.native-player-sheet'), panel=sheet.querySelector('.mobile-sheet-panel'), body=sheet.querySelector('.mobile-sheet-body');
        return {bottom:sheet.getBoundingClientRect().bottom,height:innerHeight,panelBottom:panel.getBoundingClientRect().bottom,bodyBottom:body.getBoundingClientRect().bottom,padding:Number.parseFloat(getComputedStyle(panel).paddingBottom)};
      });
      assert.equal(sheetGeometry.bottom,sheetGeometry.height);assert.equal(sheetGeometry.panelBottom,sheetGeometry.height);
      assert.equal(sheetGeometry.padding,34);assert.equal(sheetGeometry.bodyBottom,sheetGeometry.height-34);
      scenario.checks.push({name:'Player background reaches bottom and content applies safe inset once',...sheetGeometry});
      const short=await touchDrag(page,'.native-player-sheet .sheet-grabber',{click:true});
      assert(short.offset>15);await page.waitForTimeout(260);assert(await page.locator('.native-player-sheet').isVisible());
      scenario.checks.push({name:'Short drag snaps back instead of click-dismiss',...short});
      const slowStart=await touchDrag(page,'.mobile-now-art',{firstMove:1});assert(slowStart.prevented[0]);
      await page.waitForTimeout(260);assert(await page.locator('.native-player-sheet').isVisible());
      scenario.checks.push({name:'Tiny first downward move claims touch before Safari starts scrolling',...slowStart});
      for(const selector of ['.mobile-now-art','.mobile-now-title .mobile-track-copy','.mobile-now-spacer.after-art']) {
        const drag=await touchDrag(page,selector,{dy:110});assert(drag.offset>90);assert(drag.prevented.every(Boolean));
        await page.locator('.native-player-sheet').waitFor({state:'detached'});await openPlayer();await page.waitForTimeout(350);
        scenario.checks.push({name:`Downward pull dismisses from ${selector}`,...drag});
      }
      for(const selector of ['.mobile-now-progress input','.mobile-now-device select','.mobile-now-play','.mobile-now-title button']) {
        const drag=await touchDrag(page,selector,{dy:110});assert.equal(drag.offset,0);assert(drag.prevented.every(value=>!value));
      }
      scenario.checks.push({name:'Progress, device, playback, and title controls do not drag the sheet'});
      for(const options of [{dy:-100},{dx:90,dy:20}]) {
        const drag=await touchDrag(page,'.mobile-now-art',options);assert.equal(drag.offset,0);assert(drag.prevented.every(value=>!value));
      }
      scenario.checks.push({name:'Upward scrolling and horizontal gestures remain unclaimed'});
      const cancelled=await touchDrag(page,'.mobile-now-art',{dy:110,cancel:true});assert(cancelled.offset>90);
      await page.waitForTimeout(260);assert(await page.locator('.native-player-sheet').isVisible());
      const held=await touchDrag(page,'.mobile-now-art',{dy:45,hold:180});await page.waitForTimeout(260);assert(await page.locator('.native-player-sheet').isVisible());
      scenario.checks.push({name:'Cancelled drag and slow short pull snap back',cancelled,held});
      const flick=await touchDrag(page,'.mobile-now-art',{dy:45});assert(flick.offset>35);
      await page.locator('.native-player-sheet').waitFor({state:'detached'});await openPlayer();await page.waitForTimeout(350);
      scenario.checks.push({name:'Short downward flick dismisses using recent velocity',...flick});
      await page.setViewportSize({width:402,height:560});await page.waitForTimeout(150);
      await page.locator('.native-player-sheet .mobile-sheet-body').evaluate(node=>{node.scrollTop=80;});
      assert(await page.locator('.native-player-sheet .mobile-sheet-body').evaluate(node=>node.scrollTop>0));
      const scrolled=await touchDrag(page,'.mobile-now-title .mobile-track-copy',{dy:110});assert.equal(scrolled.offset,0);assert(scrolled.prevented.every(value=>!value));
      await page.setViewportSize({width:402,height:874});await page.waitForTimeout(150);
      await page.locator('.native-player-sheet .mobile-sheet-body').evaluate(node=>{node.scrollTop=0;});
      const resized=await page.evaluate(()=>({sheetBottom:document.querySelector('.native-player-sheet').getBoundingClientRect().bottom,shellBottom:document.querySelector('.app-shell').getBoundingClientRect().bottom,height:innerHeight}));
      assert.equal(resized.sheetBottom,resized.height);assert.equal(resized.shellBottom,resized.height);
      scenario.checks.push({name:'Scrolled content is respected and resized viewport still fills bottom',...resized});
      await page.screenshot({path:path.join(output,`${theme}-player-safe-area.png`)});
      const leaving=sampleDialog(page,'.native-player-sheet',450);await page.getByRole('button',{name:'Close Now Playing',exact:true}).tap();const exit=await leaving;exited(exit);scenario.checks.push({name:'Now Playing dismisses',frames:exit});
      noRing(await focusStyle(page.getByRole('button',{name:/^Open Now Playing:/})));
      await page.getByRole('button',{name:'Settings',exact:true}).tap();await page.waitForTimeout(350);
      noRing(await focusStyle(page.getByRole('dialog',{name:'Settings',exact:true}).getByRole('button',{name:'Done',exact:true})));
      await dismiss('Settings');await page.getByRole('dialog',{name:'Settings',exact:true}).waitFor({state:'detached'});
      noRing(await focusStyle(page.getByRole('button',{name:'Settings',exact:true})));scenario.checks.push({name:'Tap and modal restoration leave no toolbar outline'});
      await tab('Search').tap();const search=page.getByRole('searchbox',{name:'Search library',exact:true});await search.tap();
      noRing(await focusStyle(page.locator('.mobile-search-field')));noRing(await focusStyle(search));
      await page.keyboard.press('Tab');await search.focus();assert.equal((await focusStyle(page.locator('.mobile-search-field'))).width,'2px');scenario.checks.push({name:'Search focus respects input method'});
      await tab('Library').tap();const create=page.getByRole('button',{name:'New playlist',exact:true});await create.focus();
      const alertEntrance=sampleDialog(page,'.native-alert',400);await page.keyboard.press('Enter');const alertEnter=await alertEntrance;entered(alertEnter);
      assert(await page.getByRole('textbox',{name:'Playlist name',exact:true}).evaluate(el=>el===document.activeElement));scenario.checks.push({name:'New Playlist enters and focuses name',frames:alertEnter});
      const alertLeaving=sampleDialog(page,'.native-alert',300);await page.keyboard.press('Escape');const alertExit=await alertLeaving;exited(alertExit);
      assert(await create.evaluate(el=>el===document.activeElement));scenario.checks.push({name:'Keyboard alert dismissal restores trigger focus',frames:alertExit});
      const interrupted=await page.evaluate(async()=>{
        document.querySelector('.mobile-mini-summary').click();await new Promise(resolve=>setTimeout(resolve,80));
        const node=document.querySelector('.native-player-sheet'), before=Number(getComputedStyle(node).opacity);
        document.querySelector('.native-player-sheet .sheet-grabber').click();await new Promise(requestAnimationFrame);
        const after=Number(getComputedStyle(node).opacity);await new Promise(resolve=>setTimeout(resolve,250));return {before,after,removed:!node.isConnected};
      });
      assert(interrupted.before<1);assert(interrupted.after<=interrupted.before+.15);assert(interrupted.removed);scenario.checks.push({name:'Closing during entrance does not jump',...interrupted});
      await page.emulateMedia({reducedMotion:'reduce'});await openPlayer();
      const reduced=await page.evaluate(()=>({sheet:document.querySelector('.native-player-sheet').getAnimations().length,atmosphere:document.querySelector('.atmosphere-wash')?.getAnimations().length??0}));
      assert.equal(reduced.sheet,0);assert.equal(reduced.atmosphere,0);
      await touchDrag(page,'.mobile-now-art',{dy:25,cancel:true});
      const reducedOffset=await page.locator('.native-player-sheet').evaluate(node=>getComputedStyle(node).transform);
      assert.equal(reducedOffset,'none');
      scenario.checks.push({name:'Reduced motion stays static and cancelled drag resets immediately',...reduced});
      assert.deepEqual(scenario.errors,[]);
    } catch(error) {
      report.failures.push({theme,error:error.stack});await page.screenshot({path:path.join(output,`${theme}-failure.png`)});
      await fs.writeFile(path.join(output,`${theme}-failure.txt`),await page.locator('body').innerText());
    } finally { await context.close(); }
  }
} finally {
  await browser.close();await new Promise(resolve=>server ? server.close(resolve) : resolve());
  await fs.writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify({output,scenarios:report.scenarios.map(s=>({theme:s.theme,checks:s.checks.map(c=>c.name),errors:s.errors})),failures:report.failures},null,2));
if(report.failures.length)process.exitCode=1;
