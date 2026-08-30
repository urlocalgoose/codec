/** QR ink/paper for the aux pass: the theme's bg and text colors, lighter one
 * as paper, so the code stays scannable while still reading as themed. */
export function auxQrPalette(bgColor: string, textColor: string): { dark: string; light: string } {
  const bg = hexLuminance(bgColor);
  const text = hexLuminance(textColor);
  if (bg === null || text === null) {
    return { dark: "#000000", light: "#ffffff" };
  }
  return bg > text ? { dark: textColor, light: bgColor } : { dark: bgColor, light: textColor };
}

function hexLuminance(color: string): number | null {
  const match = /^#([0-9a-f]{6})$/i.exec(color.trim());
  if (!match) {
    return null;
  }
  const value = parseInt(match[1], 16);
  const r = (value >> 16) & 0xff;
  const g = (value >> 8) & 0xff;
  const b = value & 0xff;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
