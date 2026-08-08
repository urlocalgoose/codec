const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const FIVE_MINUTES_MS = 5 * 60 * 1000;

let accessJwksCache = null;

export function base64UrlEncode(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function base64UrlDecode(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

export async function sha256Base64Url(value) {
  const bytes = typeof value === "string" ? textEncoder.encode(value) : new Uint8Array(value ?? new Uint8Array());
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return base64UrlEncode(digest);
}

export function canonicalSearch(url) {
  const pairs = Array.from(url.searchParams.entries()).sort(([leftKey, leftValue], [rightKey, rightValue]) => {
    const keyOrder = leftKey.localeCompare(rightKey);
    return keyOrder === 0 ? leftValue.localeCompare(rightValue) : keyOrder;
  });
  const params = new URLSearchParams();
  for (const [key, value] of pairs) {
    params.append(key, value);
  }
  const serialized = params.toString();
  return serialized ? `?${serialized}` : "";
}

export function canonicalRequest({ method, url, timestamp, nonce, bodyHash }) {
  const parsed = url instanceof URL ? url : new URL(url);
  return [
    method.toUpperCase(),
    parsed.pathname,
    canonicalSearch(parsed),
    String(timestamp),
    nonce,
    bodyHash
  ].join("\n");
}

export async function verifyDeviceSignature({ publicKeyJwk, signature, message }) {
  const key = await crypto.subtle.importKey(
    "jwk",
    publicKeyJwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"]
  );
  return crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    base64UrlDecode(signature),
    textEncoder.encode(message)
  );
}

export function cleanDeviceId(value) {
  return String(value ?? "")
    .trim()
    .replace(/[^A-Za-z0-9._:-]/g, "_")
    .slice(0, 96);
}

export function cleanFingerprint(value) {
  return String(value ?? "")
    .trim()
    .replace(/[^A-Za-z0-9._:-]/g, "_")
    .slice(0, 160);
}

export function timestampIsFresh(timestamp, now = Date.now(), windowMs = FIVE_MINUTES_MS) {
  const parsed = Number(timestamp);
  return Number.isFinite(parsed) && Math.abs(now - parsed) <= windowMs;
}

export async function parseJsonBody(bytes) {
  if (!bytes || bytes.byteLength === 0) {
    return {};
  }
  return JSON.parse(textDecoder.decode(bytes));
}

export async function verifyAccessJwt(request, env) {
  const jwt = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!jwt) {
    throw httpError(401, "Cloudflare Access token is required.");
  }
  if (!env.CF_ACCESS_JWKS_URL || !env.CF_ACCESS_AUD) {
    throw httpError(500, "Cloudflare Access verification is not configured.");
  }

  const [encodedHeader, encodedPayload, encodedSignature] = jwt.split(".");
  if (!encodedHeader || !encodedPayload || !encodedSignature) {
    throw httpError(401, "Cloudflare Access token is malformed.");
  }

  const header = JSON.parse(textDecoder.decode(base64UrlDecode(encodedHeader)));
  const payload = JSON.parse(textDecoder.decode(base64UrlDecode(encodedPayload)));
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (payload.exp && nowSeconds >= Number(payload.exp)) {
    throw httpError(401, "Cloudflare Access token expired.");
  }
  if (payload.nbf && nowSeconds < Number(payload.nbf)) {
    throw httpError(401, "Cloudflare Access token is not active yet.");
  }
  if (env.CF_ACCESS_ISSUER && payload.iss !== env.CF_ACCESS_ISSUER) {
    throw httpError(401, "Cloudflare Access token issuer is not allowed.");
  }

  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!audiences.includes(env.CF_ACCESS_AUD)) {
    throw httpError(401, "Cloudflare Access token audience is not allowed.");
  }

  const jwks = await accessJwks(env.CF_ACCESS_JWKS_URL);
  const jwk = jwks.keys.find((key) => key.kid === header.kid);
  if (!jwk) {
    throw httpError(401, "Cloudflare Access signing key was not found.");
  }

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    base64UrlDecode(encodedSignature),
    textEncoder.encode(`${encodedHeader}.${encodedPayload}`)
  );
  if (!ok) {
    throw httpError(401, "Cloudflare Access token signature is invalid.");
  }

  const email = String(payload.email ?? request.headers.get("Cf-Access-Authenticated-User-Email") ?? "").trim();
  const allowedEmails = allowedAccessEmails(env);
  if (allowedEmails.length > 0 && !allowedEmails.includes(email.toLowerCase())) {
    throw httpError(403, "Cloudflare Access user is not allowed.");
  }

  return {
    email,
    subject: String(payload.sub ?? ""),
    payload
  };
}

async function accessJwks(jwksUrl) {
  if (accessJwksCache && accessJwksCache.expiresAt > Date.now()) {
    return accessJwksCache.jwks;
  }
  const response = await fetch(jwksUrl);
  if (!response.ok) {
    throw httpError(500, "Could not load Cloudflare Access signing keys.");
  }
  const jwks = await response.json();
  accessJwksCache = {
    jwks,
    expiresAt: Date.now() + 10 * 60 * 1000
  };
  return jwks;
}

function allowedAccessEmails(env) {
  return String(env.ALLOWED_ACCESS_EMAILS ?? "")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
}

export function httpError(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

