#!/usr/bin/env node
// Isolated WebKit import UI regression: no existing server/library/credentials.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/import-regression.mjs [build-dir] [output-dir]
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const { webkit } = await import(moduleName.startsWith('/') ? pathToFileURL(moduleName).href : moduleName);
const build = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '../build'));
const output = path.resolve(process.argv[3] ?? path.join(os.tmpdir(), 'codec-import-regression'));
await fs.mkdir(output, { recursive: true });
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
const art = { file: 'covers/cover.png', sha256: createHash('sha256').update(png).digest('hex'), mime_type: 'image/png', width: 1, height: 1 };
const manifest = { schema: 'loud.import.v1', source: { base_path: 'media' }, tracks: [
  {file: 'audio/song.mp3', fingerprint: 'import-fixture', title: 'Import fixture', artwork: art}
], playlists: [{name:'Artwork fixture', tracks:[{fingerprint:'import-fixture'}], artwork:art}] };
const payloads = [
  {name:'track-artwork.json', mimeType:'application/json', buffer:Buffer.from(JSON.stringify({schema:'s2y.track-artwork.v1',tracks:[{fingerprint:'import-fixture',artwork:{...art,file:'ignored/cover.png'}}]}))},
  {name:'loud-import.json', mimeType:'application/json', buffer:Buffer.from(JSON.stringify(manifest))},
  {name:'song.mp3', mimeType:'audio/mpeg', buffer:Buffer.from('original-fixture-audio')},
  {name:'cover.png', mimeType:'image/png', buffer:png}
];
const library = {root_path:'loud://sync-server',scanned_at:1700000000,tracks:[],playlists:[],artists:[],albums:[],stats:{trackCount:0,playlistCount:0,likedCount:0,artistCount:0,albumCount:0,durationSeconds:0}};
let origin, rejectUpload = false, importMode = 'done';
let activePolls = 0, maxActivePolls = 0, pollCount = 0;
const pendingUploads = new Set();
const uploads = [], errors = [];
const server = http.createServer(async (req,res) => {
  try {
    const url = new URL(req.url, origin ?? 'http://127.0.0.1');
    const json = (value,status=200) => {res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
    if (url.pathname === '/health') return json({ok:true,schema:'loud.sync.v1',playback_schema:'loud.playback.v2',server_id:'import-fixture'});
    if (url.pathname === '/api/v1/library') return json(library);
    if (url.pathname === '/api/v1/auth/stream-token') return json({token:'fixture-only',expires_at:Math.floor(Date.now()/1000)+900});
    if (url.pathname === '/api/v1/import/bundle') {
      const chunks=[];for await (const chunk of req) chunks.push(chunk);
      const bytes=Buffer.concat(chunks); uploads.push(bytes);
      assert.equal(bytes.readUInt32LE(0),0x04034b50,'Browser upload must be a ZIP');
      await fs.writeFile(path.join(output,`uploaded-${uploads.length}.zip`),bytes);
      if (importMode === 'upload-hang') {
        pendingUploads.add(res);
        res.on('close', () => pendingUploads.delete(res));
        return;
      }
      return rejectUpload ? json({error:'Private proxy diagnostic'},413) : json({id:'fixture-job'},202);
    }
    if (url.pathname === '/api/v1/import/jobs/fixture-job') {
      const mode = importMode;
      activePolls++;
      pollCount++;
      maxActivePolls = Math.max(maxActivePolls, activePolls);
      try {
        if (mode === 'poll-failure') {
          await new Promise(resolve => setTimeout(resolve, 2500));
          return json({error:'Fixture connection unavailable'},503);
        }
        if (mode === 'running') return json({id:'fixture-job',state:'running',total:4,done:1,current:'Import fixture.mp3',added:1,existing:0,skipped:0,playlist_adds:0,liked:0});
        if (mode === 'failed') return json({id:'fixture-job',state:'failed',error:'Invalid ZIP archive.',total:0,done:0,added:0,existing:0,skipped:0,playlist_adds:0,liked:0});
        return json({id:'fixture-job',state:'done',total:4,done:4,added:1,existing:3,audio_restored:2,skipped:0,playlist_adds:1,liked:0,
          track_artwork_imported:2,playlist_artwork_imported:1,artwork_imported:3,artwork_already_present:4,artwork_missing:1,artwork_failed:1,
          artwork_warnings:['missing-cover.png: Missing artwork file','bad-cover.png: Digest mismatch']});
      } finally { activePolls--; }
    }
    if (url.pathname.endsWith('/events')) {res.writeHead(200,{'Content-Type':'text/event-stream'});res.write(': fixture\n\n');return;}
    if (url.pathname.includes('/playback/devices')) return json(req.method==='GET'?[]:{});
    if (url.pathname === '/api/v2/playback') return json({schema:'loud.playback.v2',revision:0,state:'paused',active_device_id:null,track:null,context:{playback_source:[],playback_index:0,queued_tracks:[],play_history:[],shuffle:false,repeat:'off'},clock:{position_seconds:0,started_at_ms:null,updated_at_ms:Date.now()},volume:1,server_time_ms:Date.now()});
    if (url.pathname.startsWith('/api/')) return json([]);
    const filename=path.resolve(build,'.'+(url.pathname==='/'?'/index.html':decodeURIComponent(url.pathname)));
    if (!filename.startsWith(build+path.sep)) {res.writeHead(403).end();return;}
    const bytes=await fs.readFile(filename);
    res.writeHead(200,{'Content-Type':({'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.woff2':'font/woff2'})[path.extname(filename)]??'application/octet-stream'});res.end(bytes);
  } catch(error) { errors.push(String(error)); if (!res.headersSent) res.writeHead(500);res.end(); }
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve)); origin=`http://127.0.0.1:${server.address().port}`;
const browser=await webkit.launch({headless:true});
const checks=[];
async function pageAt(width) {
  const context=await browser.newContext({viewport:{width,height:900},isMobile:width<600,hasTouch:width<600,serviceWorkers:'block'});
  await context.addInitScript(()=>{localStorage.setItem('codec.syncServer',location.origin);localStorage.setItem('codec.syncToken','fixture-only');localStorage.setItem('codec.musicRoot','loud://sync-server');});
  const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));
  await page.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
  await page.goto(origin);await page.getByRole('button',{name:'Settings',exact:true}).click();
  return {page,context};
}
function settingsFor(page, width) {
  return page.locator(width < 600 ? '.native-settings' : '.settings-modal');
}
async function visibleProgress(page, width, text) {
  const banner = settingsFor(page, width).locator('.import-banner');
  await banner.getByText(text).first().waitFor({ state:'visible' });
  await banner.scrollIntoViewIfNeeded();
  assert(await banner.isVisible(), 'Import progress must be inside the open settings surface');
  return banner;
}
async function selectZIP(page) {
  await page.locator('input[type=file]:not([webkitdirectory])').setInputFiles({name:'fixture.loud.zip',mimeType:'application/zip',buffer:uploads[0]});
}
try {
  const {page,context}=await pageAt(390);
  const accepted=await page.locator('input[type=file]').getAttribute('accept');
  for (const extension of ['.mp3','.m4a','.flac','.wav','.json','.png','.zip']) assert(accepted.includes(extension),`Mobile bundle picker accepts ${extension}`);
  await page.locator('input[type=file]').setInputFiles(payloads);
  await visibleProgress(page, 390, /2 track covers imported/);
  const message=await page.locator('.native-settings').innerText();
  for (const expected of ['2 missing audio files restored','1 playlist cover imported','4 existing covers kept','1 cover missing','1 cover import failed']) assert(message.includes(expected),expected);
  assert.equal(uploads.length,1);checks.push('Mobile loose-file import packs artwork and sidecars as ZIP64; inline cover overrides conflicting sidecar filename; distinct artwork counters visible');
  await page.screenshot({path:path.join(output,'mobile-import-result.png')});
  rejectUpload=true;
  await page.locator('input[type=file]').setInputFiles({name:'fixture.loud.zip',mimeType:'application/zip',buffer:uploads[0]});
  await visibleProgress(page, 390, /server or proxy upload limit/);
  assert(!(await page.locator('body').innerText()).includes('Private proxy diagnostic'));
  checks.push('413 provides actionable upload limit message without exposing server response');
  await context.close();rejectUpload=false;
  const desktop=await pageAt(1280);
  const desktopAccepted=await desktop.page.locator('input[type=file]:not([webkitdirectory])').getAttribute('accept');
  for (const extension of ['.mp3','.m4a','.flac','.wav']) assert(desktopAccepted.includes(extension),`Desktop bundle picker accepts ${extension}`);
  const folder=path.join(output,'bundle-folder');await fs.mkdir(path.join(folder,'media/audio'),{recursive:true});await fs.mkdir(path.join(folder,'media/covers'),{recursive:true});
  await fs.writeFile(path.join(folder,'loud-import.json'),JSON.stringify(manifest));await fs.writeFile(path.join(folder,'media/audio/song.mp3'),'original-fixture-audio');await fs.writeFile(path.join(folder,'media/covers/cover.png'),png);
  await desktop.page.locator('input[webkitdirectory]').setInputFiles(folder);
  await visibleProgress(desktop.page, 1280, /2 track covers imported/);
  assert.equal(uploads.length,3);checks.push('Desktop browser folder picker preserves nested source.base_path entries');
  await desktop.context.close();

  for (const width of [390, 1280]) {
    importMode = 'running';
    const session = await pageAt(width);
    await selectZIP(session.page);
    const banner = await visibleProgress(session.page, width, /Importing\s+1\/4/);
    assert((await banner.innerText()).includes('Import fixture.mp3'), 'Current file is visible beside track progress');
    assert.equal(await banner.locator('[role=progressbar]').getAttribute('aria-valuenow'), '25');
    await session.page.screenshot({path:path.join(output,`progress-${width}.png`)});
    // Changing screens or reloading must not require uploading the ZIP again.
    const countBeforeReload = uploads.length;
    await session.page.reload();
    await session.page.getByRole('button',{name:'Settings',exact:true}).click();
    await visibleProgress(session.page, width, /Importing\s+1\/4/);
    assert.equal(uploads.length,countBeforeReload,'Reload resumes the existing server job');
    importMode = 'failed';
    await visibleProgress(session.page, width, /Invalid ZIP archive/);
    assert(await settingsFor(session.page,width).getByRole('button',{name:/^Import music\b/}).isEnabled(),'Failed job releases import controls');
    await session.page.screenshot({path:path.join(output,`failed-${width}.png`)});
    checks.push(`${width < 600 ? 'Mobile' : 'Desktop'} settings show live file/count progress and server failure; reload resumes without duplicate upload`);
    await session.context.close();
  }

  importMode = 'poll-failure';
  pollCount = 0;
  maxActivePolls = 0;
  const reconnect = await pageAt(1280);
  await selectZIP(reconnect.page);
  const retryBanner = await visibleProgress(reconnect.page,1280,/Checking connection/);
  const retry = retryBanner.getByRole('button',{name:'Check again',exact:true});
  assert(await retry.isVisible(),'Temporary status failures offer a retry in Settings');
  assert.equal(maxActivePolls,1,'Slow status reads must not create overlapping requests');
  assert(pollCount > 0);
  await reconnect.page.screenshot({path:path.join(output,'reconnecting-1280.png')});
  importMode = 'running';
  await retry.click();
  await visibleProgress(reconnect.page,1280,/Importing\s+1\/4/);
  assert.equal(maxActivePolls,1,'Manual retry must not overlap an automatic status read');
  importMode = 'done';
  await visibleProgress(reconnect.page,1280,/Import finished/);
  checks.push('Slow failing status reads remain sequential, explain the connection problem, and recover through Check again');
  await reconnect.context.close();

  for (const width of [390,1280]) {
    importMode = 'upload-hang';
    const session = await pageAt(width);
    await selectZIP(session.page);
    const settings = settingsFor(session.page,width);
    const cancel = settings.locator('.import-banner').getByRole('button',{name:'Cancel upload',exact:true});
    await cancel.waitFor({state:'visible'});
    assert(!(await settings.getByRole('button',{name:width < 600 ? /^Importing…$/ : /^Import music\b/}).isEnabled()),'Upload disables a second import');
    await cancel.click();
    await session.page.waitForFunction(selector => [...document.querySelectorAll(`${selector} button`)].some(button => button.textContent.trim().startsWith('Import music') && !button.disabled),width < 600 ? '.native-settings' : '.settings-modal');
    // A cancelled upload must also permit a real subsequent selection.
    importMode = 'done';
    await selectZIP(session.page);
    await visibleProgress(session.page,width,/Import finished/);
    checks.push(`${width < 600 ? 'Mobile' : 'Desktop'} unacknowledged upload can be cancelled and a new import completes`);
    await session.context.close();
    for (const response of pendingUploads) response.destroy();
    pendingUploads.clear();
  }
  assert.deepEqual(errors,[]);
  await fs.writeFile(path.join(output,'report.json'),JSON.stringify({checks,uploads:uploads.length,errors},null,2));
  console.log(JSON.stringify({checks,uploads:uploads.length,output},null,2));
} catch (error) {
  const page = browser.contexts().flatMap(context => context.pages()).at(-1);
  if (page && !page.isClosed()) await page.screenshot({path:path.join(output,'failure.png')}).catch(() => {});
  await fs.writeFile(path.join(output,'report.json'),JSON.stringify({checks,uploads:uploads.length,errors,failure:String(error)},null,2));
  throw error;
} finally {await browser.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
