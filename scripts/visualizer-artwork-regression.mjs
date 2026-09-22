#!/usr/bin/env node
// Real browser/canvas + real audio, deterministic FFT magnitudes. Isolated art,
// credentials and server; no user's music or playback is touched.
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const moduleName=process.env.PLAYWRIGHT_MODULE??'playwright';
const browsers=await import(moduleName.startsWith('/')?pathToFileURL(moduleName).href:moduleName);
const browserName=process.env.CODEC_TEST_BROWSER??'webkit';
const theme=process.env.CODEC_TEST_THEME??'graphite';
const historyOnly=process.env.CODEC_TEST_HISTORY_ONLY==='1';
const build=path.resolve(process.argv[2]??'build'),output=path.resolve(process.argv[3]??'/tmp/codec-visualizer-artwork');
await fs.mkdir(output,{recursive:true});
const duration=180,wave=Buffer.alloc(44+22050*duration*2);wave.write('RIFF');wave.writeUInt32LE(wave.length-8,4);wave.write('WAVEfmt ',8);wave.writeUInt32LE(16,16);wave.writeUInt16LE(1,20);wave.writeUInt16LE(1,22);wave.writeUInt32LE(22050,24);wave.writeUInt32LE(44100,28);wave.writeUInt16LE(2,32);wave.writeUInt16LE(16,34);wave.write('data',36);wave.writeUInt32LE(wave.length-44,40);
for(let i=0;i<22050*duration;i++)wave.writeInt16LE(Math.round(Math.sin(i*2*Math.PI*220/22050)*500),44+i*2);
let origin,cover='four',trailBlueCover='solidblue',audioRequests=0,libraryReads=0;const held=[],historyHeld=[];const subscribers=new Set();const artRequests={};
const artworkColors={
  four:[[227,64,57],[37,66,190],[35,201,107],[240,195,70]],
  red:[[227,64,57],[37,66,190],[19,14,24]],
  green:[[35,201,107],[40,189,96],[12,26,17]],
  solid:[[35,201,107]],
  solidred:[[227,64,57]],
  solidblue:[[37,66,190]],
  gray:[[48,48,48],[112,112,112],[184,184,184],[224,224,224]]
};
const track=()=>({id:'fixture',path:'loud://track/fixture',file_name:'fixture.wav',title:'Artwork spectrum',artist:'Synthetic fixture',album:'Source-color study',duration_seconds:duration,artwork_url:cover?`${origin}/api/art/${cover}`:null,playlist_ids:[],is_liked:false,fingerprint:'fixture',added_at:1700000000,size_bytes:wave.length});
const trailTrack=(name,art)=>({...track(),id:`trail-${name}`,path:`loud://track/trail-${name}`,fingerprint:`trail-${name}`,title:`${name[0].toUpperCase()+name.slice(1)} trail`,artwork_url:`${origin}/api/art/${art}`});
const tracks=()=>[track(),trailTrack('red','solidred'),trailTrack('green','solid'),trailTrack('blue',trailBlueCover)];
const ref={id:'fixture',path:'loud://track/fixture',fingerprint:'fixture'};
let state={schema:'loud.playback.v2',revision:1,active_device_id:'fixture-web',state:'paused',track:ref,context:{playback_source:[ref],playback_index:0,queued_tracks:[],play_history:[],shuffle:false,repeat:'off'},clock:{position_seconds:0,started_at_ms:null,updated_at_ms:Date.now()},volume:0,server_time_ms:Date.now()};
const snapshot=()=>({...state,server_time_ms:Date.now()});
const event=(name,data)=>{for(const res of subscribers)res.write(`event: ${name}\ndata: ${JSON.stringify({type:name,...data})}\n\n`)};
function art(response,key){
  const colors=artworkColors[key];
  const rect=(color,x,y,width,height)=>`<rect x="${x}" y="${y}" width="${width}" height="${height}" fill="rgb(${color.join(' ')})"/>`;
  const shapes=colors.length===1?rect(colors[0],0,0,256,256):colors.length===3?
    rect(colors[0],0,0,256,128)+rect(colors[1],0,128,128,128)+rect(colors[2],128,128,128,128):
    colors.map((color,index)=>rect(color,(index%2)*128,Math.floor(index/2)*128,128,128)).join('');
  // Boundaries align with the 48px sampling grid: the fixture introduces no
  // interpolated edge colors that could obscure the source-pixel assertion.
  response.writeHead(200,{'Content-Type':'image/svg+xml','Cache-Control':'no-store'});
  response.end(`<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256">${shapes}</svg>`);
}
const server=http.createServer(async(req,res)=>{try{const url=new URL(req.url,origin??'http://127.0.0.1');const p=url.pathname;const json=(v,status=200)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(v))};
if(p==='/health')return json({ok:true,schema:'loud.sync.v1',playback_schema:'loud.playback.v2',server_id:'art-fixture'});
if(p==='/api/v1/auth/stream-token')return json({token:'fixture-only',expires_at:Date.now()/1000+900});
if(p==='/api/v1/library'){libraryReads++;return json({root_path:'loud://fixture',scanned_at:1700000000,tracks:tracks(),playlists:[],albums:[],artists:[],stats:{trackCount:4,playlistCount:0,likedCount:0,albumCount:1,artistCount:1,durationSeconds:duration*4}})}
if(p==='/api/v2/playback')return json(snapshot());
if(p==='/api/v2/playback/events'){res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache'});subscribers.add(res);req.on('close',()=>subscribers.delete(res));res.write(`event: playback_state\ndata: ${JSON.stringify({type:'playback_state',playback_state:snapshot()})}\n\n`);return}
if(p.includes('/devices'))return json(req.method==='GET'?[{device_id:'fixture-web',name:'This browser',updated_at:Date.now()}]:{});
if(p==='/api/v2/playback/commands'){let body='';for await(const part of req)body+=part;const c=JSON.parse(body);state={...state,revision:state.revision+1,state:c.kind==='pause'?'paused':c.kind==='play'?'playing':state.state,clock:{position_seconds:c.position_seconds??0,started_at_ms:c.kind==='pause'?null:Date.now(),updated_at_ms:Date.now()}};json(snapshot());event('playback_state',{playback_state:snapshot()});return}
if(p.startsWith('/api/art/')){const key=p.split('/').at(-1);artRequests[key]=(artRequests[key]??0)+1;if(key==='slow'){held.push(res);return}if(key==='trail-slow'){historyHeld.push(res);return}if(key==='broken')return json({},404);return art(res,key)}
if(p.includes('/audio')){audioRequests++;let start=0,end=wave.length-1;const range=/bytes=(\d+)-(\d*)/.exec(req.headers.range??'');if(range){start=Number(range[1]);if(range[2])end=Math.min(Number(range[2]),end)}const headers={'Content-Type':'audio/wav','Accept-Ranges':'bytes','Content-Length':end-start+1};if(range)headers['Content-Range']=`bytes ${start}-${end}/${wave.length}`;res.writeHead(range?206:200,headers);return res.end(wave.subarray(start,end+1))}
if(p.startsWith('/api/'))return json([]);
const file=path.resolve(build,'.'+(p==='/'?'/index.html':decodeURIComponent(p)));if(!file.startsWith(build+path.sep)){res.writeHead(403).end();return}const data=await fs.readFile(file);res.writeHead(200,{'Content-Type':({'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.woff2':'font/woff2'})[path.extname(file)]??'application/octet-stream'});res.end(data);
}catch{if(!res.headersSent)res.writeHead(404);res.end()}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));origin=`http://127.0.0.1:${server.address().port}`;
const browser=await browsers[browserName].launch({headless:true,...(browserName==='chromium'?{executablePath:process.env.PLAYWRIGHT_BROWSER_PATH}: {})});
const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:2,isMobile:true,hasTouch:true,serviceWorkers:'block'});
await context.addInitScript(theme=>{
localStorage.setItem('codec.syncServer',location.origin);localStorage.setItem('codec.syncToken','fixture-only');localStorage.setItem('codec.deviceId','fixture-web');localStorage.setItem('codec.theme',theme);
window.__drawReads=0;window.__media=[];window.__samples=0;const get=CanvasRenderingContext2D.prototype.getImageData;CanvasRenderingContext2D.prototype.getImageData=function(...args){if(this.canvas.width===48)window.__drawReads++;return get.apply(this,args)};
AnalyserNode.prototype.getByteFrequencyData=function(bytes){window.__samples++;if(typeof window.__spectrumByte==='number'){bytes.fill(window.__spectrumByte);return}for(let i=0;i<bytes.length;i++)bytes[i]=Math.round(50+195*(.5+.5*Math.sin(Math.log2(i+1)*2+performance.now()/1100)))};
// History tests slow sampling/display callbacks equally so a short viewport
// retains several songs while normal browser UI and real audio keep running.
// This is a deterministic rendering test, not an FPS benchmark.
const nativeFrame=requestAnimationFrame.bind(window),nativeCancel=cancelAnimationFrame.bind(window),pending=new Map();let frameID=0;
window.requestAnimationFrame=callback=>{const id=++frameID,entry={frame:0,timer:0};pending.set(id,entry);entry.frame=nativeFrame(()=>{const run=()=>{if(!pending.has(id))return;pending.delete(id);callback(performance.now())};if(window.__historyFrameDelay)entry.timer=setTimeout(run,window.__historyFrameDelay);else run()});return id};
window.cancelAnimationFrame=id=>{const entry=pending.get(id);if(entry){nativeCancel(entry.frame);clearTimeout(entry.timer);pending.delete(id)}};
for(const name of ['play','pause','load']){const fn=HTMLMediaElement.prototype[name];HTMLMediaElement.prototype[name]=function(...args){window.__media.push({name,at:performance.now()});return fn.apply(this,args)}}
},theme);
const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
const report={browser:browserName,theme,fixture:'Synthetic square artwork and generated audio; no private library or live server.',checks:[],errors};
async function pixels(){return page.locator('.visualizer-stage canvas').evaluate(canvas=>{
  // Use a completely covered device pixel, avoiding antialiased cell edges.
  // The latest column is at the right edge and all FFT bins are held equal.
  const bands=112,cell=canvas.height/bands,gap=Math.max(1,Math.floor(cell*.22));
  let y=-1;
  for(let band=0;band<bands;band++){
    const top=canvas.height-(band+1)*cell+gap/2,bottom=top+Math.max(1,cell-gap);
    const candidate=Math.ceil(top);
    if(candidate+1<=bottom+.000001){y=candidate;break}
  }
  if(y<0)throw new Error('No fully covered spectrum pixel available');
  const rgba=[...canvas.getContext('2d').getImageData(canvas.width-2,y,1,1).data];
  return{rgb:rgba.slice(0,3),alpha:rgba[3],reads:window.__drawReads,media:window.__media.length,audioTime:document.querySelector('audio').currentTime,paused:document.querySelector('audio').paused};
})}
async function probe(byte){await page.evaluate(value=>{window.__spectrumByte=value},byte);await page.waitForTimeout(180);return pixels()}
async function capture(name){await page.evaluate(()=>{delete window.__spectrumByte});await page.waitForTimeout(2400);await page.screenshot({path:path.join(output,name)});return probe(255)}
async function until(fn){const deadline=Date.now()+10000;while(!await fn()){assert(Date.now()<deadline,'Timed out waiting for spectrum');await page.waitForTimeout(40)}}
async function changeCover(value){cover=value;const reads=libraryReads;event('library',{});await until(()=>libraryReads>reads);await page.waitForTimeout(200)}
async function palette(expected,uniqueCount){
  const background=(await probe(0)).rgb,observed=[];
  for(const byte of [40,96,168,255]){
    const value=await probe(byte),alpha=Math.pow(byte/255,.55);
    const matches=expected.map(source=>({source,error:Math.max(...source.map((channel,index)=>
      Math.abs(value.rgb[index]-Math.round(channel*alpha+background[index]*(1-alpha)))))})).sort((a,b)=>a.error-b.error);
    assert(matches[0].error<=2,`Intensity ${byte}: canvas RGB ${value.rgb} is not any supplied artwork color composited over ${background}; closest error ${matches[0].error}`);
    assert.equal(value.alpha,255);
    observed.push({byte,source:matches[0].source,rendered:value.rgb,error:matches[0].error});
  }
  const unique=new Set(observed.map(value=>value.source.join(','))).size;
  if(uniqueCount!==undefined)assert.equal(unique,uniqueCount,'The rendered bands must preserve the number of distinct supplied colors');
  return{background,observed,unique};
}
async function themeInk(){return page.locator('.visualizer-stage').evaluate(stage=>{
  const style=getComputedStyle(stage),canvas=document.createElement('canvas');canvas.width=canvas.height=1;
  const context=canvas.getContext('2d');
  return['--color-accent','--color-text'].map(name=>{context.fillStyle=style.getPropertyValue(name).trim();context.fillRect(0,0,1,1);return[...context.getImageData(0,0,1,1).data].slice(0,3)});
})}
async function trailPixels(){return page.locator('.visualizer-stage canvas').evaluate(canvas=>{
  const cell=canvas.height/112,gap=Math.max(1,Math.floor(cell*.22));let inkY=-1,backgroundY=-1;
  for(let band=0;band<112;band++){
    const edge=canvas.height-(band+1)*cell,top=edge+gap/2,bottom=top+Math.max(1,cell-gap);
    if(inkY<0&&Math.ceil(top)+1<=bottom+.000001)inkY=Math.ceil(top);
    const gapTop=edge-gap/2,gapBottom=edge+gap/2;
    if(backgroundY<0&&gapTop>=0&&Math.ceil(gapTop)+1<=gapBottom+.000001)backgroundY=Math.ceil(gapTop);
  }
  if(inkY<0||backgroundY<0)throw new Error('No fully covered ink/background pixels');
  const context=canvas.getContext('2d');
  const ink=context.getImageData(0,inkY,canvas.width,1).data,bg=context.getImageData(0,backgroundY,canvas.width,1).data;
  return{width:canvas.width,step:Math.max(2,Math.round(2.4*Math.min(devicePixelRatio,2))),samples:window.__samples,
    ink:Array.from({length:canvas.width},(_,x)=>[...ink.slice(x*4,x*4+3)]),
    background:Array.from({length:canvas.width},(_,x)=>[...bg.slice(x*4,x*4+3)])};
})}
const closeColor=(a,b)=>a.every((channel,index)=>Math.abs(channel-b[index])<=1);
function trailRun(snapshot,color){
  const runs=[];let start=-1;
  for(let x=0;x<=snapshot.width;x++){
    if(x<snapshot.width&&closeColor(snapshot.ink[x],color)){if(start<0)start=x}
    else if(start>=0){runs.push({start,end:x-1,length:x-start});start=-1}
  }
  return runs.at(-1)??{start:-1,end:-1,length:0};
}
function preservedTrail(snapshot,color,background,label,min=5){
  const run=trailRun(snapshot,color);assert(run.length>=min,`${label}: old artwork ink was recolored or lost (${run.length}px remain)`);
  for(let x=run.start;x<=run.end;x++)assert(closeColor(snapshot.background[x],background),`${label}: old column background was recolored`);
  return run;
}
async function nextTrailTrack(name){
  const selected=tracks().find(track=>track.id===`trail-${name}`),next={id:selected.id,path:selected.path,fingerprint:selected.fingerprint};
  const now=Date.now();state={...state,revision:state.revision+1,track:next,state:'playing',context:{...state.context,playback_source:[next],playback_index:0,queued_tracks:[],play_history:[]},clock:{position_seconds:0,started_at_ms:now,stopped_at_ms:null,updated_at_ms:now}};
  event('playback_state',{playback_state:snapshot()});
  await page.waitForFunction(id=>{const audio=document.querySelector('audio');return audio?.currentSrc.includes(id)&&!audio.paused},selected.fingerprint);
}
async function historyRegression(){
  const red=artworkColors.solidred[0],green=artworkColors.solid[0],blue=artworkColors.solidblue[0];
  await page.evaluate(()=>{window.__spectrumByte=255;window.__historyFrameDelay=60});
  await nextTrailTrack('red');
  await until(async()=>trailRun(await trailPixels(),red).length>=100);
  const before=await trailPixels(),redBackground=before.background.at(-2),redBefore=trailRun(before,red);
  assert(closeColor(before.ink.at(-2),red));
  await nextTrailTrack('green');
  await until(async()=>trailRun(await trailPixels(),green).length>=25);
  let snapshot=await trailPixels();const greenBackground=snapshot.background.at(-2);
  const redAfter=preservedTrail(snapshot,red,redBackground,'Red→green song change',50);
  assert(closeColor(snapshot.ink.at(-2),green),'New columns must use the new green cover');
  assert(redAfter.end<redBefore.end,'Old red columns should scroll left as green arrives');
  assert(Math.abs((redBefore.end-redAfter.end)-(snapshot.samples-before.samples)*snapshot.step)<=snapshot.step*3,'Old columns must translate by the sampled-column displacement');
  report.checks.push({name:'A real red→green track change adds new green columns while red ink and red background move left intact',redBefore,redAfter,newGreen:trailRun(snapshot,green)});
  await page.screenshot({path:path.join(output,'history-red-to-green.png')});

  await page.getByRole('button',{name:'Full screen',exact:true}).tap();await page.getByRole('button',{name:'Exit full screen',exact:true}).waitFor();
  await until(async()=>trailRun(await trailPixels(),green).length>=5);
  snapshot=await trailPixels();preservedTrail(snapshot,red,redBackground,'Fullscreen red history');preservedTrail(snapshot,green,greenBackground,'Fullscreen green history');
  await page.getByRole('button',{name:'Exit full screen',exact:true}).tap();
  await page.getByRole('button',{name:'Full screen',exact:true}).waitFor();
  snapshot=await trailPixels();preservedTrail(snapshot,red,redBackground,'Restored-size red history');preservedTrail(snapshot,green,greenBackground,'Restored-size green history');
  report.checks.push({name:'Fullscreen resize and return preserve every prior column’s ink and background'});

  const loadsBefore=await page.evaluate(()=>window.__media.length),audioBefore=audioRequests;
  await page.getByRole('navigation').getByRole('button',{name:'Home',exact:true}).tap();await page.locator('.home-view').waitFor();
  await page.getByRole('navigation').getByRole('button',{name:'Visualizer',exact:true}).tap();await page.locator('.visualizer-stage canvas').waitFor();
  snapshot=await trailPixels();preservedTrail(snapshot,red,redBackground,'Remounted red history');preservedTrail(snapshot,green,greenBackground,'Remounted green history');
  assert.equal(await page.evaluate(()=>window.__media.length),loadsBefore);assert.equal(audioRequests,audioBefore);
  report.checks.push({name:'Leaving and reopening Visualizer retains mixed history without touching local audio'});

  await page.getByRole('navigation').getByRole('button',{name:'Home',exact:true}).tap();await page.locator('.home-view').waitFor();
  const samplesBefore=await page.evaluate(()=>window.__samples);await nextTrailTrack('blue');
  await until(async()=>await page.evaluate(()=>window.__samples)>=samplesBefore+12);
  await page.getByRole('navigation').getByRole('button',{name:'Visualizer',exact:true}).tap();await page.locator('.visualizer-stage canvas').waitFor();
  snapshot=await trailPixels();preservedTrail(snapshot,red,redBackground,'Offscreen-change red history');preservedTrail(snapshot,green,greenBackground,'Offscreen-change green history');
  assert(trailRun(snapshot,blue).length>=25,'Samples collected on Home must already carry the blue song appearance');
  assert(closeColor(snapshot.ink.at(-2),blue));const blueBackground=snapshot.background.at(-2);
  report.checks.push({name:'A new song while Home is open records its own blue columns before Visualizer remounts'});
  await page.screenshot({path:path.join(output,'history-three-songs.png')});

  const fallback=await themeInk(),mediaBeforeDelay=await page.evaluate(()=>window.__media.length),requestsBeforeDelay=audioRequests;
  trailBlueCover='trail-slow';const reads=libraryReads;event('library',{});
  await until(()=>libraryReads>reads&&historyHeld.length>0);
  await until(async()=>{const current=await trailPixels();return fallback.some(color=>trailRun(current,color).length>=30)});
  snapshot=await trailPixels();const fallbackRGB=snapshot.ink.at(-2),fallbackBackground=snapshot.background.at(-2);
  assert(fallback.some(color=>closeColor(color,fallbackRGB)),'Delayed art must use theme-only colors for new samples');
  preservedTrail(snapshot,blue,blueBackground,'Delayed-art blue history');
  for(const response of historyHeld)art(response,'solid');
  await until(async()=>closeColor((await trailPixels()).ink.at(-2),green));
  snapshot=await trailPixels();preservedTrail(snapshot,fallbackRGB,fallbackBackground,'Resolved-art fallback history',15);preservedTrail(snapshot,blue,blueBackground,'Resolved-art blue history');
  assert.equal(await page.evaluate(()=>window.__media.length),mediaBeforeDelay);assert.equal(audioRequests,requestsBeforeDelay);
  report.checks.push({name:'Delayed artwork adds fallback columns, then green columns; neither old blue nor fallback ink/background is rewritten'});
  await page.screenshot({path:path.join(output,'history-delayed-art.png')});
  await page.evaluate(()=>{window.__historyFrameDelay=0});
}
try{
await page.goto(origin);await page.locator('.mobile-mini-player').waitFor();await page.locator('.mobile-mini-player').getByRole('button',{name:'Play',exact:true}).tap();await page.waitForFunction(()=>document.querySelector('audio')?.paused===false);
await page.getByRole('navigation').getByRole('button',{name:'Visualizer',exact:true}).tap();
await until(async()=> (await pixels()).reads===1);
const canvas=await page.locator('.visualizer-stage canvas').elementHandle();
if(!historyOnly){
const four=await palette(artworkColors.four,4);
report.checks.push({name:'Four rendered bands use the four actual artwork RGB colors without hue synthesis',...four});
await capture('artwork-four-colors.png');const baseline=await pixels();const audioBefore=audioRequests;
await changeCover('red');report.checks.push({name:'Red and blue artwork produces only its three supplied source colors',...await palette(artworkColors.red,3)});
await capture('artwork-red-blue.png');
await changeCover('green');const greenPalette=await palette(artworkColors.green);
const green=await pixels();assert(await canvas.evaluate(n=>n.isConnected));assert(green.audioTime>baseline.audioTime&&!green.paused);assert.equal(green.media,baseline.media);assert.equal(audioRequests,audioBefore);
report.checks.push({name:'Green artwork stays within its green shades and dark source color; recoloring retains canvas and audio',...greenPalette});await capture('artwork-green.png');
const greenReads=green.reads;await page.getByRole('button',{name:/Open Now Playing/}).tap();await page.locator('.atmosphere-layers').waitFor();assert.equal(await page.evaluate(()=>window.__drawReads),greenReads);report.checks.push({name:'Now Playing reuses the same cached artwork extraction',extractions:greenReads});await page.getByRole('button',{name:'Close Now Playing',exact:true}).tap();await page.locator('.native-player-sheet').waitFor({state:'detached'});
await changeCover('solid');const solid=await palette(artworkColors.solid,1);
report.checks.push({name:'Solid green artwork remains a single exact green across every band; no complementary colors',...solid});await capture('artwork-solid-green.png');
await changeCover('gray');const gray=await palette(artworkColors.gray,4);
report.checks.push({name:'Grayscale artwork uses only its actual gray levels and never becomes a rainbow',...gray});await capture('artwork-grayscale.png');
const fallbackColors=await themeInk();
await changeCover(null);const missing=await palette(fallbackColors);
report.checks.push({name:'Missing artwork uses only existing theme accent/text colors',...missing});
await changeCover('broken');await page.waitForTimeout(300);const failed=await palette(fallbackColors);
assert.deepEqual(failed,missing);report.checks.push({name:'Failed artwork uses the same theme-only fallback'});
await changeCover('four');await palette(artworkColors.four,4);
await changeCover('slow');await until(()=>held.length>0);const loading=await palette(fallbackColors);
assert.deepEqual(loading,missing);report.checks.push({name:'Changing to delayed artwork clears the previous song palette immediately'});
await changeCover('solid');await palette(artworkColors.solid,1);
for(const response of held)art(response,'red');await page.waitForTimeout(400);
await palette(artworkColors.solid,1);report.checks.push({name:'A late old artwork response cannot replace the current solid-green colors'});
await changeCover('green');await palette(artworkColors.green);const extractionCount=(await pixels()).reads;
await page.waitForTimeout(650);assert.equal((await pixels()).reads,extractionCount);assert.equal(extractionCount,6);
report.checks.push({name:'No image extraction per frame; all five known artworks are cached and one late response was sampled once',extractions:extractionCount,artRequests});
await page.getByRole('button',{name:'Full screen',exact:true}).tap();await page.getByRole('button',{name:'Exit full screen',exact:true}).waitFor();await palette(artworkColors.green);await page.getByRole('button',{name:'Exit full screen',exact:true}).tap();
report.checks.push({name:'Actual artwork RGB colors survive fullscreen resize'});
}
await historyRegression();
assert.deepEqual(errors,[]);report.passed=true;
}catch(error){report.error=error.stack;await page.screenshot({path:path.join(output,'failure.png')});throw error}
finally{await fs.writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));await browser.close();for(const res of subscribers)res.end();server.closeAllConnections();await new Promise(r=>server.close(r))}
