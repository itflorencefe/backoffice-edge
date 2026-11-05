import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import { verify as jwtVerify } from "jsr:@zaubrik/djwt@3.0.2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

const TAG = "[app-game-sessions]";

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

Deno.serve(async (req: Request): Promise<Response> => {
  const ts = new Date().toISOString();
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: { message: "Method not allowed" } }, 405);

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) {
    return json({ ok: false, error: { message: "Missing bearer token" } }, 401);
  }
  const rawToken = auth.slice(7).trim();

  let claims: AppClaims;
  try {
    const key = await importKey();
    claims = await jwtVerify(rawToken, key) as unknown as AppClaims;
  } catch (err) {
    return json({ ok: false, error: { message: err instanceof Error ? err.message : "Invalid token" } }, 401);
  }
  if (claims.app_role !== "app_user") {
    return json({ ok: false, error: { message: "Not an app_user token" } }, 403);
  }

  let body: { command?: string; payload?: Record<string, unknown> };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: { message: "Invalid JSON" } }, 400);
  }

  const supabase = createUserClient(rawToken);

  try {
    switch (body.command) {
      case "start": {
        const category = String(body.payload?.category ?? "general");
        const totalQuestions = Number(body.payload?.total_questions ?? 10);
        // Triggers auto-fill service_id and product_id from JWT
        const { data, error } = await supabase
          .from("quiz_attempts")
          .insert({
            user_id: claims.sub,
            service_id: claims.service_id,
            product_id: claims.product_id,
            category,
            total_questions: totalQuestions,
            score: 0,
            correct_answers: 0,
            points_earned: 0,
          })
          .select()
          .maybeSingle();
        if (error) return json({ ok: false, error: { message: error.message } }, 500);
        return json({ ok: true, data: { session_id: data?.id, attempt: data } }, 200);
      }

      case "complete": {
        const sessionId = String(body.payload?.session_id ?? "");
        if (!sessionId) return json({ ok: false, error: { message: "Missing session_id" } }, 400);
        const score = Number(body.payload?.score ?? 0);
        const correctAnswers = Number(body.payload?.correct_answers ?? 0);
        const pointsEarned = Number(body.payload?.points_earned ?? 0);
        // RLS ensures user owns this row for their service+product
        const { data, error } = await supabase
          .from("quiz_attempts")
          .update({
            score,
            correct_answers: correctAnswers,
            points_earned: pointsEarned,
            completed_at: new Date().toISOString(),
          })
          .eq("id", sessionId)
          .select()
          .maybeSingle();
        if (error) return json({ ok: false, error: { message: error.message } }, 500);
        if (!data) return json({ ok: false, error: { message: "Session not found" } }, 404);
        return json({ ok: true, data }, 200);
      }

      case "listMine": {
        const limit = Math.min(Number(body.payload?.limit ?? 20), 100);
        // RLS returns only the user's own rows for their service+product
        const { data, error } = await supabase
          .from("quiz_attempts")
          .select("*")
          .order("created_at", { ascending: false })
          .limit(limit);
        if (error) return json({ ok: false, error: { message: error.message } }, 500);
        return json({ ok: true, data }, 200);
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
