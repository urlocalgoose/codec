<script lang="ts">
  import QRCode from "qrcode";
  import { Copy, Share2, XCircle } from "lucide-svelte";
  import MobileSheet from "./MobileSheet.svelte";
  import { auxQrPalette } from "$lib/aux-session";
  let { code, link, guestMode, onClose, onEnd }: {code:string;link:string;guestMode:boolean;onClose:()=>void;onEnd:()=>void} = $props();
  let canvas:HTMLCanvasElement | undefined = $state(); let plate:HTMLDivElement | undefined = $state(); let message = $state("");
  let qrPaper = $state("#ffffff");
  $effect(() => {
    if (!canvas || !plate) return;
    const css = getComputedStyle(plate);
    const colors = auxQrPalette(css.getPropertyValue("--color-bg"),css.getPropertyValue("--color-text"));
    qrPaper = colors.light;
    const accent = css.getPropertyValue("--color-accent").trim();
    const symbol = QRCode.create(link,{errorCorrectionLevel:"H"});
    const n = symbol.modules.size, scale = 624/n;
    const ctx = canvas.getContext("2d"); if (!ctx) return;
    canvas.width = canvas.height = 624;
    ctx.fillStyle=colors.light; ctx.fillRect(0,0,624,624);
    let span = Math.max(5,Math.round(n*.21)); if(span%2 !== n%2)span++;
    const start=(n-span)/2;
    ctx.fillStyle=colors.dark;
    for(let y=0;y<n;y++) for(let x=0;x<n;x++) {
      const finder=(x<7&&y<7)||(x>=n-7&&y<7)||(x<7&&y>=n-7);
      const logo=x>=start&&x<start+span&&y>=start&&y<start+span;
      if(!symbol.modules.get(y,x)||finder||logo)continue;
      ctx.beginPath();ctx.arc((x+.5)*scale,(y+.5)*scale,.39*scale,0,Math.PI*2);ctx.fill();
    }
    function rounded(x:number,y:number,w:number,r:number,color:string) { if(!ctx)return;ctx.fillStyle=color;ctx.beginPath();ctx.roundRect(x*scale,y*scale,w*scale,w*scale,r*scale);ctx.fill(); }
    for(const [x,y] of [[0,0],[n-7,0],[0,n-7]]) {
      rounded(x,y,7,2.2,colors.dark);rounded(x+1,y+1,5,1.6,colors.light);rounded(x+2,y+2,3,1.1,colors.dark);
    }
    rounded(start+.35,start+.35,span-.7,(span-.7)*.24,accent);
    ctx.fillStyle=css.getPropertyValue("--button-primary-text").trim();
    ctx.font=`900 ${(span-.7)*scale*.65}px -apple-system, sans-serif`;ctx.textAlign="center";ctx.textBaseline="middle";ctx.fillText("♪",312,312);
  });
  async function copy() { try { await navigator.clipboard.writeText(link); message = "Link copied"; } catch { message = link; } }
  async function share() { if(navigator.share) { try { await navigator.share({ title:"Codec Aux",url:link }); } catch(error) { if (!(error instanceof DOMException && error.name === "AbortError")) await copy(); } } else await copy(); }
</script>
<MobileSheet full title={guestMode ? "Joined Aux" : "Aux Live"} {onClose}>
  <div class="native-aux"><div class="native-aux-code"><div class="native-aux-qr" style:background={qrPaper} bind:this={plate}><canvas bind:this={canvas} aria-label="Scan to join Aux"></canvas></div><strong>{code}</strong><p>{guestMode ? "You're on the aux" : "Scan to join, or enter the code"}</p></div>
  <div class="native-aux-actions"><button class="ui-button primary" type="button" onclick={() => void share()}><Share2 size={18}/>Share Link</button><button class="ui-button" type="button" onclick={() => void copy()}><Copy size={18}/>Copy Link</button><button class="native-aux-end" type="button" onclick={onEnd}><XCircle size={18}/>{guestMode ? "Leave Aux" : "End Aux"}</button>{#if message}<p role="status">{message}</p>{/if}</div></div>
</MobileSheet>
