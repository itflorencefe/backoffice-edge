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

export async function verifyAppJwt(req: Request): Promise<VerifyResult> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) {
    return { ok: false, status: 401, message: "Missing bearer token" };
  }
  const rawToken = auth.slice(7).trim();
  try {
    const key = await importKey();
    const payload = await jwtVerify(rawToken, key) as unknown as AppClaims;
    if (payload.app_role !== "app_user") {
      return { ok: false, status: 403, message: "Not an app_user token" };
    }
    return { ok: true, claims: payload, rawToken };
  } catch (err) {
    return { ok: false, status: 401, message: err instanceof Error ? err.message : "Invalid token" };
  }
}
