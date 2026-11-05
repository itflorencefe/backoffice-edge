import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import { verify as jwtVerify } from "jsr:@zaubrik/djwt@3.0.2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

const TAG = "[app-profile]";

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

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

interface AppClaims {
  sub: string;
  service_id: string;
  service_slug: string;
  product_id: string;
  product_slug: string;
  app_role: string;
}

async function verifyAppJwt(req: Request): Promise<
  { ok: true; claims: AppClaims; rawToken: string } | { ok: false; status: number; message: string }
> {
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

function createUserClient(jwt: string) {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    {
      auth: { autoRefreshToken: false, persistSession: false },
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    },
  );
}

function createAdminClient() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: { message: "Method not allowed" } }, 405);

  const auth = await verifyAppJwt(req);
  if (!auth.ok) {
    console.log(`${TAG} ${ts} | auth failed:`, auth.message);
    return json({ ok: false, error: { message: auth.message } }, auth.status);
  }
  const { claims, rawToken } = auth;
  const supabase = createUserClient(rawToken);

  let body: { command?: string; payload?: Record<string, unknown> };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: { message: "Invalid JSON" } }, 400);
  }

  try {
    switch (body.command) {
      case "get": {
        const { data, error } = await supabase
          .from("profiles")
          .select("id, nickname, avatar_url, total_points, points_this_week, onboarding_completed, preferences, avatar_traits, badge_name, service_id, product_id")
          .maybeSingle();
        if (error) return json({ ok: false, error: { message: error.message } }, 500);
        if (!data) return json({ ok: false, error: { message: "Profile not found" } }, 404);
        return json({ ok: true, data }, 200);
      }

      case "update": {
        const allowed = ["nickname", "preferences", "avatar_traits", "onboarding_completed"] as const;
        const patch: Record<string, unknown> = {};
        for (const k of allowed) {
          if (body.payload && k in body.payload) patch[k] = body.payload[k];
        }
        if (Object.keys(patch).length === 0) {
          return json({ ok: false, error: { message: "No allowed fields in payload" } }, 400);
        }
        patch.updated_at = new Date().toISOString();
        const { data, error } = await supabase
          .from("profiles")
          .update(patch)
          .select()
          .maybeSingle();
        if (error) return json({ ok: false, error: { message: error.message } }, 500);
        return json({ ok: true, data }, 200);
      }

      case "setAvatar": {
        const admin = createAdminClient();
        const ext = String((body.payload?.ext ?? "png")).toLowerCase().replace(/[^a-z0-9]/g, "");
        if (!["png", "jpg", "jpeg", "webp"].includes(ext)) {
          return json({ ok: false, error: { message: "Unsupported ext" } }, 400);
        }
        const path = `${claims.service_slug}/${claims.product_slug}/${claims.sub}/avatar.${ext}`;
        const { data, error } = await admin.storage
          .from("avatars")
          .createSignedUploadUrl(path, { upsert: true });
        if (error) return json({ ok: false, error: { message: error.message } }, 500);
        return json({ ok: true, data: { path, signed_url: data.signedUrl, token: data.token } }, 200);
      }

      case "confirmAvatar": {
        const admin = createAdminClient();
        const path = String(body.payload?.path ?? "");
        if (!path.startsWith(`${claims.service_slug}/${claims.product_slug}/${claims.sub}/`)) {
          return json({ ok: false, error: { message: "Invalid path" } }, 400);
        }
        const { data: pub } = admin.storage.from("avatars").getPublicUrl(path);
        const { error } = await supabase
          .from("profiles")
          .update({ avatar_url: pub.publicUrl, updated_at: new Date().toISOString() })
          .select()
          .maybeSingle();
        if (error) return json({ ok: false, error: { message: error.message } }, 500);
        return json({ ok: true, data: { avatar_url: pub.publicUrl } }, 200);
      }

      default:
        return json({ ok: false, error: { message: `Unknown command: ${body.command}` } }, 400);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : "Request failed";
    console.error(`${TAG} ${ts} | error:`, message);
    return json({ ok: false, error: { message } }, 500);
  }
});
