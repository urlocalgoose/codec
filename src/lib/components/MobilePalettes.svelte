<script lang="ts">
  import { Check, Music2, Play } from "lucide-svelte";
  import { themes, type ThemeId } from "$lib/themes";
  import MobileSheet from "./MobileSheet.svelte";
  let { theme, onSetTheme, onClose }: { theme:ThemeId; onSetTheme:(id:ThemeId)=>void; onClose:()=>void } = $props();
  const light = new Set(["paper","linen","daylight","sage-light","blush-light","glacier","lavender-light","peach-light","mint-light","mono-light","butter"]);
</script>
<MobileSheet full title="Palettes" {onClose}>
  <div class="native-palettes">{#each ["Dark", "Light"] as section}
    {@const options = themes.filter(option => light.has(option.id) === (section === "Light"))}
    <section><h3>{section}<span>{options.length}</span></h3><div class="native-palette-grid">
      {#each options as option}<button class="native-palette" class:selected={theme === option.id} data-theme={option.id} type="button" aria-label={option.name} aria-pressed={theme === option.id} onclick={() => onSetTheme(option.id)}>
        <span class="native-palette-title">{option.name}<i>{#if theme === option.id}<Check size={12} strokeWidth={3}/>{/if}</i></span>
        <span class="native-palette-preview"><span class="native-palette-art"><Music2 size={17}/></span><span class="native-palette-lines"><i></i><i></i></span><Play size={13} fill="currentColor"/></span>
      </button>{/each}
    </div></section>
  {/each}</div>
</MobileSheet>
