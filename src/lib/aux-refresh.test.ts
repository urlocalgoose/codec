import { expect, test } from "bun:test";

const source = await Bun.file(new URL("./components/AuxWorkspace.svelte", import.meta.url).pathname).text();
const start = source.indexOf("  async function refresh() {");
const refresh = source.slice(start, source.indexOf("\n  async function command(", start));

function controller(request: () => Promise<unknown>) {
  const code = `
    let stopped=false, unavailable=false, pollController=null, refreshPending=false, pollTimer;
    let events={readyState:1}, error="", scheduled=[], applied=[];
    const document={hidden:false}, connection={server:"https://aux.example",token:"guest"};
    const auxPath=()=>"/api/v2/aux/sessions/session";
    const clearTimeout=()=>{}, setTimeout=(run,delay)=>{scheduled.push({run,delay});return scheduled.length};
    const showError=()=>{}, sessionGone=()=>false;
    const apply=(value)=>applied.push(value);
    ${refresh}
    return {refresh,scheduled,applied,disconnect(){stopped=true;pollController?.abort()}};
  `;
  return new Function("auxRequest", new Bun.Transpiler({loader:"ts"}).transformSync(code))(request);
}

test("Aux invalidations arriving during a state read coalesce into an immediate follow-up", async () => {
  let resolve!: (value:unknown)=>void;
  let requests=0;
  const c=controller(()=>{requests++;return requests===1?new Promise(done=>resolve=done):Promise.resolve({revision:2});});
  const pending=c.refresh();
  await c.refresh();await c.refresh();
  expect(requests).toBe(1);
  resolve({revision:1});await pending;
  expect(c.scheduled.map((item:{delay:number})=>item.delay)).toEqual([0]);
  await c.scheduled.shift().run();
  expect(requests).toBe(2);
  expect(c.applied).toEqual([{revision:1},{revision:2}]);
  expect(c.scheduled.map((item:{delay:number})=>item.delay)).toEqual([20000]);
});

test("Leaving Aux cancels its outstanding read without applying or scheduling stale state", async () => {
  let resolve!: (value:unknown)=>void;
  const c=controller(()=>new Promise(done=>resolve=done));
  const pending=c.refresh();await c.refresh();c.disconnect();resolve({revision:5});await pending;
  expect(c.applied).toEqual([]);expect(c.scheduled).toEqual([]);
});
