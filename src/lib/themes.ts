export const themes = [
  { id: "oxide", name: "Oxide", swatch: ["#f47b3f", "#242119", "#f5efe2"] },
  { id: "graphite", name: "Graphite", swatch: ["#9ba3a0", "#151817", "#eef2ed"] },
  { id: "cream", name: "Cream", swatch: ["#c56b35", "#eee0be", "#21190f"] },
  { id: "forest", name: "Forest", swatch: ["#72c28f", "#14291f", "#eef7df"] },
  { id: "ember", name: "Ember", swatch: ["#ff6a3d", "#24130f", "#fff0df"] },
  { id: "denim", name: "Denim", swatch: ["#73a7ff", "#101929", "#eef4ff"] },
  { id: "lagoon", name: "Lagoon", swatch: ["#54d4c5", "#0e2426", "#e8fff9"] },
  { id: "berry", name: "Berry", swatch: ["#f277b5", "#241321", "#fff0f8"] },
  { id: "solar", name: "Solar", swatch: ["#f4c542", "#211c0d", "#fff6d6"] },
  { id: "terminal", name: "Terminal", swatch: ["#7dff8a", "#07130b", "#e9ffe8"] },
  { id: "blueprint", name: "Blueprint", swatch: ["#8bb8ff", "#101728", "#f0f5ff"] },
  { id: "candy", name: "Candy", swatch: ["#ff8ac7", "#231522", "#fff3fb"] },
  { id: "coffee", name: "Coffee", swatch: ["#d19a62", "#1f1712", "#f6e8d4"] },
  { id: "orchid", name: "Orchid", swatch: ["#c79bff", "#1d1528", "#f7efff"] },
  { id: "marine", name: "Marine", swatch: ["#5cc8ff", "#0b1c27", "#eaf8ff"] },
  { id: "moss", name: "Moss", swatch: ["#aac96b", "#172112", "#f3f8df"] },
  { id: "ruby", name: "Ruby", swatch: ["#ff646f", "#251215", "#fff0f0"] },
  { id: "paper", name: "Paper", swatch: ["#2f7d5f", "#eee9dc", "#18140f"] },
  { id: "linen", name: "Linen", swatch: ["#466fd1", "#f6eedf", "#1d1912"] },
  { id: "daylight", name: "Daylight", swatch: ["#b46d1d", "#f7fbfd", "#12202a"] },
  { id: "sage-light", name: "Sage Light", swatch: ["#386e53", "#edf3e7", "#172015"] },
  { id: "blush-light", name: "Blush Light", swatch: ["#b94364", "#fff0f1", "#27181b"] },
  { id: "glacier", name: "Glacier", swatch: ["#18798f", "#eff8fa", "#102027"] },
  { id: "lavender-light", name: "Lavender", swatch: ["#7252b3", "#f4effb", "#20172b"] },
  { id: "peach-light", name: "Peach", swatch: ["#a9572f", "#fff0e1", "#24180f"] },
  { id: "mint-light", name: "Mint", swatch: ["#17826e", "#eff8f3", "#122018"] },
  { id: "mono-light", name: "Mono Light", swatch: ["#4b4c47", "#f0f0ea", "#181815"] },
  { id: "butter", name: "Butter", swatch: ["#2e6971", "#faf1ce", "#1f1a0e"] },
  { id: "noir", name: "Noir", swatch: ["#ded6c4", "#090908", "#f4eee2"] },
  { id: "skyline", name: "Skyline", swatch: ["#ffb45c", "#111b2c", "#eef5ff"] },
  { id: "acid", name: "Acid", swatch: ["#d7ff4a", "#111509", "#f6ffd9"] },
  { id: "mixtape", name: "Mixtape", swatch: ["#ff7f50", "#1b1822", "#f4f0ff"] },
  { id: "icebox", name: "Icebox", swatch: ["#76e2ff", "#102225", "#effcff"] }
] as const;

export type ThemeId = (typeof themes)[number]["id"];
export type ThemeOption = (typeof themes)[number];

export function parseTheme(value: string | null): ThemeId {
  return themes.some((option) => option.id === value) ? (value as ThemeId) : "oxide";
}
