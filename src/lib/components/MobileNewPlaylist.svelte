<script lang="ts">
 import { onMount } from "svelte";
 import { cubicOut } from "svelte/easing";
 import { scale, type TransitionConfig } from "svelte/transition";
 let { name=$bindable(), busy, error, onClose, onCreate }: {name:string;busy:boolean;error:string;onClose:()=>void;onCreate:()=>void}=$props();
 let dialog:HTMLDialogElement; let input:HTMLInputElement;
 let presented=$state(false); let leaving=$state(false);
 function alertMotion(node:HTMLDialogElement,{duration}:{duration:number}):TransitionConfig {
  return scale(node,{start:.96,duration:matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : duration,easing:cubicOut});
 }
 onMount(()=>{
  const trigger=document.activeElement as HTMLElement|null;
  dialog.showModal();input.focus({preventScroll:true});
  let frame=requestAnimationFrame(()=>{frame=requestAnimationFrame(()=>{presented=true;});});
  return()=>{cancelAnimationFrame(frame);dialog.close();if(trigger?.isConnected)trigger.focus({preventScroll:true});};
 });
</script>
<dialog class="native-alert" class:sheet-presented={presented} class:sheet-leaving={leaving} bind:this={dialog} in:alertMotion={{duration:200}} out:alertMotion={{duration:140}} onoutrostart={()=>{leaving=true;}} aria-labelledby="new-playlist-title" oncancel={(event)=>{event.preventDefault();if(!busy)onClose();}}>
 <form onsubmit={(event)=>{event.preventDefault();onCreate();}}>
  <div class="native-alert-body"><h2 id="new-playlist-title">New Playlist</h2><input bind:this={input} bind:value={name} aria-label="Playlist name" placeholder="Name" maxlength="96" disabled={busy}/>{#if error}<p role="alert">{error}</p>{/if}</div>
  <div class="native-alert-actions"><button type="button" disabled={busy} onclick={onClose}>Cancel</button><button type="submit" disabled={busy || !name.trim()}>{busy ? "Creating…" : "Create"}</button></div>
 </form>
</dialog>
