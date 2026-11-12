import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import { verify as jwtVerify } from "jsr:@zaubrik/djwt@3.0.2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

const TAG = "[app-account-delete]";

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

Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: { message: "Method not allowed" } }, 405);

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) {
    return json({ ok: false, error: { message: "Missing bearer token" } }, 401);
  }

  let claims: AppClaims;
  try {
    const key = await importKey();
    claims = await jwtVerify(auth.slice(7).trim(), key) as unknown as AppClaims;
  } catch (err) {
    return json({ ok: false, error: { message: err instanceof Error ? err.message : "Invalid token" } }, 401);
  }
  if (claims.app_role !== "app_user") {
    return json({ ok: false, error: { message: "Not an app_user token" } }, 403);
  }

  let body: { confirm?: boolean };
  try {
    body = await req.json();
  } catch {
    body = {};
  }
  if (body.confirm !== true) {
    return json({ ok: false, error: { message: "Missing confirm=true" } }, 400);
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const userId = claims.sub;
  const serviceId = claims.service_id;
  const productId = claims.product_id;
  const serviceSlug = claims.service_slug;
  const productSlug = claims.product_slug;

  try {
    // Storage: scoped to service/product/user
    const prefix = `${serviceSlug}/${productSlug}/${userId}/`;
    const { data: list } = await supabase.storage.from("avatars").list(`${serviceSlug}/${productSlug}/${userId}`, { limit: 100 });
    if (list && list.length > 0) {
      await supabase.storage.from("avatars").remove(list.map((f) => prefix + f.name));
    }

    // Delete from KEEP secondary tables (scoped to product)
    for (const t of ["user_badges", "quiz_attempts", "avatar_generations"] as const) {
      await supabase.schema("application").from(t)
        .delete().eq("user_id", userId).eq("service_id", serviceId).eq("product_id", productId);
    }

    // Anonymize profile
    const { error } = await supabase
      .schema("application").from("profiles")
      .update({
        nickname: `deleted_${userId.substring(0, 8)}`,
        avatar_url: null,
        preferences: {},
        onboarding_completed: false,
        total_points: 0,
        points_this_week: 0,
        updated_at: new Date().toISOString(),
      })
      .eq("id", userId)
      .eq("service_id", serviceId)
      .eq("product_id", productId);
    if (error) return json({ ok: false, error: { message: error.message } }, 500);

    console.log(`${TAG} ${ts} | account anonymized user=${userId} product=${productSlug}`);
    return json({ ok: true, data: { user_id: userId, product_id: productId, anonymized: true } }, 200);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Request failed";
    console.error(`${TAG} ${ts} | error:`, message);
    return json({ ok: false, error: { message } }, 500);
  }
});
