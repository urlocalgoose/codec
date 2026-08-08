import { describe, expect, test } from "bun:test";
import {
  base64UrlDecode,
  base64UrlEncode,
  canonicalRequest,
  canonicalSearch,
  cleanDeviceId,
  sha256Base64Url,
  timestampIsFresh,
  verifyDeviceSignature
} from "./src/security.mjs";

describe("secure sync request signing", () => {
  test("base64url round trips bytes without padding", () => {
    const encoded = base64UrlEncode(new Uint8Array([1, 2, 3, 252, 253, 254]));
    expect(encoded.includes("=")).toBe(false);
    expect(Array.from(base64UrlDecode(encoded))).toEqual([1, 2, 3, 252, 253, 254]);
  });

  test("canonical requests sort query params and bind body hash", async () => {
    const url = new URL("https://codec.example.com/api/v3/library?z=2&a=2&a=1");
    const bodyHash = await sha256Base64Url("body");
    expect(canonicalSearch(url)).toBe("?a=1&a=2&z=2");
    expect(
      canonicalRequest({
        method: "post",
        url,
        timestamp: 123,
        nonce: "nonce",
        bodyHash
      })
    ).toBe(`POST\n/api/v3/library\n?a=1&a=2&z=2\n123\nnonce\n${bodyHash}`);
  });

  test("verifies a P-256 device signature", async () => {
    const keyPair = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"]
    );
    const publicKeyJwk = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
    const message = "GET\n/api/v3/library\n\n123\nnonce\nhash";
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      keyPair.privateKey,
      new TextEncoder().encode(message)
    );

    await expect(
      verifyDeviceSignature({
        publicKeyJwk,
        signature: base64UrlEncode(signature),
        message
      })
    ).resolves.toBe(true);
  });

  test("cleans device ids and checks timestamp windows", () => {
    expect(cleanDeviceId(" phone 1 / weird ")).toBe("phone_1___weird");
    expect(timestampIsFresh(1_000, 1_200, 500)).toBe(true);
    expect(timestampIsFresh(1_000, 2_000, 500)).toBe(false);
  });
});

