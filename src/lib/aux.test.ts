import { describe, expect, test } from "bun:test";
import { auxQrPalette } from "./aux";

describe("auxQrPalette", () => {
  test("dark theme: light text becomes paper, dark bg becomes ink", () => {
    expect(auxQrPalette("#242119", "#f5efe2")).toEqual({ dark: "#242119", light: "#f5efe2" });
  });

  test("light theme: light bg becomes paper, dark text becomes ink", () => {
    expect(auxQrPalette("#eee9dc", "#18140f")).toEqual({ dark: "#18140f", light: "#eee9dc" });
  });

  test("unparseable colors fall back to black on white", () => {
    expect(auxQrPalette("var(--nope)", "#18140f")).toEqual({ dark: "#000000", light: "#ffffff" });
    expect(auxQrPalette("rgb(20, 20, 20)", "white")).toEqual({ dark: "#000000", light: "#ffffff" });
  });
});
