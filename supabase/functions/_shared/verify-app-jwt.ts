import { verify as jwtVerify } from "jsr:@zaubrik/djwt@3.0.2";

export interface AppClaims {
  sub: string;
  service_id: string;
  service_slug: string;
  product_id: string;
  product_slug: string;
  app_role: string;
  absolute_reference: string;
  role: string;
  iat: number;
  exp: number;
}

type VerifyResult =
  | { ok: true; claims: AppClaims; rawToken: string }
  | { ok: false; status: number; message: string };

async function importKey(): Promise<CryptoKey> {
  const secret = Deno.env.get("APP_JWT_SECRET") ?? Deno.env.get("SUPABASE_JWT_SECRET");
  if (!secret) throw new Error("JWT secret not configured");
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function claimString(
  payload: Record<string, unknown>,
  meta: Record<string, unknown>,
  key: string,
): string {
  const top = payload[key];
  if (typeof top === "string" && top) return top;
  const nested = meta[key];
  return typeof nested === "string" ? nested : "";
}

/** Normalize flat production JWTs and local session tokens that nest claims in app_metadata. */
export function normalizeAppClaims(raw: Record<string, unknown>): AppClaims | null {
  const meta = asRecord(raw.app_metadata);
  const sub = claimString(raw, meta, "sub") || (typeof raw.sub === "string" ? raw.sub : "");
  const app_role = claimString(raw, meta, "app_role");
  if (!sub || app_role !== "app_user") return null;

  return {
    sub,
    service_id: claimString(raw, meta, "service_id"),
    service_slug: claimString(raw, meta, "service_slug"),
    product_id: claimString(raw, meta, "product_id"),
    product_slug: claimString(raw, meta, "product_slug"),
    app_role,
    absolute_reference: claimString(raw, meta, "absolute_reference"),
    role: claimString(raw, meta, "role") || "authenticated",
    iat: typeof raw.iat === "number" ? raw.iat : 0,
    exp: typeof raw.exp === "number" ? raw.exp : 0,
  };
}

export async function verifyAppJwt(req: Request): Promise<VerifyResult> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) {
    return { ok: false, status: 401, message: "Missing bearer token" };
  }
  const rawToken = auth.slice(7).trim();
  try {
    const key = await importKey();
    const payload = await jwtVerify(rawToken, key) as unknown as Record<string, unknown>;
    const claims = normalizeAppClaims(payload);
    if (!claims) {
      return { ok: false, status: 403, message: "Not an app_user token" };
    }
    return { ok: true, claims, rawToken };
  } catch (err) {
    return { ok: false, status: 401, message: err instanceof Error ? err.message : "Invalid token" };
  }
}
