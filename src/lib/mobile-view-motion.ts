type MobileView = { view: string; tab: string; enabled: boolean };

// Animate the existing scroll container. Re-keying the page would discard
// scroll/virtual-list state and could remount the player during navigation.
export function mobileViewMotion(node: HTMLElement, initial: MobileView) {
  let previous = initial;
  let animation: Animation | undefined;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const stop = () => { animation?.cancel(); animation = undefined; };
  reducedMotion.addEventListener("change", stop);
  return {
    update(next: MobileView) {
      const last = previous;
      previous = next;
      if (last.view === next.view && last.tab === next.tab) return;
      stop();
      if (!next.enabled || reducedMotion.matches) return;
      const switchingTabs = last.tab !== next.tab;
      const returning = next.view === next.tab;
      const distance = switchingTabs || next.view === "visualizer" ? 0 : returning ? -28 : 40;
      animation = node.animate([
        { opacity: switchingTabs ? .55 : .4, transform: `translateX(${distance}px)` },
        { opacity: 1, transform: "translateX(0)" }
      ], { duration: switchingTabs ? 170 : 260, easing: "cubic-bezier(.2,0,0,1)" });
    },
    destroy() { stop(); reducedMotion.removeEventListener("change", stop); }
  };
}
