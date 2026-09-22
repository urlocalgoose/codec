import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Usage: PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node scripts/web-playback-regression.mjs [build-dir] [report.json]
// All music, credentials, and API responses are isolated fixtures.
const moduleName = process.env.PLAYWRIGHT_MODULE ?? 'playwright';
const moduleURL = moduleName.startsWith('/') || moduleName.startsWith('.') ? pathToFileURL(path.resolve(moduleName)).href : moduleName;
const { chromium } = await import(moduleURL);

const build = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '../build'));
const output = process.argv[3] ?? '/tmp/codec-web-playback-regression.json';
const sampleRate=22050, seconds=90, wave=Buffer.alloc(44+sampleRate*seconds*2);
wave.write('RIFF');wave.writeUInt32LE(wave.length-8,4);wave.write('WAVEfmt ',8);wave.writeUInt32LE(16,16);
wave.writeUInt16LE(1,20);wave.writeUInt16LE(1,22);wave.writeUInt32LE(sampleRate,24);wave.writeUInt32LE(sampleRate*2,28);wave.writeUInt16LE(2,32);wave.writeUInt16LE(16,34);wave.write('data',36);wave.writeUInt32LE(wave.length-44,40);
for(let i=0;i<sampleRate*seconds;i++)wave.writeInt16LE(Math.round(Math.sin(i*2*Math.PI*220/sampleRate)*500),44+i*2);
let origin, tokens=0, audioRequests=0, reads=0;
const subscribers=new Set();
const track={id:'fixture-song',path:'loud://track/fixture-song',file_name:'fixture.wav',title:'Continuity test',artist:'Local generated audio',album:'Isolated test',duration_seconds:seconds,artwork_url:null,playlist_ids:[],is_liked:false,fingerprint:'fixture-song',added_at:1700000000,size_bytes:wave.length};
const ref={id:track.id,path:track.path,fingerprint:track.fingerprint};
const library={root_path:'loud://fixture',scanned_at:1700000000,tracks:[track],playlists:[],artists:[],albums:[],stats:{trackCount:1,playlistCount:0,likedCount:0,artistCount:1,albumCount:1,durationSeconds:seconds}};
let state={schema:'loud.playback.v2',revision:1,active_device_id:'probe-browser',state:'playing',track:ref,context:{playback_source:[ref],playback_index:0,queued_tracks:[],play_history:[],shuffle:false,repeat:'off'},clock:{position_seconds:10,started_at_ms:Date.now(),updated_at_ms:Date.now()},volume:0,server_time_ms:Date.now()};
const snapshot=()=>({...state,server_time_ms:Date.now()});
function sendState(){for(const res of subscribers)res.write(`event: playback_state\ndata: ${JSON.stringify({type:'playback_state',playback_state:snapshot()})}\n\n`)}
const server=http.createServer(async(req,res)=>{
 try{
 const url=new URL(req.url,origin??'http://127.0.0.1');
 const json=(value,status=200)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
 if(url.pathname==='/health')return json({ok:true,schema:'loud.sync.v1',playback_schema:'loud.playback.v2',server_id:'isolated-continuity'});
 if(url.pathname==='/api/v1/library')return json(library);
 if(url.pathname==='/api/v1/auth/stream-token')return json({token:`stream_fixture_${++tokens}`,expires_at:Math.floor(Date.now()/1000)+900},201);
 if(url.pathname==='/api/v2/playback/events'){
  res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache','Connection':'keep-alive'});res.write(': fixture\n\n');subscribers.add(res);req.on('close',()=>subscribers.delete(res));return;
 }
 if(url.pathname==='/api/v2/playback'){reads++;return json(snapshot());}
 if(url.pathname.includes('/audio')){
  audioRequests++;
  let start=0,end=wave.length-1;
  const range=/bytes=(\d+)-(\d*)/.exec(req.headers.range??'');
  if(range){start=Number(range[1]);if(range[2])end=Math.min(Number(range[2]),end);}
  const headers={'Content-Type':'audio/wav','Accept-Ranges':'bytes','Cache-Control':'no-store','Content-Length':end-start+1};
  if(range)headers['Content-Range']=`bytes ${start}-${end}/${wave.length}`;
  res.writeHead(range?206:200,headers);res.end(wave.subarray(start,end+1));return;
 }
 if(url.pathname.includes('/playback/devices'))return json(req.method==='GET'?[{device_id:'probe-browser',name:'Isolated browser',updated_at:Date.now()}]:{});
 if(url.pathname==='/api/v2/playback/commands'){
  let body='';for await(const chunk of req)body+=chunk;
  const command=JSON.parse(body);
  if(command.kind==='pause')state={...state,revision:state.revision+1,state:'paused',clock:{...state.clock,position_seconds:command.position_seconds??0,started_at_ms:null,updated_at_ms:Date.now()}};
  return json(snapshot());
 }
 if(url.pathname.startsWith('/api/'))return json([]);
 const name=path.resolve(build,'.'+(url.pathname==='/'?'/index.html':decodeURIComponent(url.pathname)));
 if(!name.startsWith(build+path.sep)){res.writeHead(403).end();return;}
 const data=await fs.readFile(name);
 res.writeHead(200,{'Content-Type':({'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ttf':'font/ttf','.woff2':'font/woff2'})[path.extname(name)]??'application/octet-stream'});res.end(data);
 }catch(error){res.writeHead(404).end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_BROWSER_PATH,args:['--autoplay-policy=no-user-gesture-required']});
const context=await browser.newContext({viewport:{width:1280,height:900},serviceWorkers:'block'});
const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
await context.addInitScript(()=>{
 localStorage.setItem('codec.syncServer',location.origin);localStorage.setItem('codec.syncToken','fixture-token');localStorage.setItem('codec.deviceId','probe-browser');
 window.__media=[];window.__polls=[];window.__samples=0;window.__graphs=[];window.__hidden=false;
 Object.defineProperty(document,'hidden',{configurable:true,get:()=>window.__hidden});
 Object.defineProperty(document,'visibilityState',{configurable:true,get:()=>window.__hidden?'hidden':'visible'});
 const OriginalContext=window.AudioContext;
 window.AudioContext=new Proxy(OriginalContext,{construct(target,args){const context=Reflect.construct(target,args);window.__graphs.push(context);return context;}});
 const originalFrequency=AnalyserNode.prototype.getByteFrequencyData;
 AnalyserNode.prototype.getByteFrequencyData=function(...args){window.__samples++;return originalFrequency.apply(this,args);};
 const proto=HTMLMediaElement.prototype;
 for(const name of ['load','play','pause']){const original=proto[name];proto[name]=function(...args){if(name==='play')this.muted=true;window.__media.push({op:name,t:performance.now(),time:this.currentTime});return original.apply(this,args);};}
 const descriptor=Object.getOwnPropertyDescriptor(proto,'currentTime');
 Object.defineProperty(proto,'currentTime',{...descriptor,set(value){window.__media.push({op:'seek',t:performance.now(),from:descriptor.get.call(this),to:value});descriptor.set.call(this,value);}});
 const interval=window.setInterval;
 window.setInterval=function(fn,delay,...args){if(delay===30000)window.__polls.push(()=>fn(...args));return interval(fn,delay,...args);};
 for(const name of ['loadstart','emptied','waiting','stalled','playing','seeking','seeked','error'])document.addEventListener(name,event=>{if(event.target instanceof HTMLMediaElement)window.__media.push({op:'event:'+name,t:performance.now(),time:event.target.currentTime,ready:event.target.readyState});},true);
});
const report={build,errors,phases:[]};
async function capture(name){report.phases.push({name,tokens,audioRequests,reads,...await page.evaluate(()=>({calls:[...window.__media],time:document.querySelector('audio')?.currentTime,paused:document.querySelector('audio')?.paused,polls:window.__polls.length}))});}
try{
 await page.goto(origin);await page.waitForFunction(()=>document.querySelector('audio')?.currentTime>10&&document.querySelector('audio')?.paused===false,null,{timeout:10000});
 await page.waitForTimeout(350);await capture('initial');
 await page.evaluate(()=>window.__media=[]);
 for(let i=0;i<3;i++){await page.evaluate(()=>window.__polls.forEach(fn=>fn()));await page.waitForTimeout(450);}
 await capture('three routine polls');
 // Simulate decoder startup/buffering lag, then a context-only revision.
 await page.evaluate(()=>{document.querySelector('audio').currentTime-=2;});
 await page.waitForFunction(()=>!document.querySelector('audio').seeking&&document.querySelector('audio').readyState>=3);
 await page.waitForTimeout(80);await page.evaluate(()=>window.__media=[]);
 const now=Date.now();state={...state,revision:state.revision+1,context:{...state.context,shuffle:true},clock:{position_seconds:state.clock.position_seconds+(now-state.clock.started_at_ms)/1000,started_at_ms:now,updated_at_ms:now}};sendState();
 await page.waitForTimeout(450);await capture('context-only revision with 2s local lag');
 await page.evaluate(()=>{window.__media=[];window.__polls.forEach(fn=>fn());});
 await page.waitForTimeout(450);await capture('first poll after new revision');
 await page.evaluate(()=>window.__media=[]);
 const seekAt=Date.now();state={...state,revision:state.revision+1,clock:{position_seconds:45,started_at_ms:seekAt,updated_at_ms:seekAt}};sendState();
 await page.waitForTimeout(450);await capture('intentional remote seek to45s');
 await fs.writeFile(output,JSON.stringify(report,null,2));
 console.log(JSON.stringify(report.phases.map(p=>({name:p.name,tokens:p.tokens,audioRequests:p.audioRequests,reads:p.reads,polls:p.polls,time:p.time,paused:p.paused,load:p.calls.filter(c=>c.op==='load').length,seeks:p.calls.filter(c=>c.op==='seek').length,empty:p.calls.filter(c=>c.op==='event:emptied').length,wait:p.calls.filter(c=>c.op==='event:waiting').length})),null,2));
 console.log('browserErrors:',JSON.stringify(errors));
 assert.equal(errors.length,0,'The browser must not throw during playback');
 for(const phase of report.phases.slice(1,-1)){
  assert.equal(phase.calls.filter(call=>['load','seek','pause','event:emptied','event:waiting'].includes(call.op)).length,0,`${phase.name} must preserve ongoing audio`);
  assert.equal(phase.audioRequests,report.phases[0].audioRequests,`${phase.name} must not fetch audio again`);
  assert.equal(phase.paused,false,`${phase.name} must keep playing`);
 }
 const seek=report.phases.at(-1);
 assert.equal(seek.calls.filter(call=>call.op==='load').length,0,'A seek within buffered audio must not reload the source');
 assert.equal(seek.calls.filter(call=>call.op==='seek').length,1,'Intentional remote seeks must still apply once');
 assert(seek.time>=45&&seek.time<48,'The real media element must reach the requested seek position');
 // The sampler retains history while browsing, but hidden/remote clients
 // should do no FFT work and must not interrupt local audio.
 await page.getByRole('button',{name:'Visualizer',exact:true}).click();
 await page.waitForFunction(()=>window.__samples>2);
 await page.evaluate(()=>{window.__hidden=true;document.dispatchEvent(new Event('visibilitychange'));});
 await page.waitForTimeout(60);
 const hidden=await page.evaluate(()=>({samples:window.__samples,time:document.querySelector('audio').currentTime,graph:window.__graphs[0]?.state}));
 await page.waitForTimeout(150);
 const hiddenAfter=await page.evaluate(()=>({samples:window.__samples,time:document.querySelector('audio').currentTime,paused:document.querySelector('audio').paused,graph:window.__graphs[0]?.state}));
 assert.equal(hiddenAfter.samples,hidden.samples,'Hidden tabs must stop FFT sampling');
 assert.equal(hiddenAfter.paused,false,'Hiding the tab must not pause local music');
 assert.equal(hiddenAfter.graph,'running','Hidden local audio still needs its running output context');
 assert(hiddenAfter.time>hidden.time,'Real audio must continue advancing while the tab is hidden');
 await page.evaluate(()=>{window.__hidden=false;document.dispatchEvent(new Event('visibilitychange'));});
 await page.waitForFunction(samples=>window.__samples>samples,hidden.samples);
 state={...state,revision:state.revision+1,active_device_id:'native-fixture'};sendState();
 await page.waitForFunction(()=>document.querySelector('audio').paused&&window.__graphs[0]?.state==='suspended');
 const remoteSamples=await page.evaluate(()=>window.__samples);
 await page.waitForTimeout(120);
 assert.equal(await page.evaluate(()=>window.__samples),remoteSamples,'Remote owners must stop local sampling');
 state={...state,revision:state.revision+1,active_device_id:'probe-browser'};sendState();
 await page.waitForFunction(samples=>!document.querySelector('audio').paused&&window.__graphs[0]?.state==='running'&&window.__samples>samples,remoteSamples);
 report.visualizer={hiddenSamplingStopped:true,hiddenAudioContinued:true,remoteGraphSuspended:true,remoteSamplingStopped:true,localTransferResumed:true};
 await fs.writeFile(output,JSON.stringify(report,null,2));
 console.log('visualizerLifecycle:',JSON.stringify(report.visualizer));
}finally{await browser.close();for(const res of subscribers)res.end();await new Promise(resolve=>server.close(resolve));}
